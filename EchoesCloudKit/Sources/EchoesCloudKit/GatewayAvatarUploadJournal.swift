import Foundation

/// Durable owner intent and only the prepared JPEG, in one atomic envelope. This actor must be
/// shared across foreground domains. Its lease is not a gateway/native authorization by itself.
public actor GatewayAvatarUploadJournal {
    private let files: AvatarUploadJournalFiles
    private let clock: @Sendable () -> Date
    private var active: GatewayAvatarUploadJournalLease?
    private var erasedOwners: Set<String> = []
    private struct DeletionFence {
        let binding: GatewayIdentityBinding
        let accountID: String?
    }
    private var deletionFences: [DeletionFence] = []
    private var saturated = false
    public init(root: URL, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        files = try AvatarUploadJournalFiles(root: root)
        self.clock = clock
    }
    init(
        root: URL, clock: @escaping @Sendable () -> Date,
        fault: @escaping @Sendable (AvatarUploadJournalFiles.WritePoint) throws -> Void
    ) throws {
        files = try AvatarUploadJournalFiles(root: root, fault: fault)
        self.clock = clock
    }
    /// Explicitly ending the store releases its lifetime lock. Every old handle stays closed.
    public func close() {
        active = nil
        files.shutdown()
    }
    private func timestamp() throws -> Double {
        let now = clock().timeIntervalSince1970
        guard now.isFinite, now >= 0, now < 9_007_199_254_740 else {
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
        return now
    }
    private func check(_ lease: GatewayAvatarUploadJournalLease) throws {
        try Task.checkCancellation()
        guard allowed(lease.scope),
            active?.id == lease.id, active?.scope == lease.scope
        else { throw GatewayAvatarUploadJournalFailure.inactive }
    }
    private func allowed(_ scope: GatewayAvatarUploadScope) -> Bool {
        files.isOpen && !saturated && !erasedOwners.contains(scope.privateScope.digest)
            && !deletionFences.contains {
                $0.binding == scope.binding
                    && ($0.accountID == nil || $0.accountID == scope.privateScope.accountID)
            }
    }
    private func save(_ value: AvatarUploadEnvelope, scope: GatewayAvatarUploadScope) throws {
        do { try files.write(AvatarUploadRecordCodec.encode(value), scope: scope) } catch is CancellationError
        { throw CancellationError() } catch let error as GatewayAvatarUploadJournalFailure {
            throw error
        } catch { throw GatewayAvatarUploadJournalFailure.unavailable }
    }
    private func current(_ lease: GatewayAvatarUploadJournalLease) throws -> AvatarUploadEnvelope {
        try check(lease)
        guard let bytes = try files.read(lease.scope) else {
            throw GatewayAvatarUploadJournalFailure.inactive
        }
        let value = try AvatarUploadRecordCodec.decode(bytes, scope: lease.scope)
        guard value.record.lease == lease.id else { throw GatewayAvatarUploadJournalFailure.inactive }
        if let entry = value.record.entry, entry.createdAt > (try timestamp()) + 300 {
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
        return value
    }
    private func expire(_ value: inout AvatarUploadEnvelope) throws -> Bool {
        guard var entry = value.record.entry else { return false }
        let now = try timestamp()
        guard entry.createdAt <= now + 300 else { throw GatewayAvatarUploadJournalFailure.unavailable }
        guard entry.sourcePresent == true, now - entry.createdAt >= AvatarUploadRecordCodec.sourceLifetime
        else { return false }
        entry.sourcePresent = false
        entry.revision = UUID().uuidString.lowercased()
        value.record.entry = entry
        value.source = Data()
        return true
    }
    /// Reopening preserves the pending intent but rotates its durable lease. No ID is auto-retried.
    public func open(scope: GatewayAvatarUploadScope) throws -> GatewayAvatarUploadJournalLease {
        try Task.checkCancellation()
        guard allowed(scope) else {
            throw GatewayAvatarUploadJournalFailure.inactive
        }
        _ = try timestamp()
        active = nil
        let id = UUID().uuidString.lowercased()
        var value: AvatarUploadEnvelope
        if let bytes = try files.read(scope) {
            value = try AvatarUploadRecordCodec.decode(bytes, scope: scope)
        } else {
            value = .init(
                record: .init(
                    schemaVersion: 1, privateScope: scope.privateScope.digest, scope: scope.digest, lease: id,
                    entry: nil), source: Data())
        }
        value.record.lease = id
        _ = try expire(&value)
        try save(value, scope: scope)
        let lease = GatewayAvatarUploadJournalLease(id: id, scope: scope)
        active = lease
        return lease
    }
    public func fence(_ lease: GatewayAvatarUploadJournalLease) {
        if active?.id == lease.id, active?.scope == lease.scope { active = nil }
    }
    public func fence(binding: GatewayIdentityBinding, accountID: String?) {
        guard let active, active.scope.binding == binding,
            accountID == nil || active.scope.privateScope.accountID == accountID
        else { return }
        self.active = nil
    }
    /// Deletion is stronger than ordinary suspension: queued opens for this verified native owner
    /// must remain blocked even when an earlier cleanup callback fails before erase reaches us.
    public func fenceForAccountDeletion(binding: GatewayIdentityBinding, accountID: String?) throws {
        guard accountID == nil || gatewayUUID(accountID!) else {
            throw GatewayAvatarUploadJournalFailure.invalidData
        }
        fence(binding: binding, accountID: accountID)
        guard !deletionFences.contains(where: { $0.binding == binding && $0.accountID == accountID }) else {
            return
        }
        if deletionFences.count >= 32 {
            saturated = true
            active = nil
        } else {
            deletionFences.append(.init(binding: binding, accountID: accountID))
        }
    }
    public func pending(lease: GatewayAvatarUploadJournalLease) throws -> GatewayAvatarUploadJournalEntry? {
        var value = try current(lease)
        if try expire(&value) { try save(value, scope: lease.scope) }
        return try value.record.entry?.entry()
    }
    public func prepareUpload(
        intent: GatewayAvatarUploadIntent, avatar: PreparedAvatar, lease: GatewayAvatarUploadJournalLease
    ) throws -> GatewayAvatarUploadJournalEntry {
        var value = try current(lease)
        guard value.record.entry == nil else { throw GatewayAvatarUploadJournalFailure.pendingExists }
        let size = try AvatarUploadRecordCodec.image(avatar.image)
        value.record.entry = .init(
            revision: UUID().uuidString.lowercased(), kind: "upload", requestID: intent.requestID,
            expectedGeneration: intent.expectedGeneration, phase: .prepared, createdAt: try timestamp(),
            versionID: intent.versionID, consentVersion: intent.consentVersion,
            sourceSHA256: AvatarUploadRecordCodec.digest(avatar.image), sourceByteCount: avatar.image.count,
            width: size.width, height: size.height, sourcePresent: true)
        value.source = avatar.image
        try save(value, scope: lease.scope)
        return try value.record.entry!.entry()
    }
    /// Explicit withdrawal may replace an exact pending entry, atomically dropping its local JPEG.
    /// Native host must obtain fresh server generation and user intent before requesting replacement.
    public func prepareClear(
        requestID: String, expectedGeneration: Int,
        replacing expected: GatewayAvatarUploadJournalEntry? = nil,
        lease: GatewayAvatarUploadJournalLease
    ) throws -> GatewayAvatarUploadJournalEntry {
        _ = try GatewayAvatarMutation.clear(requestID: requestID, expectedGeneration: expectedGeneration)
            .wire()
        var value = try current(lease)
        guard try value.record.entry?.entry() == expected else {
            throw GatewayAvatarUploadJournalFailure.superseded
        }
        if let old = value.record.entry, old.requestID == requestID {
            guard try old.intent() == .clear(requestID: requestID, expectedGeneration: expectedGeneration)
            else { throw GatewayAvatarUploadJournalFailure.invalidData }
            return try old.entry()
        }
        value.record.entry = .init(
            revision: UUID().uuidString.lowercased(), kind: "clear", requestID: requestID,
            expectedGeneration: expectedGeneration, phase: .prepared, createdAt: try timestamp())
        value.source = Data()
        try save(value, scope: lease.scope)
        return try value.record.entry!.entry()
    }
    private func matched(_ expected: GatewayAvatarUploadJournalEntry, lease: GatewayAvatarUploadJournalLease)
        throws -> AvatarUploadEnvelope
    {
        let value = try current(lease)
        guard try value.record.entry?.entry() == expected else {
            throw GatewayAvatarUploadJournalFailure.superseded
        }
        return value
    }
    public func source(for expected: GatewayAvatarUploadJournalEntry, lease: GatewayAvatarUploadJournalLease)
        throws -> Data
    {
        var value = try matched(expected, lease: lease)
        if try expire(&value) { try save(value, scope: lease.scope) }
        guard value.record.entry?.sourcePresent == true else {
            throw GatewayAvatarUploadJournalFailure.sourceUnavailable
        }
        return value.source
    }
    /// Records dispatch BEFORE HTTP. Repeating dispatched/publishing is an explicit host action,
    /// never an automatic network retry. Every transition fences stale acknowledgements by revision.
    public func transition(
        _ expected: GatewayAvatarUploadJournalEntry, to phase: GatewayAvatarJournalPhase,
        lease: GatewayAvatarUploadJournalLease
    ) throws -> GatewayAvatarUploadJournalEntry {
        var value = try matched(expected, lease: lease)
        if try expire(&value) {
            try save(value, scope: lease.scope)
            throw GatewayAvatarUploadJournalFailure.superseded
        }
        var entry = value.record.entry!
        let allowed: Bool
        if entry.kind == "clear" {
            allowed = phase == .dispatched && (entry.phase == .prepared || entry.phase == .dispatched)
        } else {
            switch (entry.phase, phase) {
            case (.prepared, .dispatched), (.dispatched, .dispatched), (.dispatched, .staged),
                (.staged, .staged),
                (.staged, .publishing), (.publishing, .publishing), (.publishing, .staged):
                allowed = true
            default: allowed = false
            }
        }
        guard allowed else { throw GatewayAvatarUploadJournalFailure.invalidTransition }
        if entry.kind == "upload", phase == .dispatched, entry.sourcePresent != true {
            throw GatewayAvatarUploadJournalFailure.sourceUnavailable
        }
        entry.phase = phase
        entry.revision = UUID().uuidString.lowercased()
        value.record.entry = entry
        try save(value, scope: lease.scope)
        return try entry.entry()
    }
    /// Only after verified completion or an explicit local-discard decision in the future owner UI.
    public func remove(_ expected: GatewayAvatarUploadJournalEntry, lease: GatewayAvatarUploadJournalLease)
        throws
    {
        var value = try matched(expected, lease: lease)
        value.record.entry = nil
        value.source = Data()
        try save(value, scope: lease.scope)
    }
    /// Exact private-account cleanup across its origins/native bindings. Volatile erased-scope
    /// fences block queued opens too; saturation closes writes until a fresh store after restart.
    public func erase(scope: PrivateAccountScope) throws {
        if active?.scope.privateScope == scope { active = nil }
        if !erasedOwners.contains(scope.digest) {
            if erasedOwners.count >= 32 {
                saturated = true
                active = nil
            } else {
                erasedOwners.insert(scope.digest)
            }
        }
        try files.erase(scope)
    }
}
