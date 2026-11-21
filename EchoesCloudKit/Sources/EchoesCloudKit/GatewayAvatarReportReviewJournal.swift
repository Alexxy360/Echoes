import Foundation
import Observation

public enum GatewayAvatarReportReviewJournalFailure: Error, Equatable, Sendable, LocalizedError {
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
public struct GatewayAvatarReportReviewScope: Equatable, Sendable, CustomStringConvertible, CustomReflectable
{
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
        digest = communityDigest(
            "echoes/avatar-report-review-journal/v1\0" + community.digest + "\0" + owner.digest)
    }
    public var description: String { "GatewayAvatarReportReviewScope(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReportReviewJournalLease: Sendable, CustomStringConvertible, CustomReflectable {
    let id: String
    let scope: GatewayAvatarReportReviewScope
    public var description: String { "GatewayAvatarReportReviewJournalLease(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayAvatarReportReviewJournalPhase: String, Codable, Sendable {
    case prepared, dispatched, retiring, resolved
}
public struct GatewayAvatarReportReviewJournalEntry: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let intent: GatewayAvatarReportReviewSavedIntent
    public let phase: GatewayAvatarReportReviewJournalPhase
    let revision: String
    let outcome: GatewayAvatarReportReviewOutcome?
    public var description: String { "GatewayAvatarReportReviewJournalEntry(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Synchronous storage executed only inside the dedicated backend queue transaction.
/// Implementations must isolate this namespace from community journals and credentials.
public protocol GatewayAvatarReportReviewJournalStorage: Sendable {
    func read(scope: GatewayAvatarReportReviewScope) throws -> Data?
    func write(_ data: Data, scope: GatewayAvatarReportReviewScope) throws
    func erase(owner: PrivateAccountScope) throws
}

/// One metadata intent per native/private/origin scope. Only exact recovery and optional validated photo target. No inspection receipt, reason, pixels, bearer or automatic retry.
/// A single Runtime owns the store; leases also fence overlapping host instances on MainActor.
private final class AvatarReportReviewJournalBackend: @unchecked Sendable {
    // All backend fields and synchronous Security calls are confined to this serial GCD queue.
    // Unlike a blocking lock on Swift's cooperative executor, slow IO cannot exhaust that pool.
    private static let queue = DispatchQueue(
        label: "mpvEcho.Echo.avatar-report-review-journal", qos: .utility)
    func execute(_ command: AvatarReportReviewJournalCommand) async throws -> AvatarReportReviewJournalReply {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do { continuation.resume(returning: try self.perform(command)) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private func perform(_ command: AvatarReportReviewJournalCommand) throws -> AvatarReportReviewJournalReply
    {
        switch command {
        case .open(let scope): return .lease(try open(scope: scope))
        case .pending(let lease): return .entry(try pending(lease: lease))
        case .peek(let scope):
            guard allowed(scope) else { throw GatewayAvatarReportReviewJournalFailure.inactive }
            return .entry(try load(scope)?.entry?.value())
        case .prepare(let intent, let lease): return .entry(try prepare(intent, lease: lease))
        case .dispatch(let entry, let lease): return .entry(try dispatched(entry, lease: lease))
        case .retire(let entry, let lease): return .entry(try retiring(entry, lease: lease))
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
    private let storage: any GatewayAvatarReportReviewJournalStorage
    private var active: GatewayAvatarReportReviewJournalLease?
    private var erasedOwners = Set<String>()
    private struct Fence {
        let binding: GatewayIdentityBinding
        let accountID: String?
    }
    private var fences: [Fence] = []
    private var saturated = false
    private struct StoredTarget: Codable {
        let ownerID: String, versionID: String
        let publicationGeneration: Int
        init(_ value: GatewayAvatarReportReviewPhotoTarget) {
            ownerID = value.ownerID
            versionID = value.versionID
            publicationGeneration = value.publicationGeneration
        }
        func value() throws -> GatewayAvatarReportReviewPhotoTarget {
            try .init(ownerID: ownerID, versionID: versionID, publicationGeneration: publicationGeneration)
        }
    }
    private struct StoredIntent: Codable {
        let reportID: String, decisionID: String, verdict: String, contentHash: String
        let target: StoredTarget?
        init(_ value: GatewayAvatarReportReviewSavedIntent) {
            reportID = value.recovery.reportID
            decisionID = value.recovery.decisionID
            verdict = value.recovery.verdict.rawValue
            contentHash = value.recovery.contentHash
            target = value.photoTarget.map(StoredTarget.init)
        }
        func value() throws -> GatewayAvatarReportReviewSavedIntent {
            guard let verdict = GatewayAvatarReportReviewVerdict(rawValue: verdict) else {
                throw GatewayAvatarReportReviewJournalFailure.unavailable
            }
            let recovery = try GatewayAvatarReportReviewRecoveryIntent(
                reportID: reportID, decisionID: decisionID, verdict: verdict, contentHash: contentHash)
            return try .init(recovery: recovery, photoTarget: target?.value())
        }
    }
    private struct StoredEntry: Codable {
        let intent: StoredIntent
        var phase: GatewayAvatarReportReviewJournalPhase
        var revision: String
        var outcome: String?
        var resultRevision: String?
        func value() throws -> GatewayAvatarReportReviewJournalEntry {
            let intent = try intent.value()
            guard gatewayUUID(revision) else { throw GatewayAvatarReportReviewJournalFailure.unavailable }
            let result: GatewayAvatarReportReviewOutcome?
            switch outcome {
            case nil:
                guard phase != .resolved, resultRevision == nil else {
                    throw GatewayAvatarReportReviewJournalFailure.unavailable
                }
                result = nil
            case "confirmed":
                guard phase == .resolved, let resultRevision, gatewayUUID(resultRevision)
                else { throw GatewayAvatarReportReviewJournalFailure.unavailable }
                result = .confirmed(revision: resultRevision)
            case "not-applied":
                guard phase == .dispatched || phase == .retiring, resultRevision == nil else {
                    throw GatewayAvatarReportReviewJournalFailure.unavailable
                }
                result = .notApplied
            case "superseded", "retired":
                guard phase == .resolved, resultRevision == nil else {
                    throw GatewayAvatarReportReviewJournalFailure.unavailable
                }
                result = outcome == "retired" ? .retired : .superseded
            default: throw GatewayAvatarReportReviewJournalFailure.unavailable
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
    public init(storage: any GatewayAvatarReportReviewJournalStorage) { self.storage = storage }
    private func allowed(_ scope: GatewayAvatarReportReviewScope) -> Bool {
        !saturated && !erasedOwners.contains(scope.owner.digest)
            && !fences.contains {
                $0.binding == scope.binding && ($0.accountID == nil || $0.accountID == scope.owner.accountID)
            }
    }
    private func load(_ scope: GatewayAvatarReportReviewScope) throws -> Record? {
        do {
            guard let data = try storage.read(scope: scope) else { return nil }
            guard data.count <= 4096 else { throw GatewayAvatarReportReviewJournalFailure.unavailable }
            let value = try JSONDecoder().decode(Record.self, from: data)
            guard value.schemaVersion == 1, value.scope == scope.digest, value.owner == scope.owner.digest,
                gatewayUUID(value.lease)
            else { throw GatewayAvatarReportReviewJournalFailure.unavailable }
            _ = try value.entry?.value()
            // Require the canonical closed encoding, including absence of unsupported fields.
            let encoded = try JSONEncoder().encode(value)
            guard
                (try JSONSerialization.jsonObject(with: data) as? NSDictionary)
                    == (try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            else { throw GatewayAvatarReportReviewJournalFailure.unavailable }
            return value
        } catch { throw GatewayAvatarReportReviewJournalFailure.unavailable }
    }
    private func save(_ record: Record, scope: GatewayAvatarReportReviewScope) throws {
        do {
            let data = try JSONEncoder().encode(record)
            guard data.count <= 4096 else { throw GatewayAvatarReportReviewJournalFailure.unavailable }
            try storage.write(data, scope: scope)
            guard try storage.read(scope: scope) == data else {
                throw GatewayAvatarReportReviewJournalFailure.unavailable
            }
        } catch { throw GatewayAvatarReportReviewJournalFailure.unavailable }
    }
    private func open(scope: GatewayAvatarReportReviewScope) throws -> GatewayAvatarReportReviewJournalLease {
        guard allowed(scope) else { throw GatewayAvatarReportReviewJournalFailure.inactive }
        active = nil
        let id = UUID().uuidString.lowercased()
        var value =
            try load(scope)
            ?? Record(schemaVersion: 1, scope: scope.digest, owner: scope.owner.digest, lease: id, entry: nil)
        value.lease = id
        try save(value, scope: scope)
        let lease = GatewayAvatarReportReviewJournalLease(id: id, scope: scope)
        active = lease
        return lease
    }
    private func current(_ lease: GatewayAvatarReportReviewJournalLease) throws -> Record {
        guard allowed(lease.scope), active?.id == lease.id, active?.scope == lease.scope,
            let value = try load(lease.scope), value.lease == lease.id
        else { throw GatewayAvatarReportReviewJournalFailure.inactive }
        return value
    }
    private func fence(_ lease: GatewayAvatarReportReviewJournalLease) {
        if active?.id == lease.id { active = nil }
    }
    private func fenceForAccountDeletion(binding: GatewayIdentityBinding, accountID: String?) throws {
        guard accountID == nil || gatewayUUID(accountID!) else {
            throw GatewayAvatarReportReviewJournalFailure.unavailable
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
    private func pending(lease: GatewayAvatarReportReviewJournalLease) throws
        -> GatewayAvatarReportReviewJournalEntry?
    {
        try current(lease).entry?.value()
    }
    private func prepare(
        _ intent: GatewayAvatarReportReviewSavedIntent, lease: GatewayAvatarReportReviewJournalLease
    )
        throws -> GatewayAvatarReportReviewJournalEntry
    {
        var value = try current(lease)
        guard value.entry == nil else { throw GatewayAvatarReportReviewJournalFailure.pendingExists }
        value.entry = .init(
            intent: StoredIntent(intent), phase: .prepared, revision: UUID().uuidString.lowercased(),
            outcome: nil, resultRevision: nil)
        try save(value, scope: lease.scope)
        return try value.entry!.value()
    }
    private func dispatched(
        _ entry: GatewayAvatarReportReviewJournalEntry, lease: GatewayAvatarReportReviewJournalLease
    )
        throws -> GatewayAvatarReportReviewJournalEntry
    {
        var value = try exact(entry, lease)
        guard entry.phase == .prepared else {
            throw GatewayAvatarReportReviewJournalFailure.invalidTransition
        }
        value.entry!.phase = .dispatched
        value.entry!.revision = UUID().uuidString.lowercased()
        try save(value, scope: lease.scope)
        return try value.entry!.value()
    }
    private func retiring(
        _ entry: GatewayAvatarReportReviewJournalEntry, lease: GatewayAvatarReportReviewJournalLease
    )
        throws -> GatewayAvatarReportReviewJournalEntry
    {
        var value = try exact(entry, lease)
        guard entry.phase != .resolved else {
            throw GatewayAvatarReportReviewJournalFailure.invalidTransition
        }
        if entry.phase == .retiring { return entry }
        value.entry!.phase = .retiring
        value.entry!.revision = UUID().uuidString.lowercased()
        try save(value, scope: lease.scope)
        return try value.entry!.value()
    }
    private func resolve(
        _ entry: GatewayAvatarReportReviewJournalEntry, result: GatewayAvatarReportReviewRecoveryResult,
        lease: GatewayAvatarReportReviewJournalLease
    ) throws -> GatewayAvatarReportReviewJournalEntry {
        var value = try exact(entry, lease)
        guard result.intent == entry.intent.recovery else {
            throw GatewayAvatarReportReviewJournalFailure.invalidTransition
        }
        guard entry.phase != .resolved || entry.outcome == result.outcome && result.outcome.isTerminal else {
            throw GatewayAvatarReportReviewJournalFailure.invalidTransition
        }
        value.entry!.phase =
            result.outcome.isTerminal ? .resolved : entry.phase == .retiring ? .retiring : .dispatched
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
        case .retired:
            value.entry!.outcome = "retired"
            value.entry!.resultRevision = nil
        }
        let result = try value.entry!.value()
        try save(value, scope: lease.scope)
        return result
    }
    private func exact(
        _ entry: GatewayAvatarReportReviewJournalEntry, _ lease: GatewayAvatarReportReviewJournalLease
    )
        throws -> Record
    {
        let value = try current(lease)
        guard try value.entry?.value() == entry else {
            throw GatewayAvatarReportReviewJournalFailure.inactive
        }
        return value
    }
    private func acknowledge(
        _ entry: GatewayAvatarReportReviewJournalEntry, lease: GatewayAvatarReportReviewJournalLease
    )
        throws
    {
        var value = try exact(entry, lease)
        guard entry.phase == .resolved, entry.outcome?.isTerminal == true else {
            throw GatewayAvatarReportReviewJournalFailure.invalidTransition
        }
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
        do { try storage.erase(owner: owner) } catch {
            throw GatewayAvatarReportReviewJournalFailure.unavailable
        }
    }
}

private enum AvatarReportReviewJournalCommand: Sendable {
    case open(GatewayAvatarReportReviewScope)
    case peek(GatewayAvatarReportReviewScope)
    case pending(GatewayAvatarReportReviewJournalLease)
    case prepare(GatewayAvatarReportReviewSavedIntent, GatewayAvatarReportReviewJournalLease)
    case dispatch(GatewayAvatarReportReviewJournalEntry, GatewayAvatarReportReviewJournalLease)
    case retire(GatewayAvatarReportReviewJournalEntry, GatewayAvatarReportReviewJournalLease)
    case resolve(
        GatewayAvatarReportReviewJournalEntry, GatewayAvatarReportReviewRecoveryResult,
        GatewayAvatarReportReviewJournalLease)
    case acknowledge(GatewayAvatarReportReviewJournalEntry, GatewayAvatarReportReviewJournalLease)
    case fence(GatewayAvatarReportReviewJournalLease)
    case deletion(GatewayIdentityBinding, String?)
    case erase(PrivateAccountScope)
}
private enum AvatarReportReviewJournalReply: Sendable {
    case lease(GatewayAvatarReportReviewJournalLease)
    case entry(GatewayAvatarReportReviewJournalEntry?)
    case none
}

/// Observable UI fence with serialized storage IO off MainActor. No suspension within a backend
/// read/check/write/readback transaction; every awaited result rechecks this foreground lease.
@MainActor @Observable public final class GatewayAvatarReportReviewJournal {
    private let backend: AvatarReportReviewJournalBackend
    private var active: GatewayAvatarReportReviewJournalLease?
    private var epoch = UUID()
    private var erasedOwners = Set<String>()
    private struct Fence {
        let binding: GatewayIdentityBinding
        let accountID: String?
    }
    private var fences: [Fence] = []
    private var saturated = false
    public init(storage: any GatewayAvatarReportReviewJournalStorage) {
        backend = AvatarReportReviewJournalBackend(storage: storage)
    }
    private func allowed(_ scope: GatewayAvatarReportReviewScope) -> Bool {
        !saturated && !erasedOwners.contains(scope.owner.digest)
            && !fences.contains {
                $0.binding == scope.binding && ($0.accountID == nil || $0.accountID == scope.owner.accountID)
            }
    }
    public func isActive(_ lease: GatewayAvatarReportReviewJournalLease) -> Bool {
        allowed(lease.scope) && active?.id == lease.id && active?.scope == lease.scope
    }
    /// Read-only bootstrap before binding the report panel. No record creation or lease rotation.
    public func peek(scope: GatewayAvatarReportReviewScope) async throws
        -> GatewayAvatarReportReviewJournalEntry?
    {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard allowed(scope) else { throw GatewayAvatarReportReviewJournalFailure.inactive }
        let start = epoch
        guard case .entry(let entry) = try await backend.execute(.peek(scope)) else {
            throw GatewayAvatarReportReviewJournalFailure.unavailable
        }
        guard allowed(scope), epoch == start else { throw GatewayAvatarReportReviewJournalFailure.inactive }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        return entry
    }
    public func open(scope: GatewayAvatarReportReviewScope) async throws
        -> GatewayAvatarReportReviewJournalLease
    {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard allowed(scope) else { throw GatewayAvatarReportReviewJournalFailure.inactive }
        active = nil
        epoch = UUID()
        let start = epoch
        guard case .lease(let lease) = try await backend.execute(.open(scope)) else {
            throw GatewayAvatarReportReviewJournalFailure.unavailable
        }
        guard allowed(scope), epoch == start else {
            _ = try? await backend.execute(.fence(lease))
            throw GatewayAvatarReportReviewJournalFailure.inactive
        }
        if Task.isCancelled {
            _ = try? await backend.execute(.fence(lease))
            throw GatewayFailure.cancelled
        }
        active = lease
        return lease
    }
    public func fence(_ lease: GatewayAvatarReportReviewJournalLease) {
        if active?.id == lease.id {
            active = nil
            epoch = UUID()
        }
        let backend = backend
        Task { _ = try? await backend.execute(.fence(lease)) }
    }
    public func fenceForAccountDeletion(binding: GatewayIdentityBinding, accountID: String?) throws {
        guard accountID == nil || gatewayUUID(accountID!) else {
            throw GatewayAvatarReportReviewJournalFailure.unavailable
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
    private func entry(
        _ command: AvatarReportReviewJournalCommand, lease: GatewayAvatarReportReviewJournalLease
    )
        async throws -> GatewayAvatarReportReviewJournalEntry?
    {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isActive(lease) else { throw GatewayAvatarReportReviewJournalFailure.inactive }
        guard case .entry(let value) = try await backend.execute(command) else {
            throw GatewayAvatarReportReviewJournalFailure.unavailable
        }
        guard isActive(lease) else { throw GatewayAvatarReportReviewJournalFailure.inactive }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        return value
    }
    public func pending(lease: GatewayAvatarReportReviewJournalLease) async throws
        -> GatewayAvatarReportReviewJournalEntry?
    { try await entry(.pending(lease), lease: lease) }
    public func prepare(
        _ intent: GatewayAvatarReportReviewSavedIntent, lease: GatewayAvatarReportReviewJournalLease
    )
        async throws -> GatewayAvatarReportReviewJournalEntry
    {
        guard let value = try await entry(.prepare(intent, lease), lease: lease) else {
            throw GatewayAvatarReportReviewJournalFailure.unavailable
        }
        return value
    }
    public func dispatched(
        _ value: GatewayAvatarReportReviewJournalEntry, lease: GatewayAvatarReportReviewJournalLease
    )
        async throws -> GatewayAvatarReportReviewJournalEntry
    {
        guard let result = try await entry(.dispatch(value, lease), lease: lease) else {
            throw GatewayAvatarReportReviewJournalFailure.unavailable
        }
        return result
    }
    public func retiring(
        _ value: GatewayAvatarReportReviewJournalEntry, lease: GatewayAvatarReportReviewJournalLease
    )
        async throws -> GatewayAvatarReportReviewJournalEntry
    {
        guard let result = try await entry(.retire(value, lease), lease: lease) else {
            throw GatewayAvatarReportReviewJournalFailure.unavailable
        }
        return result
    }
    public func resolve(
        _ value: GatewayAvatarReportReviewJournalEntry, result: GatewayAvatarReportReviewRecoveryResult,
        lease: GatewayAvatarReportReviewJournalLease
    ) async throws -> GatewayAvatarReportReviewJournalEntry {
        guard let value = try await entry(.resolve(value, result, lease), lease: lease) else {
            throw GatewayAvatarReportReviewJournalFailure.unavailable
        }
        return value
    }
    public func acknowledge(
        _ value: GatewayAvatarReportReviewJournalEntry, lease: GatewayAvatarReportReviewJournalLease
    )
        async throws
    {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isActive(lease) else { throw GatewayAvatarReportReviewJournalFailure.inactive }
        _ = try await backend.execute(.acknowledge(value, lease))
        guard isActive(lease) else { throw GatewayAvatarReportReviewJournalFailure.inactive }
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
