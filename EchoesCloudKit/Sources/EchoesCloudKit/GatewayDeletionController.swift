import Foundation
import Observation

/// Native host supplies fresh Apple proof, lifecycle notifications, and REAL access/cache callbacks.
/// No dependency has a successful default. There is no automatic sheet, code replay or cleanup loop.
@MainActor @Observable public final class GatewayDeletionController {
    public enum Phase: Equatable {
        case suspended, idle, working, ready, awaitingServer, completed, failed, storageBlocked
    }
    public private(set) var phase: Phase = .suspended
    public private(set) var progress: GatewayDeletionProgress?
    public private(set) var errorMessage: String?
    public var isBusy: Bool { busy != nil }
    @ObservationIgnored private let configuration: CloudKitConfiguration
    @ObservationIgnored private let binding: GatewayIdentityBinding
    @ObservationIgnored private let api: any GatewayAccountDeletionAPI
    @ObservationIgnored private let storage: any GatewayDeletionStorage
    @ObservationIgnored private let account: CloudKitAccountSession
    @ObservationIgnored private let cleanup: any GatewayPrivateAccountCleanup
    @ObservationIgnored private let fenceLocalAccess:
        @MainActor (GatewayIdentityBinding, String?) async throws -> Void
    @ObservationIgnored private let clearLocalData: @MainActor (PrivateAccountScope) async throws -> Void
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    private var foreground = false
    private var generation = UUID()
    private var busy: UUID?
    private struct Operation {
        let id: UUID
        let generation: UUID
        let cloudRevision: UInt64
    }

    public init(
        configuration: CloudKitConfiguration, binding: GatewayIdentityBinding,
        api: any GatewayAccountDeletionAPI, storage: any GatewayDeletionStorage,
        account: CloudKitAccountSession, cleanup: any GatewayPrivateAccountCleanup,
        isEnabled: @escaping @MainActor () -> Bool, now: @escaping @Sendable () -> Date = { Date() },
        fenceLocalAccess: @escaping @MainActor (GatewayIdentityBinding, String?) async throws -> Void,
        clearLocalData: @escaping @MainActor (PrivateAccountScope) async throws -> Void
    ) {
        self.configuration = configuration
        self.binding = binding
        self.api = api
        self.storage = storage
        self.account = account
        self.cleanup = cleanup
        self.isEnabled = isEnabled
        self.now = now
        self.fenceLocalAccess = fenceLocalAccess
        self.clearLocalData = clearLocalData
    }
    /// Host must invoke suspend synchronously on background/lock or native iCloud change.
    /// Apple authorization revocation alone does not remove a deletion ticket or prohibit erasure.
    public func activate() {
        foreground = true
        if busy == nil { phase = .idle }
    }
    public func suspend() {
        foreground = false
        generation = UUID()
        busy = nil
        progress = nil
        errorMessage = nil
        phase = .suspended
    }
    public func ownedRequests() async throws -> [GatewayDeletionProgress] {
        try await work { operation in
            try self.check(operation)
            return try self.read().requests.filter { $0.binding == self.binding }.map(self.summary)
        }
    }
    /// Reuses the same unconfirmed ticket after a lost initial response; persists BEFORE dispatch.
    public func request(
        challenge: GatewayChallenge, proof: AppleGatewayProof, expectedAccountID: String?,
        journalID: String? = nil
    )
        async throws -> GatewayDeletionProgress
    {
        try await work { operation in
            let verified = try self.verifiedProof(challenge, proof, expectedAccountID: expectedAccountID)
            var journal = try self.read()
            let pending = journal.requests.filter {
                $0.binding == self.binding && !self.summary($0).completed
            }
            let id: String
            if let journalID {
                let previous = try self.entry(journalID)
                guard previous.ticket != nil, previous.status == nil, previous.accountID == expectedAccountID
                else { throw GatewayDeletionFailure.freshProofRequired }
                id = journalID
                let index = journal.requests.firstIndex(where: { $0.journalID == id })!
                journal.requests[index].phase = .requestPending
                journal.requests[index].attemptID = UUID().uuidString.lowercased()
                try self.write(journal)
            } else if let previous = pending.first {
                guard pending.count == 1 else { throw GatewayFailure.operationInProgress }
                guard previous.phase == .requestPending, previous.accountID == expectedAccountID else {
                    throw GatewayDeletionFailure.freshProofRequired
                }
                id = previous.journalID
                let index = journal.requests.firstIndex(where: { $0.journalID == id })!
                journal.requests[index].attemptID = UUID().uuidString.lowercased()
                try self.write(journal)
            } else {
                guard journal.requests.count < 8 else { throw GatewayDeletionFailure.journalFull }
                let ticket = try GatewayDeletionTicket.create()
                id = UUID().uuidString.lowercased()
                journal.requests.append(
                    .init(
                        journalID: id, binding: self.binding, phase: .requestPending,
                        ticket: ticket, accountID: expectedAccountID))
                try self.write(journal)
            }
            let entry = try self.entry(id)
            let ticket = try self.ticket(entry)
            try await self.fence(operation, accountID: expectedAccountID)
            let status = try await self.api.requestDeletion(ticket: ticket, proof: verified)
            try self.check(operation)
            try self.accept(
                status, ticket: ticket, id: id, requiredPhase: .requestPending, attemptID: entry.attemptID)
            return try self.publish(id)
        }
    }
    /// Lost/rotated ticket recovery always needs a NEW native challenge/proof. The old ticket is
    /// retained but unavailable for cleanup while recoveryPending; a late response cannot replace it.
    public func recover(
        challenge: GatewayChallenge, proof: AppleGatewayProof, expectedAccountID: String?,
        journalID: String? = nil
    ) async throws -> GatewayDeletionProgress {
        try await work { operation in
            let verified = try self.verifiedProof(challenge, proof, expectedAccountID: expectedAccountID)
            var journal = try self.read()
            let id: String
            let outstanding = journal.requests.first(where: {
                $0.binding == self.binding && $0.phase == .recoveryPending
            })
            if let selected = journalID ?? outstanding?.journalID {
                guard outstanding == nil || outstanding?.journalID == selected else {
                    throw GatewayFailure.operationInProgress
                }
                let existing = try self.entry(selected)
                guard expectedAccountID == existing.accountID else { throw GatewayFailure.accountMismatch }
                id = selected
                let index = journal.requests.firstIndex(where: { $0.journalID == id })!
                journal.requests[index].phase = .recoveryPending
                journal.requests[index].attemptID = UUID().uuidString.lowercased()
            } else {
                guard journal.requests.count < 8 else { throw GatewayDeletionFailure.journalFull }
                id = UUID().uuidString.lowercased()
                journal.requests.append(
                    .init(
                        journalID: id, binding: self.binding, phase: .recoveryPending,
                        accountID: expectedAccountID))
            }
            try self.write(journal)
            let attemptID = journal.requests.first(where: { $0.journalID == id })!.attemptID
            if let expectedAccountID { try await self.fence(operation, accountID: expectedAccountID) }
            let response = try await self.api.recoverDeletion(proof: verified)
            try self.check(operation)
            try response.status.validate(deletionID: response.ticket.deletionID, accountID: expectedAccountID)
            journal = try self.read()
            guard let index = journal.requests.firstIndex(where: { $0.journalID == id }),
                journal.requests[index].binding == self.binding,
                journal.requests[index].phase == .recoveryPending,
                journal.requests[index].attemptID == attemptID
            else { throw GatewayFailure.superseded }
            if let old = journal.requests.first(where: {
                $0.journalID != id && $0.binding == self.binding
                    && $0.ticket?.deletionID == response.ticket.deletionID
            }) {
                guard old.accountID == response.status.accountID else { throw GatewayFailure.accountMismatch }
                var merged = old
                merged.phase = .accepted
                merged.attemptID = attemptID
                merged.ticket = response.ticket
                merged.status = response.status
                journal.requests.removeAll { $0.journalID == id || $0.journalID == old.journalID }
                journal.requests.append(merged)
                try self.write(journal)
                try await self.fence(operation, accountID: response.status.accountID)
                return try self.publish(old.journalID)
            }
            let old = journal.requests[index]
            if let oldTicket = old.ticket {
                guard oldTicket.deletionID == response.ticket.deletionID,
                    old.accountID == nil || old.accountID == response.status.accountID
                else { throw GatewayFailure.accountMismatch }
            }
            journal.requests[index].phase = .accepted
            journal.requests[index].ticket = response.ticket
            journal.requests[index].accountID = response.status.accountID
            journal.requests[index].status = response.status
            try self.write(journal)
            try await self.fence(operation, accountID: response.status.accountID)
            return try self.publish(id)
        }
    }
    /// Read-only/idempotent recovery of an existing initial request. Never sends an Apple proof.
    public func poll(journalID: String) async throws -> GatewayDeletionProgress {
        try await work { operation in
            let entry = try self.entry(journalID)
            guard entry.phase != .recoveryPending else { throw GatewayDeletionFailure.freshProofRequired }
            try await self.fence(operation, accountID: entry.accountID)
            let ticket = try self.ticket(entry)
            let status =
                entry.phase == .requestPending
                ? try await self.api.requestDeletion(ticket: ticket, proof: nil)
                : try await self.api.deletionStatus(ticket: ticket)
            try self.check(operation)
            try self.accept(
                status, ticket: ticket, id: journalID, requiredPhase: entry.phase, attemptID: entry.attemptID)
            return try self.publish(journalID)
        }
    }
    /// At most ONE private page. The host schedules further explicit steps while foregrounded.
    /// Persisted content/local checkpoints survive failures; ACK is sent only after both succeed.
    public func advance(journalID: String) async throws -> GatewayDeletionProgress {
        try await work { operation in
            var entry = try self.entry(journalID)
            guard entry.phase == .accepted else { throw GatewayDeletionFailure.freshProofRequired }
            try await self.fence(operation, accountID: entry.accountID)
            let status = try await self.authorize(entry, operation: operation)
            try self.accept(
                status, ticket: self.ticket(entry), id: journalID, requiredPhase: .accepted,
                attemptID: entry.attemptID)
            entry = try self.entry(journalID)
            let scope = try self.scope(entry)
            if !entry.contentDeleted {
                if let cursor = entry.cursor {
                    try self.validate(cursor, scope: scope, ticket: self.ticket(entry))
                }
                let captured = entry
                let result = try await self.cleanup.step(
                    scope: scope, deletionID: self.ticket(entry).deletionID, cursor: entry.cursor
                ) { requestedScope in
                    try self.check(operation)
                    guard requestedScope == scope else { throw GatewayFailure.accountMismatch }
                    _ = try await self.authorize(captured, operation: operation)
                }
                try self.check(operation)
                guard result.scope == scope, (0...100).contains(result.deletedRecords),
                    result.contentDeleted == (result.cursor == nil)
                else { throw GatewayFailure.invalidResponse }
                if let cursor = result.cursor {
                    try self.validate(cursor, scope: scope, ticket: self.ticket(captured))
                }
                try self.update(journalID) { current in
                    try self.requireSameCheckpoint(current, captured)
                    current.cursor = result.cursor
                    current.contentDeleted = result.contentDeleted
                }
                entry = try self.entry(journalID)
                if !entry.contentDeleted { return try self.publish(journalID) }
            }
            if !entry.localDataDeleted {
                let captured = entry
                try self.check(operation)
                try await self.clearLocalData(scope)
                try self.check(operation)
                try self.update(journalID) { current in
                    try self.requireSameCheckpoint(current, captured)
                    current.localDataDeleted = true
                }
                entry = try self.entry(journalID)
            }
            if !entry.ownAcknowledgement {
                let ticket = try self.ticket(entry)
                let acknowledgement = try await self.api.acknowledgePrivateCleanup(ticket: ticket)
                try self.check(operation)
                try acknowledgement.validate(deletionID: ticket.deletionID, accountID: entry.accountID)
                guard acknowledgement.privateData == .deviceAcknowledged else {
                    throw GatewayFailure.invalidResponse
                }
                let captured = entry
                try self.update(journalID) { current in
                    try self.requireSameCheckpoint(current, captured)
                    current.status = acknowledgement
                    current.ownAcknowledgement = true
                }
            }
            return try self.publish(journalID)
        }
    }
    /// A deliberate rescan after token expiry/unknown provider outcome; does not retry the SDK now.
    public func restartPrivateScan(journalID: String) async throws -> GatewayDeletionProgress {
        try await work { operation in
            let entry = try self.entry(journalID)
            _ = try await self.authorize(entry, operation: operation)
            try self.update(journalID) { current in
                try self.requireSameCheckpoint(current, entry)
                current.cursor = nil
                current.contentDeleted = false
                current.localDataDeleted = false
                current.ownAcknowledgement = false
            }
            return try self.publish(journalID)
        }
    }

    /// Explicit local removal of a fully completed receipt. No gateway calls or content erasure.
    /// The immutable displayed snapshot pins the attempt/status; a rotated receipt cannot be lost.
    public func forgetCompleted(receipt: GatewayDeletionProgress) async throws {
        try await work { operation in
            var journal = try self.read()
            let current = try self.entry(receipt.journalID)
            guard receipt.completed, self.summary(current) == receipt else {
                throw GatewayDeletionFailure.receiptChanged
            }
            try self.check(operation)
            journal.requests.removeAll { $0.journalID == receipt.journalID }
            // Synchronous read/check/write: no suspension can overwrite a concurrent checkpoint.
            try self.write(journal)
            self.phase = .ready
        }
    }

    private func work<T>(_ body: (Operation) async throws -> T) async throws -> T {
        guard foreground, isEnabled() else { throw GatewayFailure.configuration }
        guard busy == nil else { throw GatewayFailure.operationInProgress }
        let id = UUID()
        let original = generation
        busy = id
        progress = nil
        phase = .working
        errorMessage = nil
        defer {
            if busy == id {
                busy = nil
                if phase == .working { phase = .idle }
            }
        }
        do {
            await account.refresh()
            let operation = Operation(id: id, generation: original, cloudRevision: account.identityRevision)
            try check(operation)
            let result = try await body(operation)
            try check(operation)
            return result
        } catch {
            if generation == original, busy == id {
                progress = nil
                phase = (error as? GatewayFailure == .storageUnavailable) ? .storageBlocked : .failed
                if let safe = error as? GatewayFailure {
                    errorMessage = safe.errorDescription
                } else if let safe = error as? GatewayDeletionFailure {
                    errorMessage = safe.errorDescription
                } else if let safe = error as? PrivateDataFailure {
                    errorMessage = safe.errorDescription
                } else {
                    errorMessage =
                        "Nie udało się potwierdzić etapu usuwania. Spróbuj ponownie po sprawdzeniu konta."
                }
            }
            throw error
        }
    }
    private func check(_ operation: Operation) throws {
        guard foreground, busy == operation.id, generation == operation.generation, !Task.isCancelled else {
            throw GatewayFailure.superseded
        }
        guard isEnabled() else { throw GatewayFailure.configuration }
        guard account.state == .ready, account.identityRevision == operation.cloudRevision,
            let name = account.userRecordName,
            try GatewayIdentityBinding(appleUserID: binding.appleUserID, cloudKitRecordName: name) == binding
        else { throw GatewayFailure.accountMismatch }
    }
    private func verifiedProof(
        _ challenge: GatewayChallenge, _ proof: AppleGatewayProof, expectedAccountID: String?
    ) throws -> GatewayDeletionProof {
        try challenge.validate(now: now())
        guard proof.appleUserID == binding.appleUserID else { throw GatewayFailure.accountMismatch }
        return try .init(
            challengeID: challenge.challengeID, identityToken: proof.identityToken,
            expectedAccountID: expectedAccountID)
    }
    private func fence(_ operation: Operation, accountID: String?) async throws {
        try check(operation)
        try await fenceLocalAccess(binding, accountID)
        try check(operation)
    }
    private func authorize(_ entry: StoredGatewayDeletion, operation: Operation) async throws
        -> GatewayDeletionStatus
    {
        try check(operation)
        let current = try self.entry(entry.journalID)
        try requireSameCheckpoint(current, entry)
        guard entry.phase == .accepted else { throw GatewayDeletionFailure.freshProofRequired }
        let ticket = try ticket(entry)
        let result = try await api.deletionStatus(ticket: ticket)
        try check(operation)
        try requireSameCheckpoint(self.entry(entry.journalID), entry)
        try result.validate(deletionID: ticket.deletionID, accountID: entry.accountID)
        return result
    }
    private func scope(_ entry: StoredGatewayDeletion) throws -> PrivateAccountScope {
        guard let accountID = entry.accountID, let name = account.userRecordName else {
            throw GatewayFailure.accountMismatch
        }
        let scope = try PrivateAccountScope(
            configuration: configuration, accountID: accountID, cloudKitRecordName: name)
        guard scope.cloudKitAccountHash == binding.cloudKitAccountHash else {
            throw GatewayFailure.accountMismatch
        }
        return scope
    }
    private func ticket(_ entry: StoredGatewayDeletion) throws -> GatewayDeletionTicket {
        guard let ticket = entry.ticket else { throw GatewayDeletionFailure.freshProofRequired }
        return ticket
    }
    private func validate(
        _ cursor: PrivateCleanupCursor, scope: PrivateAccountScope, ticket: GatewayDeletionTicket
    ) throws {
        guard cursor.scopeDigest == scope.digest, cursor.deletionID == ticket.deletionID,
            !cursor.token.isEmpty, cursor.token.count <= 16_384
        else { throw PrivateDataFailure.invalidCursor }
    }
    private func requireSameCheckpoint(_ current: StoredGatewayDeletion, _ old: StoredGatewayDeletion) throws
    {
        guard current.binding == old.binding, current.attemptID == old.attemptID,
            current.phase == old.phase, current.ticket == old.ticket,
            current.accountID == old.accountID, current.cursor == old.cursor,
            current.contentDeleted == old.contentDeleted,
            current.localDataDeleted == old.localDataDeleted,
            current.ownAcknowledgement == old.ownAcknowledgement
        else { throw GatewayFailure.superseded }
    }
    private func summary(_ entry: StoredGatewayDeletion) -> GatewayDeletionProgress {
        .init(
            attemptID: entry.attemptID, journalID: entry.journalID, accountID: entry.accountID,
            status: entry.status,
            needsFreshProof: entry.phase == .recoveryPending,
            canRetryInitialRequest: entry.ticket != nil && entry.status == nil,
            privateContentDeleted: entry.contentDeleted, localDataDeleted: entry.localDataDeleted,
            ownAcknowledgement: entry.ownAcknowledgement)
    }
    private func publish(_ id: String) throws -> GatewayDeletionProgress {
        let result = summary(try entry(id))
        progress = result
        phase = result.completed ? .completed : result.ownAcknowledgement ? .awaitingServer : .ready
        return result
    }
    private func entry(_ id: String) throws -> StoredGatewayDeletion {
        let journal = try read()
        guard gatewayUUID(id), let entry = journal.requests.first(where: { $0.journalID == id }) else {
            throw GatewayDeletionFailure.missingRequest
        }
        guard entry.binding == binding else { throw GatewayFailure.accountMismatch }
        try requireNoOtherRecovery(journal, id: id)
        return entry
    }
    private func update(_ id: String, _ transform: (inout StoredGatewayDeletion) throws -> Void) throws {
        var journal = try read()
        guard let index = journal.requests.firstIndex(where: { $0.journalID == id }),
            journal.requests[index].binding == binding
        else { throw GatewayFailure.accountMismatch }
        try requireNoOtherRecovery(journal, id: id)
        try transform(&journal.requests[index])
        try write(journal)
    }
    private func accept(
        _ status: GatewayDeletionStatus, ticket: GatewayDeletionTicket, id: String,
        requiredPhase: StoredGatewayDeletion.Phase, attemptID: String
    ) throws {
        try update(id) { entry in
            guard entry.phase == requiredPhase, entry.ticket == ticket, entry.attemptID == attemptID else {
                throw GatewayFailure.superseded
            }
            try status.validate(deletionID: ticket.deletionID, accountID: entry.accountID)
            entry.phase = .accepted
            entry.accountID = status.accountID
            entry.status = status
        }
    }
    private func requireNoOtherRecovery(_ journal: StoredGatewayDeletionJournal, id: String) throws {
        guard
            !journal.requests.contains(where: {
                $0.journalID != id && $0.binding == binding && $0.phase == .recoveryPending
            })
        else {
            throw GatewayDeletionFailure.freshProofRequired
        }
    }
    private var journalCodec: GatewayDeletionJournalCodec {
        .init(origin: api.origin, configuration: configuration, storage: storage)
    }
    private func read() throws -> StoredGatewayDeletionJournal { try journalCodec.read() }
    private func write(_ value: StoredGatewayDeletionJournal) throws { try journalCodec.write(value) }

}
