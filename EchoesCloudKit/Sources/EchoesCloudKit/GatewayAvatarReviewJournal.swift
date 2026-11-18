import Foundation
import Observation

public enum GatewayAvatarReviewJournalFailure: Error, Equatable, Sendable, LocalizedError {
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
public struct GatewayAvatarReviewScope: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
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
        digest = communityDigest("echoes/avatar-review-journal/v1\0" + community.digest + "\0" + owner.digest)
    }
    public var description: String { "GatewayAvatarReviewScope(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReviewJournalLease: Sendable, CustomStringConvertible, CustomReflectable {
    let id: String
    let scope: GatewayAvatarReviewScope
    public var description: String { "GatewayAvatarReviewJournalLease(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayAvatarReviewJournalPhase: String, Codable, Sendable { case prepared, dispatched, resolved }
public struct GatewayAvatarReviewJournalEntry: Equatable, Sendable, CustomStringConvertible, CustomReflectable
{
    public let intent: GatewayAvatarReviewRecoveryIntent
    public let phase: GatewayAvatarReviewJournalPhase
    let revision: String
    let outcome: GatewayAvatarReviewOutcome?
    public var description: String { "GatewayAvatarReviewJournalEntry(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Synchronous storage executed only inside the dedicated backend queue transaction.
/// Implementations must isolate this namespace from community journals and credentials.
public protocol GatewayAvatarReviewJournalStorage: Sendable {
    func read(scope: GatewayAvatarReviewScope) throws -> Data?
    func write(_ data: Data, scope: GatewayAvatarReviewScope) throws
    func erase(owner: PrivateAccountScope) throws
}

/// One metadata intent per native/private/origin scope. No receipt, image, bearer or automatic retry.
/// A single Runtime owns the store; leases also fence overlapping host instances on MainActor.
private final class AvatarReviewJournalBackend: @unchecked Sendable {
    // All backend fields and synchronous Security calls are confined to this serial GCD queue.
    // Unlike a blocking lock on Swift's cooperative executor, slow IO cannot exhaust that pool.
    private static let queue = DispatchQueue(label: "mpvEcho.Echo.avatar-review-journal", qos: .utility)
    func execute(_ command: AvatarReviewJournalCommand) async throws -> AvatarReviewJournalReply {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do { continuation.resume(returning: try self.perform(command)) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private func perform(_ command: AvatarReviewJournalCommand) throws -> AvatarReviewJournalReply {
        switch command {
        case .open(let scope): return .lease(try open(scope: scope))
        case .pending(let lease): return .entry(try pending(lease: lease))
        case .peek(let scope):
            guard allowed(scope) else { throw GatewayAvatarReviewJournalFailure.inactive }
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
    private let storage: any GatewayAvatarReviewJournalStorage
    private var active: GatewayAvatarReviewJournalLease?
    private var erasedOwners = Set<String>()
    private struct Fence {
        let binding: GatewayIdentityBinding
        let accountID: String?
    }
    private var fences: [Fence] = []
    private var saturated = false
    private struct StoredIntent: Codable {
        let accountID: String, requestID: String, versionID: String, reviewRevision: String
        let generation: Int
        let decisionID: String, verdict: String
        init(_ value: GatewayAvatarReviewRecoveryIntent) {
            accountID = value.item.accountID
            requestID = value.item.requestID
            versionID = value.item.versionID
            reviewRevision = value.item.reviewRevision
            generation = value.item.generation
            decisionID = value.decisionID
            verdict = value.verdict.rawValue
        }
        func value() throws -> GatewayAvatarReviewRecoveryIntent {
            guard let verdict = GatewayAvatarReviewVerdict(rawValue: verdict) else {
                throw GatewayAvatarReviewJournalFailure.unavailable
            }
            return try .init(
                item: .init(
                    accountID: accountID, requestID: requestID, versionID: versionID,
                    generation: generation, reviewRevision: reviewRevision), decisionID: decisionID,
                verdict: verdict)
        }
    }
    private struct StoredEntry: Codable {
        let intent: StoredIntent
        var phase: GatewayAvatarReviewJournalPhase
        var revision: String
        var outcome: String?
        var resultRevision: String?
        func value() throws -> GatewayAvatarReviewJournalEntry {
            let intent = try intent.value()
            guard gatewayUUID(revision) else { throw GatewayAvatarReviewJournalFailure.unavailable }
            let result: GatewayAvatarReviewOutcome?
            switch outcome {
            case nil:
                guard phase != .resolved, resultRevision == nil else {
                    throw GatewayAvatarReviewJournalFailure.unavailable
                }
                result = nil
            case "confirmed":
                guard phase == .resolved, let resultRevision, gatewayUUID(resultRevision),
                    resultRevision != intent.item.reviewRevision
                else { throw GatewayAvatarReviewJournalFailure.unavailable }
                result = .confirmed(revision: resultRevision)
            case "not-applied", "superseded":
                guard phase == .resolved, resultRevision == nil else {
                    throw GatewayAvatarReviewJournalFailure.unavailable
                }
                result = outcome == "not-applied" ? .notApplied : .superseded
            default: throw GatewayAvatarReviewJournalFailure.unavailable
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
    public init(storage: any GatewayAvatarReviewJournalStorage) { self.storage = storage }
    private func allowed(_ scope: GatewayAvatarReviewScope) -> Bool {
        !saturated && !erasedOwners.contains(scope.owner.digest)
            && !fences.contains {
                $0.binding == scope.binding && ($0.accountID == nil || $0.accountID == scope.owner.accountID)
            }
    }
    private func load(_ scope: GatewayAvatarReviewScope) throws -> Record? {
        do {
            guard let data = try storage.read(scope: scope) else { return nil }
            guard data.count <= 4096 else { throw GatewayAvatarReviewJournalFailure.unavailable }
            let value = try JSONDecoder().decode(Record.self, from: data)
            guard value.schemaVersion == 1, value.scope == scope.digest, value.owner == scope.owner.digest,
                gatewayUUID(value.lease)
            else { throw GatewayAvatarReviewJournalFailure.unavailable }
            _ = try value.entry?.value()
            // Require the canonical closed encoding, including absence of unsupported fields.
            let encoded = try JSONEncoder().encode(value)
            guard
                (try JSONSerialization.jsonObject(with: data) as? NSDictionary)
                    == (try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            else { throw GatewayAvatarReviewJournalFailure.unavailable }
            return value
        } catch { throw GatewayAvatarReviewJournalFailure.unavailable }
    }
    private func save(_ record: Record, scope: GatewayAvatarReviewScope) throws {
        do {
            let data = try JSONEncoder().encode(record)
            guard data.count <= 4096 else { throw GatewayAvatarReviewJournalFailure.unavailable }
            try storage.write(data, scope: scope)
            guard try storage.read(scope: scope) == data else {
                throw GatewayAvatarReviewJournalFailure.unavailable
            }
        } catch { throw GatewayAvatarReviewJournalFailure.unavailable }
    }
    private func open(scope: GatewayAvatarReviewScope) throws -> GatewayAvatarReviewJournalLease {
        guard allowed(scope) else { throw GatewayAvatarReviewJournalFailure.inactive }
        active = nil
        let id = UUID().uuidString.lowercased()
        var value =
            try load(scope)
            ?? Record(schemaVersion: 1, scope: scope.digest, owner: scope.owner.digest, lease: id, entry: nil)
        value.lease = id
        try save(value, scope: scope)
        let lease = GatewayAvatarReviewJournalLease(id: id, scope: scope)
        active = lease
        return lease
    }
    private func current(_ lease: GatewayAvatarReviewJournalLease) throws -> Record {
        guard allowed(lease.scope), active?.id == lease.id, active?.scope == lease.scope,
            let value = try load(lease.scope), value.lease == lease.id
        else { throw GatewayAvatarReviewJournalFailure.inactive }
        return value
    }
    private func fence(_ lease: GatewayAvatarReviewJournalLease) {
        if active?.id == lease.id { active = nil }
    }
    private func fenceForAccountDeletion(binding: GatewayIdentityBinding, accountID: String?) throws {
        guard accountID == nil || gatewayUUID(accountID!) else {
            throw GatewayAvatarReviewJournalFailure.unavailable
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
    private func pending(lease: GatewayAvatarReviewJournalLease) throws -> GatewayAvatarReviewJournalEntry? {
        try current(lease).entry?.value()
    }
    private func prepare(_ intent: GatewayAvatarReviewRecoveryIntent, lease: GatewayAvatarReviewJournalLease)
        throws -> GatewayAvatarReviewJournalEntry
    {
        var value = try current(lease)
        guard value.entry == nil else { throw GatewayAvatarReviewJournalFailure.pendingExists }
        value.entry = .init(
            intent: StoredIntent(intent), phase: .prepared, revision: UUID().uuidString.lowercased(),
            outcome: nil, resultRevision: nil)
        try save(value, scope: lease.scope)
        return try value.entry!.value()
    }
    private func dispatched(_ entry: GatewayAvatarReviewJournalEntry, lease: GatewayAvatarReviewJournalLease)
        throws -> GatewayAvatarReviewJournalEntry
    {
        var value = try exact(entry, lease)
        guard entry.phase == .prepared else { throw GatewayAvatarReviewJournalFailure.invalidTransition }
        value.entry!.phase = .dispatched
        value.entry!.revision = UUID().uuidString.lowercased()
        try save(value, scope: lease.scope)
        return try value.entry!.value()
    }
    private func resolve(
        _ entry: GatewayAvatarReviewJournalEntry, result: GatewayAvatarReviewRecoveryResult,
        lease: GatewayAvatarReviewJournalLease
    ) throws -> GatewayAvatarReviewJournalEntry {
        var value = try exact(entry, lease)
        guard result.intent == entry.intent else { throw GatewayAvatarReviewJournalFailure.invalidTransition }
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
    private func exact(_ entry: GatewayAvatarReviewJournalEntry, _ lease: GatewayAvatarReviewJournalLease)
        throws -> Record
    {
        let value = try current(lease)
        guard try value.entry?.value() == entry else { throw GatewayAvatarReviewJournalFailure.inactive }
        return value
    }
    private func acknowledge(_ entry: GatewayAvatarReviewJournalEntry, lease: GatewayAvatarReviewJournalLease)
        throws
    {
        var value = try exact(entry, lease)
        guard entry.phase == .resolved else { throw GatewayAvatarReviewJournalFailure.invalidTransition }
        value.entry = nil
        try save(value, scope: lease.scope)
    }
    private func erase(owner: PrivateAccountScope) throws {
        guard erasedOwners.count < 32 || erasedOwners.contains(owner.digest) else {
            saturated = true
            active = nil
            throw GatewayAvatarReviewJournalFailure.unavailable
        }
        erasedOwners.insert(owner.digest)
        if active?.scope.owner == owner { active = nil }
        do { try storage.erase(owner: owner) } catch { throw GatewayAvatarReviewJournalFailure.unavailable }
    }
}

private enum AvatarReviewJournalCommand: Sendable {
    case open(GatewayAvatarReviewScope)
    case peek(GatewayAvatarReviewScope)
    case pending(GatewayAvatarReviewJournalLease)
    case prepare(GatewayAvatarReviewRecoveryIntent, GatewayAvatarReviewJournalLease)
    case dispatch(GatewayAvatarReviewJournalEntry, GatewayAvatarReviewJournalLease)
    case resolve(
        GatewayAvatarReviewJournalEntry, GatewayAvatarReviewRecoveryResult, GatewayAvatarReviewJournalLease)
    case acknowledge(GatewayAvatarReviewJournalEntry, GatewayAvatarReviewJournalLease)
    case fence(GatewayAvatarReviewJournalLease)
    case deletion(GatewayIdentityBinding, String?)
    case erase(PrivateAccountScope)
}
private enum AvatarReviewJournalReply: Sendable {
    case lease(GatewayAvatarReviewJournalLease)
    case entry(GatewayAvatarReviewJournalEntry?)
    case none
}

/// Observable UI fence with serialized storage IO off MainActor. No suspension within a backend
/// read/check/write/readback transaction; every awaited result rechecks this foreground lease.
@MainActor @Observable public final class GatewayAvatarReviewJournal {
    private let backend: AvatarReviewJournalBackend
    private var active: GatewayAvatarReviewJournalLease?
    private var epoch = UUID()
    private var erasedOwners = Set<String>()
    private struct Fence {
        let binding: GatewayIdentityBinding
        let accountID: String?
    }
    private var fences: [Fence] = []
    private var saturated = false
    public init(storage: any GatewayAvatarReviewJournalStorage) {
        backend = AvatarReviewJournalBackend(storage: storage)
    }
    private func allowed(_ scope: GatewayAvatarReviewScope) -> Bool {
        !saturated && !erasedOwners.contains(scope.owner.digest)
            && !fences.contains {
                $0.binding == scope.binding && ($0.accountID == nil || $0.accountID == scope.owner.accountID)
            }
    }
    public func isActive(_ lease: GatewayAvatarReviewJournalLease) -> Bool {
        allowed(lease.scope) && active?.id == lease.id && active?.scope == lease.scope
    }
    /// Read-only bootstrap before binding community photos. No record creation or lease rotation.
    public func peek(scope: GatewayAvatarReviewScope) async throws -> GatewayAvatarReviewJournalEntry? {
        guard allowed(scope) else { throw GatewayAvatarReviewJournalFailure.inactive }
        let start = epoch
        guard case .entry(let entry) = try await backend.execute(.peek(scope)) else {
            throw GatewayAvatarReviewJournalFailure.unavailable
        }
        guard allowed(scope), epoch == start else { throw GatewayAvatarReviewJournalFailure.inactive }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        return entry
    }
    public func open(scope: GatewayAvatarReviewScope) async throws -> GatewayAvatarReviewJournalLease {
        guard allowed(scope) else { throw GatewayAvatarReviewJournalFailure.inactive }
        active = nil
        epoch = UUID()
        let start = epoch
        guard case .lease(let lease) = try await backend.execute(.open(scope)) else {
            throw GatewayAvatarReviewJournalFailure.unavailable
        }
        guard allowed(scope), epoch == start else {
            _ = try? await backend.execute(.fence(lease))
            throw GatewayAvatarReviewJournalFailure.inactive
        }
        if Task.isCancelled {
            _ = try? await backend.execute(.fence(lease))
            throw GatewayFailure.cancelled
        }
        active = lease
        return lease
    }
    public func fence(_ lease: GatewayAvatarReviewJournalLease) {
        if active?.id == lease.id {
            active = nil
            epoch = UUID()
        }
        let backend = backend
        Task { _ = try? await backend.execute(.fence(lease)) }
    }
    public func fenceForAccountDeletion(binding: GatewayIdentityBinding, accountID: String?) throws {
        guard accountID == nil || gatewayUUID(accountID!) else {
            throw GatewayAvatarReviewJournalFailure.unavailable
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
    private func entry(_ command: AvatarReviewJournalCommand, lease: GatewayAvatarReviewJournalLease)
        async throws -> GatewayAvatarReviewJournalEntry?
    {
        guard isActive(lease) else { throw GatewayAvatarReviewJournalFailure.inactive }
        guard case .entry(let value) = try await backend.execute(command) else {
            throw GatewayAvatarReviewJournalFailure.unavailable
        }
        guard isActive(lease) else { throw GatewayAvatarReviewJournalFailure.inactive }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        return value
    }
    public func pending(lease: GatewayAvatarReviewJournalLease) async throws
        -> GatewayAvatarReviewJournalEntry?
    { try await entry(.pending(lease), lease: lease) }
    public func prepare(_ intent: GatewayAvatarReviewRecoveryIntent, lease: GatewayAvatarReviewJournalLease)
        async throws -> GatewayAvatarReviewJournalEntry
    {
        guard let value = try await entry(.prepare(intent, lease), lease: lease) else {
            throw GatewayAvatarReviewJournalFailure.unavailable
        }
        return value
    }
    public func dispatched(_ value: GatewayAvatarReviewJournalEntry, lease: GatewayAvatarReviewJournalLease)
        async throws -> GatewayAvatarReviewJournalEntry
    {
        guard let result = try await entry(.dispatch(value, lease), lease: lease) else {
            throw GatewayAvatarReviewJournalFailure.unavailable
        }
        return result
    }
    public func resolve(
        _ value: GatewayAvatarReviewJournalEntry, result: GatewayAvatarReviewRecoveryResult,
        lease: GatewayAvatarReviewJournalLease
    ) async throws -> GatewayAvatarReviewJournalEntry {
        guard let value = try await entry(.resolve(value, result, lease), lease: lease) else {
            throw GatewayAvatarReviewJournalFailure.unavailable
        }
        return value
    }
    public func acknowledge(_ value: GatewayAvatarReviewJournalEntry, lease: GatewayAvatarReviewJournalLease)
        async throws
    {
        guard isActive(lease) else { throw GatewayAvatarReviewJournalFailure.inactive }
        _ = try await backend.execute(.acknowledge(value, lease))
        guard isActive(lease) else { throw GatewayAvatarReviewJournalFailure.inactive }
        if Task.isCancelled { throw GatewayFailure.cancelled }
    }
    public func erase(owner: PrivateAccountScope) async throws {
        guard erasedOwners.count < 32 || erasedOwners.contains(owner.digest) else {
            saturated = true
            active = nil
            epoch = UUID()
            throw GatewayAvatarReviewJournalFailure.unavailable
        }
        erasedOwners.insert(owner.digest)
        epoch = UUID()
        if active?.scope.owner == owner { active = nil }
        _ = try await backend.execute(.erase(owner))
    }
}
