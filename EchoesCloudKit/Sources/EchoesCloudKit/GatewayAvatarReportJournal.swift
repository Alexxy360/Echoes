import Foundation
import Observation

public enum GatewayAvatarReportJournalFailure: Error, Equatable, Sendable, LocalizedError {
    case unavailable, inactive, pendingExists, invalidTransition
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Nie udało się bezpiecznie zapisać próby zgłoszenia. Sprawdź zapisaną próbę."
        case .inactive: "Konto lub dostęp do zapisanego zgłoszenia zmieniły się."
        case .pendingExists: "Najpierw sprawdź i potwierdź wynik poprzedniego zgłoszenia."
        case .invalidTransition: "Najpierw odśwież wynik zapisanego zgłoszenia."
        }
    }
}
public struct GatewayAvatarReportScope: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
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
        digest = communityDigest("echoes/avatar-report-journal/v1\0" + community.digest + "\0" + owner.digest)
    }
    public var description: String { "GatewayAvatarReportScope(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReportJournalLease: Sendable, CustomStringConvertible, CustomReflectable {
    let id: String
    let scope: GatewayAvatarReportScope
    public var description: String { "GatewayAvatarReportJournalLease(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayAvatarReportJournalPhase: String, Codable, Sendable {
    case prepared, dispatched, cancelling, resolved
}
public struct GatewayAvatarReportJournalEntry: Equatable, Sendable, CustomStringConvertible, CustomReflectable
{
    public let intent: GatewayAvatarReportIdentity
    public let phase: GatewayAvatarReportJournalPhase
    let revision: String
    public let outcome: GatewayAvatarReportOutcome?
    public var description: String { "GatewayAvatarReportJournalEntry(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Synchronous storage executed only inside the dedicated backend queue transaction.
/// Implementations must isolate this namespace from community journals and credentials.
public protocol GatewayAvatarReportJournalStorage: Sendable {
    func read(scope: GatewayAvatarReportScope) throws -> Data?
    func write(_ data: Data, scope: GatewayAvatarReportScope) throws
    func erase(owner: PrivateAccountScope) throws
}

/// One metadata intent per native/private/origin scope. No target, reason, location, image, bearer or automatic retry.
/// A single Runtime owns the store; leases also fence overlapping host instances on MainActor.
private final class AvatarReportJournalBackend: @unchecked Sendable {
    // All backend fields and synchronous Security calls are confined to this serial GCD queue.
    // Unlike a blocking lock on Swift's cooperative executor, slow IO cannot exhaust that pool.
    private static let queue = DispatchQueue(label: "mpvEcho.Echo.avatar-report-journal", qos: .utility)
    func execute(_ command: AvatarReportJournalCommand) async throws -> AvatarReportJournalReply {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do { continuation.resume(returning: try self.perform(command)) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    private func perform(_ command: AvatarReportJournalCommand) throws -> AvatarReportJournalReply {
        switch command {
        case .open(let scope): return .lease(try open(scope: scope))
        case .pending(let lease): return .entry(try pending(lease: lease))
        case .peek(let scope):
            guard allowed(scope) else { throw GatewayAvatarReportJournalFailure.inactive }
            return .entry(try load(scope)?.entry?.value(accountID: scope.owner.accountID))
        case .prepare(let intent, let lease): return .entry(try prepare(intent, lease: lease))
        case .dispatch(let entry, let lease): return .entry(try dispatched(entry, lease: lease))
        case .cancel(let entry, let lease): return .entry(try cancelling(entry, lease: lease))
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
    private let storage: any GatewayAvatarReportJournalStorage
    private var active: GatewayAvatarReportJournalLease?
    private var erasedOwners = Set<String>()
    private struct Fence {
        let binding: GatewayIdentityBinding
        let accountID: String?
    }
    private var fences: [Fence] = []
    private var saturated = false
    private struct StoredIntent: Codable {
        let requestID: String
        init(_ value: GatewayAvatarReportIdentity) { requestID = value.requestID }
        func value(accountID: String) throws -> GatewayAvatarReportIdentity {
            try .init(accountID: accountID, requestID: requestID)
        }
    }
    private struct StoredEntry: Codable {
        let intent: StoredIntent
        var phase: GatewayAvatarReportJournalPhase
        var revision: String
        var outcome: String?
        func value(accountID: String) throws -> GatewayAvatarReportJournalEntry {
            let intent = try intent.value(accountID: accountID)
            guard gatewayUUID(revision) else { throw GatewayAvatarReportJournalFailure.unavailable }
            let result = outcome.flatMap(GatewayAvatarReportOutcome.init(rawValue:))
            switch (phase, outcome, result) {
            case (.prepared, nil, nil), (.dispatched, nil, nil), (.dispatched, "unconfirmed", .unconfirmed),
                (.cancelling, nil, nil), (.cancelling, "accepted", .accepted),
                (.cancelling, "unconfirmed", .unconfirmed),
                (.resolved, "accepted", .accepted), (.resolved, "cancelled", .cancelled):
                break
            default: throw GatewayAvatarReportJournalFailure.unavailable
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
    public init(storage: any GatewayAvatarReportJournalStorage) { self.storage = storage }
    private func allowed(_ scope: GatewayAvatarReportScope) -> Bool {
        !saturated && !erasedOwners.contains(scope.owner.digest)
            && !fences.contains {
                $0.binding == scope.binding && ($0.accountID == nil || $0.accountID == scope.owner.accountID)
            }
    }
    private func load(_ scope: GatewayAvatarReportScope) throws -> Record? {
        do {
            guard let data = try storage.read(scope: scope) else { return nil }
            guard data.count <= 4096 else { throw GatewayAvatarReportJournalFailure.unavailable }
            let value = try JSONDecoder().decode(Record.self, from: data)
            guard value.schemaVersion == 1, value.scope == scope.digest, value.owner == scope.owner.digest,
                gatewayUUID(value.lease)
            else { throw GatewayAvatarReportJournalFailure.unavailable }
            _ = try value.entry?.value(accountID: scope.owner.accountID)
            // Require the canonical closed encoding, including absence of unsupported fields.
            let encoded = try JSONEncoder().encode(value)
            guard
                (try JSONSerialization.jsonObject(with: data) as? NSDictionary)
                    == (try JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            else { throw GatewayAvatarReportJournalFailure.unavailable }
            return value
        } catch { throw GatewayAvatarReportJournalFailure.unavailable }
    }
    private func save(_ record: Record, scope: GatewayAvatarReportScope) throws {
        do {
            let data = try JSONEncoder().encode(record)
            guard data.count <= 4096 else { throw GatewayAvatarReportJournalFailure.unavailable }
            try storage.write(data, scope: scope)
            guard try storage.read(scope: scope) == data else {
                throw GatewayAvatarReportJournalFailure.unavailable
            }
        } catch { throw GatewayAvatarReportJournalFailure.unavailable }
    }
    private func open(scope: GatewayAvatarReportScope) throws -> GatewayAvatarReportJournalLease {
        guard allowed(scope) else { throw GatewayAvatarReportJournalFailure.inactive }
        active = nil
        let id = UUID().uuidString.lowercased()
        var value =
            try load(scope)
            ?? Record(schemaVersion: 1, scope: scope.digest, owner: scope.owner.digest, lease: id, entry: nil)
        value.lease = id
        try save(value, scope: scope)
        let lease = GatewayAvatarReportJournalLease(id: id, scope: scope)
        active = lease
        return lease
    }
    private func current(_ lease: GatewayAvatarReportJournalLease) throws -> Record {
        guard allowed(lease.scope), active?.id == lease.id, active?.scope == lease.scope,
            let value = try load(lease.scope), value.lease == lease.id
        else { throw GatewayAvatarReportJournalFailure.inactive }
        return value
    }
    private func fence(_ lease: GatewayAvatarReportJournalLease) {
        if active?.id == lease.id { active = nil }
    }
    private func fenceForAccountDeletion(binding: GatewayIdentityBinding, accountID: String?) throws {
        guard accountID == nil || gatewayUUID(accountID!) else {
            throw GatewayAvatarReportJournalFailure.unavailable
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
    private func pending(lease: GatewayAvatarReportJournalLease) throws -> GatewayAvatarReportJournalEntry? {
        try current(lease).entry?.value(accountID: lease.scope.owner.accountID)
    }
    private func prepare(_ intent: GatewayAvatarReportIdentity, lease: GatewayAvatarReportJournalLease)
        throws -> GatewayAvatarReportJournalEntry
    {
        var value = try current(lease)
        guard intent.accountID == lease.scope.owner.accountID else {
            throw GatewayAvatarReportJournalFailure.invalidTransition
        }
        guard value.entry == nil else { throw GatewayAvatarReportJournalFailure.pendingExists }
        value.entry = .init(
            intent: StoredIntent(intent), phase: .prepared, revision: UUID().uuidString.lowercased(),
            outcome: nil)
        try save(value, scope: lease.scope)
        return try value.entry!.value(accountID: lease.scope.owner.accountID)
    }
    private func dispatched(_ entry: GatewayAvatarReportJournalEntry, lease: GatewayAvatarReportJournalLease)
        throws -> GatewayAvatarReportJournalEntry
    {
        var value = try exact(entry, lease)
        guard entry.phase == .prepared, entry.outcome == nil else {
            throw GatewayAvatarReportJournalFailure.invalidTransition
        }
        value.entry!.phase = .dispatched
        value.entry!.revision = UUID().uuidString.lowercased()
        try save(value, scope: lease.scope)
        return try value.entry!.value(accountID: lease.scope.owner.accountID)
    }
    private func cancelling(_ entry: GatewayAvatarReportJournalEntry, lease: GatewayAvatarReportJournalLease)
        throws -> GatewayAvatarReportJournalEntry
    {
        var value = try exact(entry, lease)
        guard entry.phase != .resolved else { throw GatewayAvatarReportJournalFailure.invalidTransition }
        value.entry!.phase = .cancelling
        value.entry!.revision = UUID().uuidString.lowercased()
        try save(value, scope: lease.scope)
        return try value.entry!.value(accountID: lease.scope.owner.accountID)
    }
    private func resolve(
        _ entry: GatewayAvatarReportJournalEntry, result: GatewayAvatarReportResult,
        lease: GatewayAvatarReportJournalLease
    ) throws -> GatewayAvatarReportJournalEntry {
        var value = try exact(entry, lease)
        guard result.identity == entry.intent, entry.phase != .resolved else {
            throw GatewayAvatarReportJournalFailure.invalidTransition
        }
        if result.outcome == .cancelled {
            value.entry!.phase = .resolved
        } else if entry.phase == .cancelling {
            // An accepted original report is not proof that its cancellation completed.
            value.entry!.phase = .cancelling
        } else {
            value.entry!.phase = result.outcome == .accepted ? .resolved : .dispatched
        }
        value.entry!.revision = UUID().uuidString.lowercased()
        // Unconfirmed is not a terminal absence proof. Keep this exact attempt pending;
        // it cannot be acknowledged, replaced or sent again after a read-only recovery.
        value.entry!.outcome = result.outcome.rawValue
        let result = try value.entry!.value(accountID: lease.scope.owner.accountID)
        try save(value, scope: lease.scope)
        return result
    }
    private func exact(_ entry: GatewayAvatarReportJournalEntry, _ lease: GatewayAvatarReportJournalLease)
        throws -> Record
    {
        let value = try current(lease)
        guard try value.entry?.value(accountID: lease.scope.owner.accountID) == entry else {
            throw GatewayAvatarReportJournalFailure.inactive
        }
        return value
    }
    private func acknowledge(_ entry: GatewayAvatarReportJournalEntry, lease: GatewayAvatarReportJournalLease)
        throws
    {
        var value = try exact(entry, lease)
        guard entry.phase == .resolved, entry.outcome == .accepted || entry.outcome == .cancelled else {
            throw GatewayAvatarReportJournalFailure.invalidTransition
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
        do { try storage.erase(owner: owner) } catch { throw GatewayAvatarReportJournalFailure.unavailable }
    }
}

private enum AvatarReportJournalCommand: Sendable {
    case open(GatewayAvatarReportScope)
    case peek(GatewayAvatarReportScope)
    case pending(GatewayAvatarReportJournalLease)
    case prepare(GatewayAvatarReportIdentity, GatewayAvatarReportJournalLease)
    case dispatch(GatewayAvatarReportJournalEntry, GatewayAvatarReportJournalLease)
    case cancel(GatewayAvatarReportJournalEntry, GatewayAvatarReportJournalLease)
    case resolve(
        GatewayAvatarReportJournalEntry, GatewayAvatarReportResult, GatewayAvatarReportJournalLease)
    case acknowledge(GatewayAvatarReportJournalEntry, GatewayAvatarReportJournalLease)
    case fence(GatewayAvatarReportJournalLease)
    case deletion(GatewayIdentityBinding, String?)
    case erase(PrivateAccountScope)
}
private enum AvatarReportJournalReply: Sendable {
    case lease(GatewayAvatarReportJournalLease)
    case entry(GatewayAvatarReportJournalEntry?)
    case none
}

/// Observable UI fence with serialized storage IO off MainActor. No suspension within a backend
/// read/check/write/readback transaction; every awaited result rechecks this foreground lease.
@MainActor @Observable public final class GatewayAvatarReportJournal {
    private let backend: AvatarReportJournalBackend
    private var active: GatewayAvatarReportJournalLease?
    private var epoch = UUID()
    private var erasedOwners = Set<String>()
    private struct Fence {
        let binding: GatewayIdentityBinding
        let accountID: String?
    }
    private var fences: [Fence] = []
    private var saturated = false
    public init(storage: any GatewayAvatarReportJournalStorage) {
        backend = AvatarReportJournalBackend(storage: storage)
    }
    private func allowed(_ scope: GatewayAvatarReportScope) -> Bool {
        !saturated && !erasedOwners.contains(scope.owner.digest)
            && !fences.contains {
                $0.binding == scope.binding && ($0.accountID == nil || $0.accountID == scope.owner.accountID)
            }
    }
    public func isActive(_ lease: GatewayAvatarReportJournalLease) -> Bool {
        allowed(lease.scope) && active?.id == lease.id && active?.scope == lease.scope
    }
    /// Read-only bootstrap before binding the photo report form. No record creation or lease rotation.
    public func peek(scope: GatewayAvatarReportScope) async throws -> GatewayAvatarReportJournalEntry? {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard allowed(scope) else { throw GatewayAvatarReportJournalFailure.inactive }
        let start = epoch
        guard case .entry(let entry) = try await backend.execute(.peek(scope)) else {
            throw GatewayAvatarReportJournalFailure.unavailable
        }
        guard allowed(scope), epoch == start else { throw GatewayAvatarReportJournalFailure.inactive }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        return entry
    }
    public func open(scope: GatewayAvatarReportScope) async throws -> GatewayAvatarReportJournalLease {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard allowed(scope) else { throw GatewayAvatarReportJournalFailure.inactive }
        active = nil
        epoch = UUID()
        let start = epoch
        guard case .lease(let lease) = try await backend.execute(.open(scope)) else {
            throw GatewayAvatarReportJournalFailure.unavailable
        }
        guard allowed(scope), epoch == start else {
            _ = try? await backend.execute(.fence(lease))
            throw GatewayAvatarReportJournalFailure.inactive
        }
        if Task.isCancelled {
            _ = try? await backend.execute(.fence(lease))
            throw GatewayFailure.cancelled
        }
        active = lease
        return lease
    }
    public func fence(_ lease: GatewayAvatarReportJournalLease) {
        if active?.id == lease.id {
            active = nil
            epoch = UUID()
        }
        let backend = backend
        Task { _ = try? await backend.execute(.fence(lease)) }
    }
    public func fenceForAccountDeletion(binding: GatewayIdentityBinding, accountID: String?) throws {
        guard accountID == nil || gatewayUUID(accountID!) else {
            throw GatewayAvatarReportJournalFailure.unavailable
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
    private func entry(_ command: AvatarReportJournalCommand, lease: GatewayAvatarReportJournalLease)
        async throws -> GatewayAvatarReportJournalEntry?
    {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isActive(lease) else { throw GatewayAvatarReportJournalFailure.inactive }
        guard case .entry(let value) = try await backend.execute(command) else {
            throw GatewayAvatarReportJournalFailure.unavailable
        }
        guard isActive(lease) else { throw GatewayAvatarReportJournalFailure.inactive }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        return value
    }
    public func pending(lease: GatewayAvatarReportJournalLease) async throws
        -> GatewayAvatarReportJournalEntry?
    { try await entry(.pending(lease), lease: lease) }
    public func prepare(_ intent: GatewayAvatarReportIdentity, lease: GatewayAvatarReportJournalLease)
        async throws -> GatewayAvatarReportJournalEntry
    {
        guard let value = try await entry(.prepare(intent, lease), lease: lease) else {
            throw GatewayAvatarReportJournalFailure.unavailable
        }
        return value
    }
    public func dispatched(_ value: GatewayAvatarReportJournalEntry, lease: GatewayAvatarReportJournalLease)
        async throws -> GatewayAvatarReportJournalEntry
    {
        guard let result = try await entry(.dispatch(value, lease), lease: lease) else {
            throw GatewayAvatarReportJournalFailure.unavailable
        }
        return result
    }
    /// Persist this transition before cancellation IO. Retry only this same identity;
    /// accepted/unconfirmed recovery cannot release it while cancellation remains uncertain.
    public func cancelling(_ value: GatewayAvatarReportJournalEntry, lease: GatewayAvatarReportJournalLease)
        async throws -> GatewayAvatarReportJournalEntry
    {
        guard let result = try await entry(.cancel(value, lease), lease: lease) else {
            throw GatewayAvatarReportJournalFailure.unavailable
        }
        return result
    }
    public func resolve(
        _ value: GatewayAvatarReportJournalEntry, result: GatewayAvatarReportResult,
        lease: GatewayAvatarReportJournalLease
    ) async throws -> GatewayAvatarReportJournalEntry {
        guard let value = try await entry(.resolve(value, result, lease), lease: lease) else {
            throw GatewayAvatarReportJournalFailure.unavailable
        }
        return value
    }
    public func acknowledge(_ value: GatewayAvatarReportJournalEntry, lease: GatewayAvatarReportJournalLease)
        async throws
    {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isActive(lease) else { throw GatewayAvatarReportJournalFailure.inactive }
        _ = try await backend.execute(.acknowledge(value, lease))
        guard isActive(lease) else { throw GatewayAvatarReportJournalFailure.inactive }
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
