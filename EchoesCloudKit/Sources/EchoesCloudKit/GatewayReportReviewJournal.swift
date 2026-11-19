import Foundation
import Observation

public enum GatewayReportReviewJournalFailure: Error, Equatable, Sendable, LocalizedError {
    case unavailable, inactive, pendingExists, invalidTransition
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Nie udało się bezpiecznie zapisać operacji moderacji. Otwórz panel ponownie."
        case .inactive: "Konto lub dostęp do zapisanej decyzji zmieniły się."
        case .pendingExists: "Najpierw sprawdź i potwierdź wynik poprzedniej decyzji."
        case .invalidTransition: "Najpierw odśwież wynik zapisanej decyzji."
        }
    }
}
public struct GatewayReportReviewScope: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    let owner: PrivateAccountScope
    let binding: GatewayIdentityBinding
    let digest: String
    /// Opaque identifiers for trusted storage providers; never native IDs or access grants.
    public var storageIdentifier: String { digest }
    public var ownerStorageIdentifier: String { owner.digest }
    public init(
        configuration: GatewayConfiguration, owner: PrivateAccountScope, binding: GatewayIdentityBinding
    ) throws {
        let community = try GatewayCommunityScope(
            configuration: configuration, privateScope: owner, binding: binding)
        self.owner = owner
        self.binding = binding
        digest = communityDigest("echoes/report-review-journal/v1\0" + community.digest + "\0" + owner.digest)
    }
    public var description: String { "GatewayReportReviewScope(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayReportReviewJournalLease: Sendable, CustomStringConvertible, CustomReflectable {
    let id: String
    let scope: GatewayReportReviewScope
    public var description: String { "GatewayReportReviewJournalLease(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayReportReviewJournalPhase: String, Codable, Sendable { case prepared, dispatched, resolved }
public struct GatewayReportReviewJournalEntry: Equatable, Sendable, CustomStringConvertible, CustomReflectable
{
    public let intent: GatewayReportReviewRecoveryIntent
    public let phase: GatewayReportReviewJournalPhase
    let revision: String
    let outcome: GatewayReportReviewOutcome?
    public var description: String { "GatewayReportReviewJournalEntry(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Synchronous storage executed only inside the dedicated backend queue transaction.
/// Implementations must isolate this namespace from community journals and credentials.
public protocol GatewayReportReviewJournalStorage: Sendable {
    func read(scope: GatewayReportReviewScope) throws -> Data?
    func write(_ data: Data, scope: GatewayReportReviewScope) throws
    func erase(owner: PrivateAccountScope) throws
}

/// One metadata intent per native/private/origin scope. No inspection receipt, message/reason text, bearer or automatic retry.
/// A single Runtime owns the store; leases also fence overlapping host instances on MainActor.
private final class ReportReviewJournalBackend: @unchecked Sendable {
    // All backend fields and synchronous Security calls are confined to this serial GCD queue.
    // Unlike a blocking lock on Swift's cooperative executor, slow IO cannot exhaust that pool.
    private static let queue = DispatchQueue(label: "mpvEcho.Echo.report-review-journal", qos: .utility)
    func execute(_ command: ReportReviewJournalCommand) async throws -> ReportReviewJournalReply {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do { continuation.resume(returning: try self.perform(command)) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private func perform(_ command: ReportReviewJournalCommand) throws -> ReportReviewJournalReply {
        switch command {
        case .open(let scope): return .lease(try open(scope: scope))
        case .pending(let lease): return .entry(try pending(lease: lease))
        case .peek(let scope):
            guard allowed(scope) else { throw GatewayReportReviewJournalFailure.inactive }
            return .entry(try load(scope)?.entry?.value())
        case .prepare(let intent, let lease): return .entry(try prepare(intent, lease: lease))
        case .dispatch(let entry, let lease): return .entry(try dispatched(entry, lease: lease))
        case .resolve(let entry, let result, let lease):
            return .entry(try resolve(entry, result: result, lease: lease))
        case .acknowledge(let entry, let lease):
            try acknowledge(entry, lease: lease)
            return .none
        case .fence(let lease):
            fence(lease)
            return .none
        case .deletion(let binding, let accountID):
            try fenceForAccountDeletion(binding: binding, accountID: accountID)
            return .none
        case .erase(let owner):
            try erase(owner: owner)
            return .none
        }
    }
    private let storage: any GatewayReportReviewJournalStorage
    private var active: GatewayReportReviewJournalLease?
    private var erasedOwners = Set<String>()
    private struct Fence {
        let binding: GatewayIdentityBinding
        let accountID: String?
    }
    private var fences: [Fence] = []
    private var saturated = false
    private struct StoredIntent: Codable {
        let reportID: String, decisionID: String, verdict: String, contentHash: String
        init(_ value: GatewayReportReviewRecoveryIntent) {
            reportID = value.reportID
            decisionID = value.decisionID
            verdict = value.verdict.rawValue
            contentHash = value.contentHash
        }
        func value() throws -> GatewayReportReviewRecoveryIntent {
            guard let verdict = GatewayReportReviewVerdict(rawValue: verdict) else {
                throw GatewayReportReviewJournalFailure.unavailable
            }
            return try .init(
                reportID: reportID, decisionID: decisionID, verdict: verdict, contentHash: contentHash)
        }
    }
    private struct StoredEntry: Codable {
        let intent: StoredIntent
        var phase: GatewayReportReviewJournalPhase
        var revision: String
        var outcome: String?
        var resultRevision: String?
        func value() throws -> GatewayReportReviewJournalEntry {
            let intent = try intent.value()
            guard gatewayUUID(revision) else { throw GatewayReportReviewJournalFailure.unavailable }
            let result: GatewayReportReviewOutcome?
            switch outcome {
            case nil:
                guard phase != .resolved, resultRevision == nil else {
                    throw GatewayReportReviewJournalFailure.unavailable
                }
                result = nil
            case "confirmed":
                guard phase == .resolved, let resultRevision, gatewayUUID(resultRevision)
                else { throw GatewayReportReviewJournalFailure.unavailable }
                result = .confirmed(revision: resultRevision)
            case "not-applied", "superseded":
                guard phase == .resolved, resultRevision == nil else {
                    throw GatewayReportReviewJournalFailure.unavailable
                }
                result = outcome == "not-applied" ? .notApplied : .superseded
            default: throw GatewayReportReviewJournalFailure.unavailable
            }
            return .init(intent: intent, phase: phase, revision: revision, outcome: result)
        }
    }
    private struct Record: Codable {
        let schemaVersion: Int
        let scope: String, owner: String
        var lease: String
        var entry: StoredEntry?
    }
    public init(storage: any GatewayReportReviewJournalStorage) { self.storage = storage }
    private func allowed(_ scope: GatewayReportReviewScope) -> Bool {
        !saturated && !erasedOwners.contains(scope.owner.digest)
            && !fences.contains {
                $0.binding == scope.binding && ($0.accountID == nil || $0.accountID == scope.owner.accountID)
            }
    }
    private func load(_ scope: GatewayReportReviewScope) throws -> Record? {
        do {
            guard let data = try storage.read(scope: scope) else { return nil }
            guard data.count <= 4096 else { throw GatewayReportReviewJournalFailure.unavailable }
            let value = try JSONDecoder().decode(Record.self, from: data)
            guard value.schemaVersion == 1, value.scope == scope.digest, value.owner == scope.owner.digest,
                gatewayUUID(value.lease)
            else { throw GatewayReportReviewJournalFailure.unavailable }
            _ = try value.entry?.value()
            // Require the canonical closed encoding, including absence of unsupported fields.
            let encoded = try JSONEncoder().encode(value)
            guard
                (try JSONSerialization.jsonObject(with: data) as? NSDictionary)
                    == (try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            else { throw GatewayReportReviewJournalFailure.unavailable }
            return value
        } catch { throw GatewayReportReviewJournalFailure.unavailable }
    }
    private func save(_ record: Record, scope: GatewayReportReviewScope) throws {
        do {
            let data = try JSONEncoder().encode(record)
            guard data.count <= 4096 else { throw GatewayReportReviewJournalFailure.unavailable }
            try storage.write(data, scope: scope)
            guard try storage.read(scope: scope) == data else {
                throw GatewayReportReviewJournalFailure.unavailable
            }
        } catch { throw GatewayReportReviewJournalFailure.unavailable }
    }
    private func open(scope: GatewayReportReviewScope) throws -> GatewayReportReviewJournalLease {
        guard allowed(scope) else { throw GatewayReportReviewJournalFailure.inactive }
        active = nil
        let id = UUID().uuidString.lowercased()
        var value =
            try load(scope)
            ?? Record(schemaVersion: 1, scope: scope.digest, owner: scope.owner.digest, lease: id, entry: nil)
        value.lease = id
        try save(value, scope: scope)
        let lease = GatewayReportReviewJournalLease(id: id, scope: scope)
        active = lease
        return lease
    }
    private func current(_ lease: GatewayReportReviewJournalLease) throws -> Record {
        guard allowed(lease.scope), active?.id == lease.id, active?.scope == lease.scope,
            let value = try load(lease.scope), value.lease == lease.id
        else { throw GatewayReportReviewJournalFailure.inactive }
        return value
    }
    private func fence(_ lease: GatewayReportReviewJournalLease) {
        if active?.id == lease.id { active = nil }
    }
    private func fenceForAccountDeletion(binding: GatewayIdentityBinding, accountID: String?) throws {
        guard accountID == nil || gatewayUUID(accountID!) else {
            throw GatewayReportReviewJournalFailure.unavailable
        }
        if let active, active.scope.binding == binding,
            accountID == nil || active.scope.owner.accountID == accountID
        {
            self.active = nil
        }
        guard !fences.contains(where: { $0.binding == binding && $0.accountID == accountID }) else { return }
        if fences.count >= 32 {
            saturated = true
            active = nil
        } else {
            fences.append(.init(binding: binding, accountID: accountID))
        }
    }
    private func pending(lease: GatewayReportReviewJournalLease) throws -> GatewayReportReviewJournalEntry? {
        try current(lease).entry?.value()
    }
    private func prepare(_ intent: GatewayReportReviewRecoveryIntent, lease: GatewayReportReviewJournalLease)
        throws -> GatewayReportReviewJournalEntry
    {
        var value = try current(lease)
        guard value.entry == nil else { throw GatewayReportReviewJournalFailure.pendingExists }
        value.entry = .init(
            intent: StoredIntent(intent), phase: .prepared, revision: UUID().uuidString.lowercased(),
            outcome: nil, resultRevision: nil)
        try save(value, scope: lease.scope)
        return try value.entry!.value()
    }
    private func dispatched(_ entry: GatewayReportReviewJournalEntry, lease: GatewayReportReviewJournalLease)
        throws -> GatewayReportReviewJournalEntry
    {
        var value = try exact(entry, lease)
        guard entry.phase == .prepared else { throw GatewayReportReviewJournalFailure.invalidTransition }
        value.entry!.phase = .dispatched
        value.entry!.revision = UUID().uuidString.lowercased()
        try save(value, scope: lease.scope)
        return try value.entry!.value()
    }
    private func resolve(
        _ entry: GatewayReportReviewJournalEntry, result: GatewayReportReviewRecoveryResult,
        lease: GatewayReportReviewJournalLease
    ) throws -> GatewayReportReviewJournalEntry {
        var value = try exact(entry, lease)
        guard result.intent == entry.intent else { throw GatewayReportReviewJournalFailure.invalidTransition }
        value.entry!.phase = .resolved
        value.entry!.revision = UUID().uuidString.lowercased()
        switch result.outcome {
        case .confirmed(let revision):
            value.entry!.outcome = "confirmed"
            value.entry!.resultRevision = revision
        case .notApplied:
            value.entry!.outcome = "not-applied"
            value.entry!.resultRevision = nil
        case .superseded:
            value.entry!.outcome = "superseded"
            value.entry!.resultRevision = nil
        }
        let result = try value.entry!.value()
        try save(value, scope: lease.scope)
        return result
    }
    private func exact(_ entry: GatewayReportReviewJournalEntry, _ lease: GatewayReportReviewJournalLease)
        throws -> Record
    {
        let value = try current(lease)
        guard try value.entry?.value() == entry else { throw GatewayReportReviewJournalFailure.inactive }
        return value
    }
    private func acknowledge(_ entry: GatewayReportReviewJournalEntry, lease: GatewayReportReviewJournalLease)
        throws
    {
        var value = try exact(entry, lease)
        guard entry.phase == .resolved else { throw GatewayReportReviewJournalFailure.invalidTransition }
        value.entry = nil
        try save(value, scope: lease.scope)
    }
    private func erase(owner: PrivateAccountScope) throws {
        if erasedOwners.count >= 32 && !erasedOwners.contains(owner.digest) {
            saturated = true
            active = nil
        } else {
            erasedOwners.insert(owner.digest)
        }
        if active?.scope.owner == owner { active = nil }
        do { try storage.erase(owner: owner) } catch { throw GatewayReportReviewJournalFailure.unavailable }
    }
}

private enum ReportReviewJournalCommand: Sendable {
    case open(GatewayReportReviewScope)
    case peek(GatewayReportReviewScope)
    case pending(GatewayReportReviewJournalLease)
    case prepare(GatewayReportReviewRecoveryIntent, GatewayReportReviewJournalLease)
    case dispatch(GatewayReportReviewJournalEntry, GatewayReportReviewJournalLease)
    case resolve(
        GatewayReportReviewJournalEntry, GatewayReportReviewRecoveryResult, GatewayReportReviewJournalLease)
    case acknowledge(GatewayReportReviewJournalEntry, GatewayReportReviewJournalLease)
    case fence(GatewayReportReviewJournalLease)
    case deletion(GatewayIdentityBinding, String?)
    case erase(PrivateAccountScope)
}
private enum ReportReviewJournalReply: Sendable {
    case lease(GatewayReportReviewJournalLease)
    case entry(GatewayReportReviewJournalEntry?)
    case none
}

/// Observable UI fence with serialized storage IO off MainActor. No suspension within a backend
/// read/check/write/readback transaction; every awaited result rechecks this foreground lease.
@MainActor @Observable public final class GatewayReportReviewJournal {
    private let backend: ReportReviewJournalBackend
    private var active: GatewayReportReviewJournalLease?
    private var epoch = UUID()
    private var erasedOwners = Set<String>()
    private struct Fence {
        let binding: GatewayIdentityBinding
        let accountID: String?
    }
    private var fences: [Fence] = []
    private var saturated = false
    public init(storage: any GatewayReportReviewJournalStorage) {
        backend = ReportReviewJournalBackend(storage: storage)
    }
    private func allowed(_ scope: GatewayReportReviewScope) -> Bool {
        !saturated && !erasedOwners.contains(scope.owner.digest)
            && !fences.contains {
                $0.binding == scope.binding && ($0.accountID == nil || $0.accountID == scope.owner.accountID)
            }
    }
    public func isActive(_ lease: GatewayReportReviewJournalLease) -> Bool {
        allowed(lease.scope) && active?.id == lease.id && active?.scope == lease.scope
    }
    /// Read-only bootstrap before binding the report panel. No record creation or lease rotation.
    public func peek(scope: GatewayReportReviewScope) async throws -> GatewayReportReviewJournalEntry? {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard allowed(scope) else { throw GatewayReportReviewJournalFailure.inactive }
        let start = epoch
        guard case .entry(let entry) = try await backend.execute(.peek(scope)) else {
            throw GatewayReportReviewJournalFailure.unavailable
        }
        guard allowed(scope), epoch == start else { throw GatewayReportReviewJournalFailure.inactive }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        return entry
    }
    public func open(scope: GatewayReportReviewScope) async throws -> GatewayReportReviewJournalLease {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard allowed(scope) else { throw GatewayReportReviewJournalFailure.inactive }
        active = nil
        epoch = UUID()
        let start = epoch
        guard case .lease(let lease) = try await backend.execute(.open(scope)) else {
            throw GatewayReportReviewJournalFailure.unavailable
        }
        guard allowed(scope), epoch == start else {
            _ = try? await backend.execute(.fence(lease))
            throw GatewayReportReviewJournalFailure.inactive
        }
        if Task.isCancelled {
            _ = try? await backend.execute(.fence(lease))
            throw GatewayFailure.cancelled
        }
        active = lease
        return lease
    }
    public func fence(_ lease: GatewayReportReviewJournalLease) {
        if active?.id == lease.id {
            active = nil
            epoch = UUID()
        }
        let backend = backend
        Task { _ = try? await backend.execute(.fence(lease)) }
    }
    public func fenceForAccountDeletion(binding: GatewayIdentityBinding, accountID: String?) throws {
        guard accountID == nil || gatewayUUID(accountID!) else {
            throw GatewayReportReviewJournalFailure.unavailable
        }
        if let active, active.scope.binding == binding,
            accountID == nil || active.scope.owner.accountID == accountID
        {
            self.active = nil
        }
        epoch = UUID()
        if !fences.contains(where: { $0.binding == binding && $0.accountID == accountID }) {
            if fences.count >= 32 {
                saturated = true
                active = nil
            } else {
                fences.append(.init(binding: binding, accountID: accountID))
            }
        }
        let backend = backend
        Task { _ = try? await backend.execute(.deletion(binding, accountID)) }
    }
    private func entry(_ command: ReportReviewJournalCommand, lease: GatewayReportReviewJournalLease)
        async throws -> GatewayReportReviewJournalEntry?
    {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isActive(lease) else { throw GatewayReportReviewJournalFailure.inactive }
        guard case .entry(let value) = try await backend.execute(command) else {
            throw GatewayReportReviewJournalFailure.unavailable
        }
        guard isActive(lease) else { throw GatewayReportReviewJournalFailure.inactive }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        return value
    }
    public func pending(lease: GatewayReportReviewJournalLease) async throws
        -> GatewayReportReviewJournalEntry?
    { try await entry(.pending(lease), lease: lease) }
    public func prepare(_ intent: GatewayReportReviewRecoveryIntent, lease: GatewayReportReviewJournalLease)
        async throws -> GatewayReportReviewJournalEntry
    {
        guard let value = try await entry(.prepare(intent, lease), lease: lease) else {
            throw GatewayReportReviewJournalFailure.unavailable
        }
        return value
    }
    public func dispatched(_ value: GatewayReportReviewJournalEntry, lease: GatewayReportReviewJournalLease)
        async throws -> GatewayReportReviewJournalEntry
    {
        guard let result = try await entry(.dispatch(value, lease), lease: lease) else {
            throw GatewayReportReviewJournalFailure.unavailable
        }
        return result
    }
    public func resolve(
        _ value: GatewayReportReviewJournalEntry, result: GatewayReportReviewRecoveryResult,
        lease: GatewayReportReviewJournalLease
    ) async throws -> GatewayReportReviewJournalEntry {
        guard let value = try await entry(.resolve(value, result, lease), lease: lease) else {
            throw GatewayReportReviewJournalFailure.unavailable
        }
        return value
    }
    public func acknowledge(_ value: GatewayReportReviewJournalEntry, lease: GatewayReportReviewJournalLease)
        async throws
    {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isActive(lease) else { throw GatewayReportReviewJournalFailure.inactive }
        _ = try await backend.execute(.acknowledge(value, lease))
        guard isActive(lease) else { throw GatewayReportReviewJournalFailure.inactive }
        if Task.isCancelled { throw GatewayFailure.cancelled }
    }
    public func erase(owner: PrivateAccountScope) async throws {
        if erasedOwners.count >= 32 && !erasedOwners.contains(owner.digest) {
            saturated = true
            active = nil
        } else {
            erasedOwners.insert(owner.digest)
        }
        epoch = UUID()
        if active?.scope.owner == owner { active = nil }
        _ = try await backend.execute(.erase(owner))
    }
}
