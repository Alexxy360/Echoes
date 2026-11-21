import CoreGraphics
import Foundation
import Observation

public enum GatewayAvatarReviewHostFailure: Error, Equatable, Sendable, LocalizedError {
    case superseded, displayRequired
    public var errorDescription: String? {
        switch self {
        case .superseded: "Konto lub ekran moderacji zmieniły się. Otwórz panel ponownie."
        case .displayRequired: "Najpierw wyświetl aktualny podgląd zdjęcia."
        }
    }
}
public struct GatewayAvatarReviewPresentation: Equatable, Sendable, CustomStringConvertible, CustomReflectable
{
    fileprivate let id: UUID
    public var description: String { "GatewayAvatarReviewPresentation(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReviewResolution: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    fileprivate let id: UUID
    public var description: String { "GatewayAvatarReviewResolution(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// One foreground operator host. UI resolves opaque handles on each render and acknowledges
/// actual current display. Persisted metadata never restores pixels or a permission to decide.
@MainActor @Observable public final class GatewayAvatarReviewHost {
    private struct Context {
        let id: UUID, epoch: UUID
        let authorization: GatewayCommunityAuthorization
        let scope: GatewayAvatarReviewScope
        let lease: GatewayAvatarReviewJournalLease
        let isCurrent: @MainActor () -> Bool
    }
    private struct Inspection {
        let id: UUID
        let value: GatewayAvatarReviewInspection
    }
    private struct Resolution {
        let id: UUID
        let result: GatewayAvatarReviewRecoveryResult
    }
    private let api: any GatewayAvatarReviewAPI
    private let configuration: GatewayConfiguration
    private let cloudKit: CloudKitConfiguration
    private let authorization: any GatewayAvatarAuthorizationSource
    private let journal: GatewayAvatarReviewJournal
    private let isEnabled: @MainActor () -> Bool
    private let date: @MainActor () -> Date
    private let uptime: @MainActor () -> TimeInterval
    private let publicationChanged: @MainActor (GatewayAvatarReviewPublicationEvent) -> Void
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var slot: UUID?
    @ObservationIgnored private var operation: Task<Void, any Error>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var storedQueue: [GatewayAvatarReviewItem] = []
    @ObservationIgnored private var storedInspection: Inspection?
    @ObservationIgnored private var displayID: UUID?
    @ObservationIgnored private var storedPending: GatewayAvatarReviewJournalEntry?
    @ObservationIgnored private var storedResolution: Resolution?
    @ObservationIgnored private var denied = false
    private var foreground = false
    public private(set) var presentationRevision = UUID()
    public var isBusy: Bool {
        _ = presentationRevision
        return slot != nil
    }
    public var isConnected: Bool {
        _ = presentationRevision
        return context.map(current) == true
    }
    public var isRoleDenied: Bool {
        _ = presentationRevision
        return isConnected && denied
    }
    public var queue: [GatewayAvatarReviewItem] {
        _ = presentationRevision
        return isConnected && !isBusy ? storedQueue : []
    }
    public var pendingOperation: GatewayAvatarReviewJournalEntry? {
        _ = presentationRevision
        return isConnected ? storedPending : nil
    }
    public var outcome: GatewayAvatarReviewOutcome? {
        _ = presentationRevision
        guard isConnected && !isBusy else { return nil }
        return storedResolution?.result.outcome ?? (storedPending?.outcome == .notApplied ? .notApplied : nil)
    }
    public var resolution: GatewayAvatarReviewResolution? {
        _ = presentationRevision
        guard isConnected, !isBusy, storedPending?.phase == .resolved, let value = storedResolution,
            value.result.outcome.isTerminal
        else { return nil }
        return .init(id: value.id)
    }
    public var presentation: GatewayAvatarReviewPresentation? {
        _ = presentationRevision
        guard let value = liveInspection() else { return nil }
        return .init(id: value.id)
    }
    public var canDecide: Bool {
        _ = presentationRevision
        guard let value = liveInspection() else { return false }
        return displayID == value.id && storedPending == nil && !denied
    }
    public var canRetirePending: Bool {
        _ = presentationRevision
        return isConnected && !isBusy && !denied && storedPending.map { $0.phase != .resolved } == true
    }
    public init(
        api: any GatewayAvatarReviewAPI, configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration,
        authorization: any GatewayAvatarAuthorizationSource, journal: GatewayAvatarReviewJournal,
        isEnabled: @escaping @MainActor () -> Bool = { false },
        date: @escaping @MainActor () -> Date = { Date() },
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        publicationChanged: @escaping @MainActor (GatewayAvatarReviewPublicationEvent) -> Void = { _ in }
    ) throws {
        guard api.origin == configuration.origin.absoluteString,
            cloudKit.containerIdentifier == "iCloud.mpvEcho.Echo",
            cloudKit.environment == .development
        else { throw GatewayFailure.configuration }
        self.api = api
        self.configuration = configuration
        self.cloudKit = cloudKit
        self.authorization = authorization
        self.journal = journal
        self.isEnabled = isEnabled
        self.date = date
        self.uptime = uptime
        self.publicationChanged = publicationChanged
    }
    private func stamp() throws -> AvatarReviewStamp { try .init(date: date(), uptime: uptime()) }
    private func current(_ value: Context) -> Bool {
        foreground && isEnabled() && context?.id == value.id && epoch == value.epoch && value.isCurrent()
            && journal.isActive(value.lease)
            && authorization.communityAuthorization == value.authorization
            && authorization.privateDataScope(configuration: cloudKit) == value.scope.owner
    }
    private func check(_ value: Context) throws {
        guard current(value) else { throw GatewayAvatarReviewHostFailure.superseded }
        if Task.isCancelled { throw GatewayFailure.cancelled }
    }
    private func bound() throws -> Context {
        guard let context else { throw GatewayFailure.signInRequired }
        try check(context)
        return context
    }
    private func dropPresentation() {
        storedInspection = nil
        displayID = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        presentationRevision = UUID()
    }
    private func reset() {
        if let context { journal.fence(context.lease) }
        context = nil
        epoch = UUID()
        storedQueue = []
        storedPending = nil
        storedResolution = nil
        denied = false
        dropPresentation()
    }
    public func invalidate() {
        reset()
        operation?.cancel()
    }
    public func setForeground(_ value: Bool) {
        foreground = value
        if !value { invalidate() }
    }
    private func liveInspection() -> Inspection? {
        guard isConnected, !isBusy, storedPending == nil, let value = storedInspection,
            (try? value.value.receipt.validateTime(stamp())) != nil
        else { return nil }
        return value
    }
    public func image(for handle: GatewayAvatarReviewPresentation) -> CGImage? {
        guard let value = liveInspection(), value.id == handle.id else { return nil }
        return value.value.avatar.image
    }
    public func acknowledgeDisplay(_ handle: GatewayAvatarReviewPresentation) throws {
        guard let value = liveInspection(), value.id == handle.id else {
            throw GatewayAvatarReviewHostFailure.displayRequired
        }
        displayID = value.id
        presentationRevision = UUID()
    }
    /// A local expiry notification, never a network poll. Getters independently check time.
    public func expirePresentation() {
        guard let value = storedInspection else { return }
        if (try? value.value.receipt.validateTime(stamp())) == nil { dropPresentation() }
    }
    private func scheduleExpiry(_ value: Inspection) throws {
        let now = try stamp()
        let receipt = value.value.receipt
        try receipt.validateTime(now)
        let remaining = min(
            Double(receipt.expiresAtMilliseconds - now.milliseconds),
            Double(min(90_000, receipt.expiresAtMilliseconds - receipt.observedAtMilliseconds))
                - (now.uptime - receipt.observedUptime) * 1000)
        let milliseconds = Int(remaining.rounded(.up))
        let id = value.id
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
            guard self?.storedInspection?.id == id else { return }
            self?.expirePresentation()
        }
    }
    private func safe(_ error: any Error) -> any Error {
        if error is CancellationError { return GatewayFailure.cancelled }
        if let value = error as? GatewayAvatarReviewFailure { return value }
        if let value = error as? GatewayAvatarReviewHostFailure { return value }
        if let value = error as? GatewayAvatarReviewJournalFailure { return value }
        if let value = error as? GatewayFailure { return value }
        return GatewayAvatarReviewFailure.unavailable
    }
    private func exclusive(_ body: @escaping @MainActor () async throws -> Void) async throws {
        guard slot == nil else { throw GatewayAvatarReviewFailure.busy }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        let id = UUID()
        let start = epoch
        slot = id
        dropPresentation()
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
                throw GatewayAvatarReviewHostFailure.superseded
            }
            if Task.isCancelled { throw GatewayFailure.cancelled }
        } catch {
            if epoch == start {
                dropPresentation()
                if error is CancellationError || error as? GatewayFailure == .cancelled { reset() }
                if let failure = error as? GatewayAvatarReviewJournalFailure,
                    failure == .inactive || failure == .unavailable
                {
                    reset()
                }
                if error as? GatewayAvatarReviewFailure == .denied {
                    denied = true
                    storedQueue = []
                    storedResolution = nil
                }
                if error as? GatewayFailure == .signInRequired, let context, current(context) {
                    await authorization.rejectCommunityAccess(for: context.authorization)
                    if epoch == start, self.context?.id == context.id { reset() }
                }
            }
            throw safe(error)
        }
    }
    public func connect(isCurrent: @escaping @MainActor () -> Bool = { true }) async throws {
        guard slot == nil else { throw GatewayAvatarReviewFailure.busy }
        reset()
        try await exclusive {
            guard self.foreground, self.isEnabled(), isCurrent() else {
                throw GatewayAvatarReviewHostFailure.superseded
            }
            guard let native = self.authorization.communityAuthorization,
                let owner = self.authorization.privateDataScope(configuration: self.cloudKit),
                owner.accountID == native.identity.accountID
            else { throw GatewayFailure.signInRequired }
            let start = self.epoch
            _ = try await self.authorization.communityAccessToken(for: native)
            guard self.foreground, self.isEnabled(), isCurrent(), self.epoch == start,
                self.authorization.communityAuthorization == native,
                self.authorization.privateDataScope(configuration: self.cloudKit) == owner
            else { throw GatewayAvatarReviewHostFailure.superseded }
            try Task.checkCancellation()
            let scope = try GatewayAvatarReviewScope(
                configuration: self.configuration, owner: owner, binding: native.identity.binding)
            let lease = try await self.journal.open(scope: scope)
            do {
                @MainActor func checkOpening() throws {
                    guard self.foreground, self.isEnabled(), isCurrent(), self.epoch == start,
                        self.authorization.communityAuthorization == native,
                        self.authorization.privateDataScope(configuration: self.cloudKit) == owner
                    else { throw GatewayAvatarReviewHostFailure.superseded }
                    try Task.checkCancellation()
                }
                try checkOpening()
                let pending = try await self.journal.pending(lease: lease)
                try checkOpening()
                self.context = .init(
                    id: UUID(), epoch: start, authorization: native, scope: scope, lease: lease,
                    isCurrent: isCurrent)
                self.storedPending = pending
                if let pending { self.publicationChanged(.pending(pending.intent)) }
                if let pending, pending.phase == .resolved, let outcome = pending.outcome, outcome.isTerminal
                {
                    let result = GatewayAvatarReviewRecoveryResult(intent: pending.intent, outcome: outcome)
                    self.storedResolution = .init(id: UUID(), result: result)
                    self.publicationChanged(.resolved(result))
                } else {
                    self.storedResolution = nil
                }
                try self.check(self.bound())
            } catch {
                self.journal.fence(lease)
                throw error
            }
        }
    }
    private func match(_ expected: GatewayAvatarReviewJournalEntry?, _ context: Context) async throws {
        try check(context)
        let actual = try await journal.pending(lease: context.lease)
        try check(context)
        guard actual == expected else {
            throw GatewayAvatarReviewJournalFailure.inactive
        }
    }
    private func token(_ context: Context, expected: GatewayAvatarReviewJournalEntry?) async throws
        -> GatewaySecret
    {
        try await match(expected, context)
        let token = try await authorization.communityAccessToken(for: context.authorization)
        try await match(expected, context)
        return token
    }
    public func refreshQueue() async throws {
        try await exclusive {
            let context = try self.bound()
            guard self.storedPending == nil else { throw GatewayAvatarReviewJournalFailure.pendingExists }
            try await self.match(nil, context)
            self.storedQueue = []
            let token = try await self.token(context, expected: nil)
            let result = try await self.api.queue(token: token)
            try await self.match(nil, context)
            guard result.count <= 20, Set(result.map(\.accountID)).count == result.count else {
                throw GatewayAvatarReviewFailure.invalidResponse
            }
            self.storedQueue = result
            self.denied = false
        }
    }
    public func inspect(_ item: GatewayAvatarReviewItem) async throws {
        try await exclusive {
            let context = try self.bound()
            try await self.match(nil, context)
            guard self.storedQueue.contains(item) else { throw GatewayAvatarReviewFailure.stale }
            let token = try await self.token(context, expected: nil)
            let result = try await self.api.inspect(item, token: token)
            try await self.match(nil, context)
            try result.receipt.validate(origin: self.api.origin, token: token, stamp: self.stamp())
            guard result.receipt.item == item, result.avatar.manifest.reference.ownerID == item.accountID,
                result.avatar.manifest.reference.versionID == item.versionID,
                result.avatar.manifest.variant == .image,
                result.avatar.image.width == result.avatar.manifest.width,
                result.avatar.image.height == result.avatar.manifest.height
            else { throw GatewayAvatarReviewFailure.invalidResponse }
            let value = Inspection(id: UUID(), value: result)
            self.storedInspection = value
            self.displayID = nil
            self.denied = false
            try self.scheduleExpiry(value)
        }
    }
    public func decide(_ verdict: GatewayAvatarReviewVerdict, presentation: GatewayAvatarReviewPresentation)
        async throws
    {
        guard let shown = liveInspection(), shown.id == presentation.id, displayID == shown.id,
            storedPending == nil, !denied
        else { throw GatewayAvatarReviewHostFailure.displayRequired }
        try await exclusive {
            let context = try self.bound()
            let token = try await self.token(context, expected: nil)
            try shown.value.receipt.validate(origin: self.api.origin, token: token, stamp: self.stamp())
            let intent = try GatewayAvatarReviewDecisionIntent(
                receipt: shown.value.receipt,
                decisionID: UUID().uuidString.lowercased(), verdict: verdict)
            let prepared = try await self.journal.prepare(.init(decision: intent), lease: context.lease)
            try self.check(context)
            self.storedPending = prepared
            let dispatched = try await self.journal.dispatched(prepared, lease: context.lease)
            try self.check(context)
            self.storedPending = dispatched
            self.publicationChanged(.pending(dispatched.intent))
            try await self.match(dispatched, context)
            let result = try await self.api.decide(intent, token: token)
            try await self.match(dispatched, context)
            guard result.intent == intent else { throw GatewayAvatarReviewFailure.invalidResponse }
            let recovered = GatewayAvatarReviewRecoveryResult(
                intent: dispatched.intent, outcome: .confirmed(revision: result.revision))
            let resolved = try await self.journal.resolve(dispatched, result: recovered, lease: context.lease)
            try self.check(context)
            self.storedPending = resolved
            self.storedResolution = .init(id: UUID(), result: recovered)
            self.publicationChanged(.resolved(recovered))
            try self.check(context)
            self.storedQueue = []
        }
    }
    /// Exact persisted metadata only. No resubmission, fresh inspection, new ID or decision retry.
    public func recover() async throws {
        try await exclusive {
            let context = try self.bound()
            guard let entry = self.storedPending else {
                throw GatewayAvatarReviewJournalFailure.invalidTransition
            }
            self.storedResolution = nil
            let token = try await self.token(context, expected: entry)
            let result = try await self.api.recover(entry.intent, token: token)
            try await self.match(entry, context)
            guard result.intent == entry.intent else { throw GatewayAvatarReviewFailure.invalidResponse }
            let resolved = try await self.journal.resolve(entry, result: result, lease: context.lease)
            try self.check(context)
            self.storedPending = resolved
            self.storedResolution = result.outcome.isTerminal ? .init(id: UUID(), result: result) : nil
            if result.outcome.isTerminal {
                self.publicationChanged(.resolved(result))
            } else {
                self.publicationChanged(.pending(entry.intent))
            }
            try self.check(context)
            self.storedQueue = []
            self.denied = false
        }
    }
    /// Explicitly closes only the captured pending attempt; never re-sends or undoes a decision.
    public func retirePending(_ expected: GatewayAvatarReviewRecoveryIntent) async throws {
        guard canRetirePending, storedPending?.intent == expected else {
            throw GatewayAvatarReviewJournalFailure.invalidTransition
        }
        try await exclusive {
            let context = try self.bound()
            guard let entry = self.storedPending, entry.intent == expected else {
                throw GatewayAvatarReviewJournalFailure.invalidTransition
            }
            self.storedResolution = nil
            let retiring = try await self.journal.retiring(entry, lease: context.lease)
            try self.check(context)
            self.storedPending = retiring
            self.publicationChanged(.pending(retiring.intent))
            try await self.match(retiring, context)
            let token = try await self.token(context, expected: retiring)
            let result = try await self.api.retire(retiring.intent, token: token)
            try await self.match(retiring, context)
            guard result.intent == retiring.intent, result.outcome.isTerminal else {
                throw GatewayAvatarReviewFailure.invalidResponse
            }
            let resolved = try await self.journal.resolve(retiring, result: result, lease: context.lease)
            try self.check(context)
            self.storedPending = resolved
            self.storedResolution = .init(id: UUID(), result: result)
            self.publicationChanged(.resolved(result))
            self.storedQueue = []
            try self.check(context)
        }
    }
    public func acknowledgeResult(_ handle: GatewayAvatarReviewResolution) async throws {
        guard !isBusy else { throw GatewayAvatarReviewFailure.busy }
        let context = try bound()
        guard let resolution = storedResolution, resolution.id == handle.id, let entry = storedPending,
            entry.intent == resolution.result.intent, entry.phase == .resolved,
            resolution.result.outcome.isTerminal
        else { throw GatewayAvatarReviewJournalFailure.invalidTransition }
        try await exclusive {
            try await self.match(entry, context)
            try await self.journal.acknowledge(entry, lease: context.lease)
            try self.check(context)
            self.storedPending = nil
            self.storedResolution = nil
            self.storedQueue = []
        }
    }
}
