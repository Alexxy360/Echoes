import Foundation
import Observation

public protocol GatewayAvatarUploadJournaling: Sendable {
    func open(scope: GatewayAvatarUploadScope) async throws -> GatewayAvatarUploadJournalLease
    func fence(_ lease: GatewayAvatarUploadJournalLease) async
    func pending(lease: GatewayAvatarUploadJournalLease) async throws -> GatewayAvatarUploadJournalEntry?
    func prepareUpload(
        intent: GatewayAvatarUploadIntent, avatar: PreparedAvatar, lease: GatewayAvatarUploadJournalLease
    ) async throws -> GatewayAvatarUploadJournalEntry
    func prepareClear(
        requestID: String, expectedGeneration: Int, replacing: GatewayAvatarUploadJournalEntry?,
        lease: GatewayAvatarUploadJournalLease
    ) async throws -> GatewayAvatarUploadJournalEntry
    func source(for entry: GatewayAvatarUploadJournalEntry, lease: GatewayAvatarUploadJournalLease)
        async throws -> Data
    func transition(
        _ entry: GatewayAvatarUploadJournalEntry, to phase: GatewayAvatarJournalPhase,
        lease: GatewayAvatarUploadJournalLease
    ) async throws -> GatewayAvatarUploadJournalEntry
    func remove(_ entry: GatewayAvatarUploadJournalEntry, lease: GatewayAvatarUploadJournalLease) async throws
}
extension GatewayAvatarUploadJournal: GatewayAvatarUploadJournaling {}

public enum GatewayAvatarOwnerFailure: Error, Equatable, Sendable, LocalizedError {
    case superseded
    public var errorDescription: String? { "Konto lub ekran zdjęcia zmieniły się. Otwórz go ponownie." }
}

/// One foreground owner controller per Runtime. No automatic poll, retransmission or publication.
/// UI must invalidate synchronously on background/native/domain changes and never retain snapshots.
@MainActor @Observable public final class GatewayAvatarOwnerController {
    private struct Context {
        let id: UUID
        let epoch: UUID
        let authorization: GatewayCommunityAuthorization
        let scope: GatewayAvatarUploadScope
        let lease: GatewayAvatarUploadJournalLease
    }
    private let api: any GatewayAvatarMutationAPI
    private let configuration: GatewayConfiguration
    private let cloudKit: CloudKitConfiguration
    private let authorization: any GatewayAvatarAuthorizationSource
    private let journal: any GatewayAvatarUploadJournaling
    private let isEnabled: @MainActor () -> Bool
    private let presentationChanged: @MainActor (String, GatewayAvatarOwnerSnapshot?) -> Void
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var slot: UUID?
    @ObservationIgnored private var operation: Task<Void, any Error>?
    @ObservationIgnored private var storedSnapshot: GatewayAvatarOwnerSnapshot?
    @ObservationIgnored private var storedPending: GatewayAvatarUploadJournalEntry?
    @ObservationIgnored private var refreshRequired = true
    public private(set) var presentationRevision = UUID()
    public var isBusy: Bool {
        _ = presentationRevision
        return slot != nil
    }
    public var isConnected: Bool {
        _ = presentationRevision
        return context.map(current) == true
    }
    /// Last observed owner state only. Every mutation fetches/validates fresh server state itself.
    public var snapshot: GatewayAvatarOwnerSnapshot? {
        _ = presentationRevision
        return isConnected ? storedSnapshot : nil
    }
    public var pendingOperation: GatewayAvatarUploadJournalEntry? {
        _ = presentationRevision
        return isConnected ? storedPending : nil
    }
    public var needsRefresh: Bool {
        _ = presentationRevision
        return !isConnected || refreshRequired
    }
    public init(
        api: any GatewayAvatarMutationAPI, configuration: GatewayConfiguration,
        cloudKit: CloudKitConfiguration,
        authorization: any GatewayAvatarAuthorizationSource, journal: any GatewayAvatarUploadJournaling,
        isEnabled: @escaping @MainActor () -> Bool = { false },
        presentationChanged: @escaping @MainActor (String, GatewayAvatarOwnerSnapshot?) -> Void = { _, _ in }
    ) throws {
        guard api.origin == configuration.origin.absoluteString,
            cloudKit.containerIdentifier == "iCloud.mpvEcho.Echo", cloudKit.environment == .development
        else { throw GatewayFailure.configuration }
        self.api = api
        self.configuration = configuration
        self.cloudKit = cloudKit
        self.authorization = authorization
        self.journal = journal
        self.isEnabled = isEnabled
        self.presentationChanged = presentationChanged
    }
    private func reset() {
        let lease = context?.lease
        context = nil
        storedSnapshot = nil
        storedPending = nil
        epoch = UUID()
        refreshRequired = true
        presentationRevision = UUID()
        if let lease { Task { [journal] in await journal.fence(lease) } }
    }
    /// The single slot stays occupied until the actual dependency returns, even after invalidation.
    public func invalidate() {
        reset()
        operation?.cancel()
    }
    private func current(_ expected: Context) -> Bool {
        context?.id == expected.id && epoch == expected.epoch && isEnabled()
            && authorization.communityAuthorization == expected.authorization
            && authorization.privateDataScope(configuration: cloudKit) == expected.scope.privateScope
    }
    private func check(_ expected: Context) throws {
        guard current(expected) else { throw GatewayAvatarOwnerFailure.superseded }
        if Task.isCancelled { throw GatewayFailure.cancelled }
    }
    private func bound() throws -> Context {
        guard let context else { throw GatewayFailure.signInRequired }
        try check(context)
        return context
    }
    private func safe(_ error: any Error) -> any Error {
        if error is CancellationError { return GatewayFailure.cancelled }
        if let value = error as? GatewayAvatarOwnerFailure { return value }
        if let value = error as? GatewayAvatarMutationFailure { return value }
        if let value = error as? GatewayAvatarUploadJournalFailure { return value }
        if let value = error as? GatewayFailure { return value }
        return GatewayAvatarMutationFailure.unavailable
    }
    private func exclusive(_ body: @escaping @MainActor () async throws -> Void) async throws {
        guard slot == nil else { throw GatewayAvatarMutationFailure.busy }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        let id = UUID()
        let start = epoch
        slot = id
        if let context, current(context) {
            presentationChanged(context.scope.privateScope.accountID, nil)
        }
        storedSnapshot = nil
        refreshRequired = true
        presentationRevision = UUID()
        let task = Task { try await body() }
        operation = task
        defer {
            if slot == id {
                slot = nil
                operation = nil
                presentationRevision = UUID()
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard epoch == start, let context, current(context) else {
                throw GatewayAvatarOwnerFailure.superseded
            }
            if Task.isCancelled { throw GatewayFailure.cancelled }
        } catch {
            if epoch == start, error as? GatewayAvatarUploadJournalFailure == .inactive { reset() }
            if epoch == start {
                refreshRequired = true
                storedSnapshot = nil
            }
            throw safe(error)
        }
    }
    public func connect() async throws {
        guard slot == nil else { throw GatewayAvatarMutationFailure.busy }
        reset()
        try await exclusive {
            guard self.isEnabled() else { throw GatewayAvatarMutationFailure.unavailable }
            guard let native = self.authorization.communityAuthorization,
                let owner = self.authorization.privateDataScope(configuration: self.cloudKit),
                owner.accountID == native.identity.accountID
            else { throw GatewayFailure.signInRequired }
            let start = self.epoch
            let scope = try GatewayAvatarUploadScope(
                configuration: self.configuration, privateScope: owner, binding: native.identity.binding)
            @MainActor func checkOpening() throws {
                guard self.epoch == start, self.isEnabled(),
                    self.authorization.communityAuthorization == native,
                    self.authorization.privateDataScope(configuration: self.cloudKit) == owner
                else { throw GatewayAvatarOwnerFailure.superseded }
                if Task.isCancelled { throw GatewayFailure.cancelled }
            }
            _ = try await self.authorization.communityAccessToken(for: native)
            try checkOpening()
            let lease = try await self.journal.open(scope: scope)
            do {
                try checkOpening()
                let pending = try await self.journal.pending(lease: lease)
                try checkOpening()
                self.context = .init(
                    id: UUID(), epoch: start, authorization: native, scope: scope, lease: lease)
                self.storedPending = pending
                self.presentationRevision = UUID()
            } catch {
                await self.journal.fence(lease)
                throw error
            }
        }
    }
    private func pending(_ context: Context) async throws -> GatewayAvatarUploadJournalEntry? {
        try check(context)
        let value = try await journal.pending(lease: context.lease)
        try check(context)
        storedPending = value
        presentationRevision = UUID()
        return value
    }
    private func match(_ expected: GatewayAvatarUploadJournalEntry?, _ context: Context) async throws {
        guard try await pending(context) == expected else {
            throw GatewayAvatarUploadJournalFailure.superseded
        }
    }
    private func dispatch(
        _ action: GatewayAvatarMutation, context: Context, expected: GatewayAvatarUploadJournalEntry?
    ) async throws -> GatewayAvatarOwnerSnapshot {
        try check(context)
        do {
            let token = try await authorization.communityAccessToken(for: context.authorization)
            try check(context)
            try await match(expected, context)
            let value = try await api.perform(action, token: token)
            try check(context)
            try value.validate(for: action)
            try await match(expected, context)
            return value
        } catch {
            try check(context)
            if error as? GatewayFailure == .signInRequired {
                await authorization.rejectCommunityAccess(for: context.authorization)
                guard self.context?.id == context.id, epoch == context.epoch,
                    authorization.communityAuthorization == nil
                        || authorization.communityAuthorization == context.authorization
                else { throw GatewayAvatarOwnerFailure.superseded }
                reset()
                throw GatewayFailure.signInRequired
            }
            throw safe(error)
        }
    }
    private func transition(
        _ entry: GatewayAvatarUploadJournalEntry, to phase: GatewayAvatarJournalPhase, context: Context
    ) async throws -> GatewayAvatarUploadJournalEntry {
        try check(context)
        let next = try await journal.transition(entry, to: phase, lease: context.lease)
        try check(context)
        storedPending = next
        presentationRevision = UUID()
        return next
    }
    private func complete(_ entry: GatewayAvatarUploadJournalEntry, context: Context) async throws {
        try check(context)
        try await journal.remove(entry, lease: context.lease)
        try check(context)
        storedPending = nil
        presentationRevision = UUID()
    }
    private func observe(_ value: GatewayAvatarOwnerSnapshot, context: Context) throws {
        try check(context)
        storedSnapshot = value
        refreshRequired = false
        presentationChanged(context.scope.privateScope.accountID, value)
        presentationRevision = UUID()
    }
    /// A snapshot may complete/stage an exact operation; it never authorizes a new upload or publish.
    @discardableResult private func reconcile(
        _ value: GatewayAvatarOwnerSnapshot, entry: GatewayAvatarUploadJournalEntry?, context: Context
    ) async throws -> Bool {
        guard let entry else {
            try observe(value, context: context)
            return false
        }
        let id: String
        let generation: Int
        switch entry.intent {
        case .upload(let intent): (id, generation) = (intent.requestID, intent.expectedGeneration)
        case .clear(let requestID, let expected): (id, generation) = (requestID, expected)
        }
        guard value.generation >= generation else { throw GatewayAvatarMutationFailure.invalidResponse }
        if value.requestID != id {
            try observe(value, context: context)
            return false  // Explicit discard or clear is required; never forget uncertain IDs automatically.
        }
        guard value.generation == generation + 1, entry.phase != .prepared else {
            throw GatewayAvatarMutationFailure.invalidResponse
        }
        switch entry.intent {
        case .clear:
            guard value.versionID == nil, value.status == .none || value.status == .clearing else {
                throw GatewayAvatarMutationFailure.invalidResponse
            }
            if value.status == .none { try await complete(entry, context: context) }
        case .upload(let intent):
            guard value.versionID == intent.versionID else {
                throw GatewayAvatarMutationFailure.invalidResponse
            }
            switch value.status {
            case .published: try await complete(entry, context: context)
            case .pendingReview, .approved, .rejected:
                if entry.phase != .staged { _ = try await transition(entry, to: .staged, context: context) }
            case .uploading:
                guard entry.phase == .dispatched else { throw GatewayAvatarMutationFailure.invalidResponse }
            default: throw GatewayAvatarMutationFailure.invalidResponse
            }
        }
        try observe(value, context: context)
        return true
    }

    public func refresh() async throws {
        try await exclusive {
            let context = try self.bound()
            let entry = try await self.pending(context)
            let value = try await self.dispatch(.status, context: context, expected: entry)
            try await self.reconcile(value, entry: entry, context: context)
        }
    }
    public func submit(_ avatar: PreparedAvatar, consentVersion: Int) async throws {
        guard consentVersion == 1 else { throw GatewayAvatarMutationFailure.invalidInput }
        try await exclusive {
            let context = try self.bound()
            guard try await self.pending(context) == nil else {
                throw GatewayAvatarUploadJournalFailure.pendingExists
            }
            let status = try await self.dispatch(.status, context: context, expected: nil)
            let intent = try GatewayAvatarUploadIntent(
                requestID: UUID().uuidString.lowercased(), versionID: UUID().uuidString.lowercased(),
                expectedGeneration: status.generation, consentVersion: consentVersion)
            let entry = try await self.journal.prepareUpload(
                intent: intent, avatar: avatar, lease: context.lease)
            try self.check(context)
            self.storedPending = entry
            try await self.sendUpload(entry, context: context)
        }
    }
    private func sendUpload(_ entry: GatewayAvatarUploadJournalEntry, context: Context) async throws {
        guard case .upload(let intent) = entry.intent, entry.phase == .prepared || entry.phase == .dispatched
        else { throw GatewayAvatarUploadJournalFailure.invalidTransition }
        let source = try await journal.source(for: entry, lease: context.lease)
        try check(context)
        let dispatched = try await transition(entry, to: .dispatched, context: context)
        let value = try await dispatch(
            .upload(intent: intent, image: source), context: context, expected: dispatched)
        try await reconcile(value, entry: dispatched, context: context)
    }
    /// Explicit retransmission of the SAME prepared bytes/IDs only, after fresh status.
    /// Already staged/published work is reconciled without retransmission.
    public func retryUpload() async throws {
        try await exclusive {
            let context = try self.bound()
            guard let entry = try await self.pending(context), case .upload(let intent) = entry.intent else {
                throw GatewayAvatarUploadJournalFailure.invalidTransition
            }
            let status = try await self.dispatch(.status, context: context, expected: entry)
            let same = try await self.reconcile(status, entry: entry, context: context)
            if same && status.status != .uploading { return }
            guard same || status.generation == intent.expectedGeneration else {
                throw GatewayAvatarMutationFailure.stale
            }
            try await self.sendUpload(entry, context: context)
        }
    }
    public func recover() async throws {
        try await exclusive {
            let context = try self.bound()
            guard let entry = try await self.pending(context) else {
                throw GatewayAvatarUploadJournalFailure.invalidTransition
            }
            if case .clear = entry.intent {
                try await self.sendClear(entry, context: context)
                return
            }
            guard case .upload(let intent) = entry.intent, entry.phase != .prepared else {
                throw GatewayAvatarUploadJournalFailure.invalidTransition
            }
            let value = try await self.dispatch(
                .recover(requestID: intent.requestID), context: context, expected: entry)
            try await self.reconcile(value, entry: entry, context: context)
        }
    }
    public func publish() async throws {
        try await exclusive {
            let context = try self.bound()
            guard let entry = try await self.pending(context), case .upload(let intent) = entry.intent else {
                throw GatewayAvatarUploadJournalFailure.invalidTransition
            }
            let status = try await self.dispatch(.status, context: context, expected: entry)
            guard try await self.reconcile(status, entry: entry, context: context) else {
                throw GatewayAvatarMutationFailure.stale
            }
            if status.status == .published { return }
            guard status.status == .approved else {
                throw status.status == .rejected
                    ? GatewayAvatarMutationFailure.rejected : GatewayAvatarMutationFailure.pending
            }
            guard let staged = try await self.pending(context) else {
                throw GatewayAvatarUploadJournalFailure.superseded
            }
            let publishing = try await self.transition(staged, to: .publishing, context: context)
            let value = try await self.dispatch(
                .publish(requestID: intent.requestID), context: context, expected: publishing)
            try await self.reconcile(value, entry: publishing, context: context)
        }
    }
    public func clear() async throws {
        try await exclusive {
            let context = try self.bound()
            let entry = try await self.pending(context)
            if let entry, case .clear = entry.intent {
                try await self.sendClear(entry, context: context)
                return
            }
            let status = try await self.dispatch(.status, context: context, expected: entry)
            if let entry {
                let previous: Int
                switch entry.intent {
                case .upload(let intent): previous = intent.expectedGeneration
                case .clear(_, let generation): previous = generation
                }
                guard status.generation >= previous else {
                    throw GatewayAvatarMutationFailure.invalidResponse
                }
            }
            let clear = try await self.journal.prepareClear(
                requestID: UUID().uuidString.lowercased(), expectedGeneration: status.generation,
                replacing: entry, lease: context.lease)
            try self.check(context)
            self.storedPending = clear
            try await self.sendClear(clear, context: context)
        }
    }
    private func sendClear(_ entry: GatewayAvatarUploadJournalEntry, context: Context) async throws {
        guard case .clear(let id, let generation) = entry.intent else {
            throw GatewayAvatarUploadJournalFailure.invalidTransition
        }
        let dispatched = try await transition(entry, to: .dispatched, context: context)
        let value = try await dispatch(
            .clear(requestID: id, expectedGeneration: generation), context: context, expected: dispatched)
        try await reconcile(value, entry: dispatched, context: context)
    }
    /// Explicit local discard only when fresh status proves no dispatch or supersession.
    /// A current uncertain/staged/rejected selection must be withdrawn through clear instead.
    public func discardUnsentOrSuperseded() async throws {
        try await exclusive {
            let context = try self.bound()
            guard let entry = try await self.pending(context) else { return }
            let status = try await self.dispatch(.status, context: context, expected: entry)
            let id: String
            let generation: Int
            switch entry.intent {
            case .upload(let intent): (id, generation) = (intent.requestID, intent.expectedGeneration)
            case .clear(let requestID, let expected): (id, generation) = (requestID, expected)
            }
            guard status.requestID != id,
                status.generation > generation || entry.phase == .prepared && status.generation == generation
            else { throw GatewayAvatarMutationFailure.pending }
            try await self.complete(entry, context: context)
            try self.observe(status, context: context)
        }
    }
}
