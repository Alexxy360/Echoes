import CoreGraphics
import Foundation
import Observation

public enum GatewayAvatarReportReviewHostFailure: Error, Equatable, Sendable, LocalizedError {
    case superseded, displayRequired
    public var errorDescription: String? {
        switch self {
        case .superseded: "Konto lub ekran moderacji zmieniły się. Otwórz panel ponownie."
        case .displayRequired: "Najpierw wyświetl aktualną treść zgłoszenia."
        }
    }
}
public struct GatewayAvatarReportReviewMaterial: Sendable, CustomStringConvertible, CustomReflectable {
    public let reason: String
    public let image: CGImage?
    public var description: String { "GatewayAvatarReportReviewMaterial(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReportReviewPageHandle: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    fileprivate let id: UUID
    public var description: String { "GatewayAvatarReportReviewPageHandle(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReportReviewPresentation: Hashable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    fileprivate let id: UUID
    public var description: String { "GatewayAvatarReportReviewPresentation(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReportReviewResolution: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    fileprivate let id: UUID
    public var description: String { "GatewayAvatarReportReviewResolution(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// One foreground operator host. UI resolves opaque handles on each render and acknowledges
/// actual current display. Persisted metadata never restores text or a permission to decide.
@MainActor @Observable public final class GatewayAvatarReportReviewHost {
    private struct Context {
        let id: UUID, epoch: UUID
        let authorization: GatewayCommunityAuthorization
        let scope: GatewayAvatarReportReviewScope
        let lease: GatewayAvatarReportReviewJournalLease
        let isCurrent: @MainActor () -> Bool
    }
    private struct Page {
        let id: UUID
        let value: GatewayAvatarReportReviewPage
        let observed: AvatarReportReviewStamp
    }
    private struct Inspection {
        let id: UUID
        let value: GatewayAvatarReportReviewInspection
    }
    private struct Resolution {
        let id: UUID
        let result: GatewayAvatarReportReviewRecoveryResult
    }
    private let api: any GatewayAvatarReportReviewAPI
    private let configuration: GatewayConfiguration
    private let cloudKit: CloudKitConfiguration
    private let authorization: any GatewayAvatarAuthorizationSource
    private let journal: GatewayAvatarReportReviewJournal
    private let isEnabled: @MainActor () -> Bool
    private let date: @MainActor () -> Date
    private let uptime: @MainActor () -> TimeInterval
    // Internal timer seam keeps deterministic expiry tests aligned with their controlled clock.
    // Production continues to wait the exact receipt-derived duration using Task.sleep.
    @ObservationIgnored var inspectionDeadlineWait: @Sendable (Int) async throws -> Void = { milliseconds in
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
    private let publicationChanged: @MainActor (GatewayAvatarReportReviewPublicationEvent) -> Void
    @ObservationIgnored private var materialReadID: UUID?
    @ObservationIgnored private var clockFloor: AvatarReportReviewStamp?
    @ObservationIgnored private var clockRejected = false
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var retiredContextID: UUID?
    @ObservationIgnored private var retiredInspectionID: UUID?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var slot: UUID?
    @ObservationIgnored private var operation: Task<Void, any Error>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var storedPage: Page?
    @ObservationIgnored private var storedInspection: Inspection?
    @ObservationIgnored private var displayID: UUID?
    @ObservationIgnored private var storedPending: GatewayAvatarReportReviewJournalEntry?
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
    public var queue: [GatewayAvatarReportReviewItem] {
        _ = presentationRevision
        guard let page = livePage(), let now = try? stamp() else { return [] }
        return page.value.items.filter {
            $0.createdAtMilliseconds <= now.milliseconds && $0.expiresAtMilliseconds > now.milliseconds
        }
    }
    public var pendingOperation: GatewayAvatarReportReviewJournalEntry? {
        _ = presentationRevision
        return isConnected ? storedPending : nil
    }
    public var outcome: GatewayAvatarReportReviewOutcome? {
        _ = presentationRevision
        guard isConnected && !isBusy else { return nil }
        return storedResolution?.result.outcome ?? (storedPending?.outcome == .notApplied ? .notApplied : nil)
    }
    public var resolution: GatewayAvatarReportReviewResolution? {
        _ = presentationRevision
        guard isConnected, !isBusy, storedPending?.phase == .resolved, let value = storedResolution,
            value.result.outcome.isTerminal
        else { return nil }
        return .init(id: value.id)
    }
    public var presentation: GatewayAvatarReportReviewPresentation? {
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
        api: any GatewayAvatarReportReviewAPI, configuration: GatewayConfiguration,
        cloudKit: CloudKitConfiguration,
        authorization: any GatewayAvatarAuthorizationSource, journal: GatewayAvatarReportReviewJournal,
        isEnabled: @escaping @MainActor () -> Bool = { false },
        date: @escaping @MainActor () -> Date = { Date() },
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        publicationChanged: @escaping @MainActor (GatewayAvatarReportReviewPublicationEvent) -> Void = { _ in
        }
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
    private func stamp() throws -> AvatarReportReviewStamp {
        guard !clockRejected else { throw GatewayAvatarReportReviewFailure.stale }
        do {
            let now = try AvatarReportReviewStamp(date: date(), uptime: uptime())
            if let floor = clockFloor {
                guard now.milliseconds >= floor.milliseconds, now.uptime >= floor.uptime else {
                    throw GatewayAvatarReportReviewFailure.stale
                }
            }
            clockFloor = now
            return now
        } catch {
            clockRejected = true
            throw GatewayAvatarReportReviewFailure.stale
        }
    }
    private func current(_ value: Context) -> Bool {
        guard context?.id == value.id, retiredContextID != value.id else { return false }
        let valid =
            foreground && isEnabled() && epoch == value.epoch && value.isCurrent()
            && (try? stamp()) != nil
            && journal.isActive(value.lease)
            && authorization.communityAuthorization == value.authorization
            && authorization.privateDataScope(configuration: cloudKit) == value.scope.owner
        if !valid { retiredContextID = value.id }
        return valid
    }
    private func check(_ value: Context) throws {
        guard current(value) else { throw GatewayAvatarReportReviewHostFailure.superseded }
        if Task.isCancelled { throw GatewayFailure.cancelled }
    }
    private func bound() throws -> Context {
        guard let context else { throw GatewayFailure.signInRequired }
        try check(context)
        return context
    }
    private func dropPresentation() {
        storedInspection = nil
        materialReadID = nil
        retiredInspectionID = nil
        displayID = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        presentationRevision = UUID()
    }
    private func reset() {
        if let context { journal.fence(context.lease) }
        context = nil
        clockFloor = nil
        clockRejected = false
        retiredContextID = nil
        epoch = UUID()
        storedPage = nil
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
            retiredInspectionID != value.id
        else { return nil }
        guard (try? value.value.receipt.validateTime(stamp())) != nil else {
            retiredInspectionID = value.id
            return nil
        }
        return value
    }
    public func material(for handle: GatewayAvatarReportReviewPresentation)
        -> GatewayAvatarReportReviewMaterial?
    {
        guard let value = liveInspection(), value.id == handle.id else { return nil }
        materialReadID = value.id
        return .init(reason: value.value.reason, image: value.value.avatar?.image)
    }
    public var canHidePhoto: Bool {
        _ = presentationRevision
        return canDecide && liveInspection()?.value.avatar != nil
    }
    public func acknowledgeDisplay(_ handle: GatewayAvatarReportReviewPresentation) throws {
        guard let value = liveInspection(), value.id == handle.id, materialReadID == value.id else {
            throw GatewayAvatarReportReviewHostFailure.displayRequired
        }
        displayID = value.id
        presentationRevision = UUID()
    }
    /// A local expiry notification, never a network poll. Getters independently check time.
    public func expirePresentation() {
        guard let value = storedInspection else { return }
        if retiredInspectionID == value.id || (try? value.value.receipt.validateTime(stamp())) == nil {
            dropPresentation()
        }
    }
    private func scheduleExpiry(_ value: Inspection) throws {
        let now = try stamp()
        let receipt = value.value.receipt
        try receipt.validateTime(now)
        let remaining = min(
            Double(receipt.expiresAtMilliseconds - now.milliseconds),
            Double(min(90_000, receipt.expiresAtMilliseconds - receipt.observed.milliseconds))
                - (now.uptime - receipt.observed.uptime) * 1000)
        let milliseconds = Int(remaining.rounded(.up))
        let id = value.id
        deadlineTask?.cancel()
        let wait = inspectionDeadlineWait
        deadlineTask = Task { [weak self] in
            do { try await wait(milliseconds) } catch { return }
            guard self?.storedInspection?.id == id else { return }
            self?.expirePresentation()
        }
    }
    private func safe(_ error: any Error) -> any Error {
        if error is CancellationError { return GatewayFailure.cancelled }
        if let value = error as? GatewayAvatarReportReviewFailure { return value }
        if let value = error as? GatewayAvatarReportReviewHostFailure { return value }
        if let value = error as? GatewayAvatarReportReviewJournalFailure { return value }
        if let value = error as? GatewayFailure { return value }
        return GatewayAvatarReportReviewFailure.unavailable
    }
    private func exclusive(_ body: @escaping @MainActor () async throws -> Void) async throws {
        guard slot == nil else { throw GatewayAvatarReportReviewFailure.busy }
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
                throw GatewayAvatarReportReviewHostFailure.superseded
            }
            if Task.isCancelled { throw GatewayFailure.cancelled }
        } catch {
            if epoch == start {
                dropPresentation()
                if error is CancellationError || error as? GatewayFailure == .cancelled { reset() }
                if let failure = error as? GatewayAvatarReportReviewJournalFailure,
                    failure == .inactive || failure == .unavailable
                {
                    reset()
                }
                if error as? GatewayAvatarReportReviewFailure == .denied {
                    denied = true
                    storedPage = nil
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
        guard slot == nil else { throw GatewayAvatarReportReviewFailure.busy }
        reset()
        try await exclusive {
            guard self.foreground, self.isEnabled(), isCurrent() else {
                throw GatewayAvatarReportReviewHostFailure.superseded
            }
            guard let native = self.authorization.communityAuthorization,
                let owner = self.authorization.privateDataScope(configuration: self.cloudKit),
                owner.accountID == native.identity.accountID
            else { throw GatewayFailure.signInRequired }
            let start = self.epoch
            _ = try self.stamp()
            _ = try await self.authorization.communityAccessToken(for: native)
            guard self.foreground, self.isEnabled(), isCurrent(), self.epoch == start,
                self.authorization.communityAuthorization == native,
                self.authorization.privateDataScope(configuration: self.cloudKit) == owner
            else { throw GatewayAvatarReportReviewHostFailure.superseded }
            try Task.checkCancellation()
            let scope = try GatewayAvatarReportReviewScope(
                configuration: self.configuration, owner: owner, binding: native.identity.binding)
            let lease = try await self.journal.open(scope: scope)
            do {
                @MainActor func checkOpening() throws {
                    guard self.foreground, self.isEnabled(), isCurrent(), self.epoch == start,
                        self.authorization.communityAuthorization == native,
                        self.authorization.privateDataScope(configuration: self.cloudKit) == owner
                    else { throw GatewayAvatarReportReviewHostFailure.superseded }
                    _ = try self.stamp()
                    try Task.checkCancellation()
                }
                try checkOpening()
                let pending = try await self.journal.pending(lease: lease)
                try checkOpening()
                self.context = .init(
                    id: UUID(), epoch: start, authorization: native, scope: scope, lease: lease,
                    isCurrent: isCurrent)
                self.storedPending = pending
                if let pending, pending.phase == .resolved, let outcome = pending.outcome, outcome.isTerminal
                {
                    self.storedResolution = .init(
                        id: UUID(), result: .init(intent: pending.intent.recovery, outcome: outcome))
                } else {
                    self.storedResolution = nil
                }
                try self.check(self.bound())
                if let pending {
                    self.publicationChanged(.pending(pending.intent))
                    try self.check(self.bound())
                    if let outcome = pending.outcome, pending.phase == .resolved, outcome.isTerminal {
                        self.publicationChanged(.resolved(intent: pending.intent, outcome: outcome))
                        try self.check(self.bound())
                    }
                }
            } catch {
                self.journal.fence(lease)
                throw error
            }
        }
    }
    private func match(_ expected: GatewayAvatarReportReviewJournalEntry?, _ context: Context) async throws {
        try check(context)
        let actual = try await journal.pending(lease: context.lease)
        try check(context)
        guard actual == expected else { throw GatewayAvatarReportReviewJournalFailure.inactive }
    }
    private func token(_ context: Context, expected: GatewayAvatarReportReviewJournalEntry?) async throws
        -> GatewaySecret
    {
        try await match(expected, context)
        let token = try await authorization.communityAccessToken(for: context.authorization)
        try await match(expected, context)
        return token
    }
    public func refreshQueue() async throws { try await loadPage(after: nil) }
    public var page: GatewayAvatarReportReviewPageHandle? {
        _ = presentationRevision
        guard let value = livePage() else { return nil }
        return .init(id: value.id)
    }
    public var hasNextPage: Bool {
        _ = presentationRevision
        return livePage()?.value.next != nil
    }
    public func nextPage(_ handle: GatewayAvatarReportReviewPageHandle) async throws {
        guard !isBusy else { throw GatewayAvatarReportReviewFailure.busy }
        guard let value = livePage(), value.id == handle.id, let cursor = value.value.next else {
            throw GatewayAvatarReportReviewFailure.stale
        }
        try await loadPage(after: cursor)
    }
    private func livePage() -> Page? {
        guard isConnected, !isBusy, !denied, storedPending == nil, let page = storedPage,
            let now = try? stamp(), now.milliseconds >= page.observed.milliseconds,
            now.uptime >= page.observed.uptime
        else { return nil }
        return page
    }
    private func loadPage(after: GatewayAvatarReportReviewCursor?) async throws {
        try await exclusive {
            let context = try self.bound()
            guard self.storedPending == nil else {
                throw GatewayAvatarReportReviewJournalFailure.pendingExists
            }
            try await self.match(nil, context)
            self.storedPage = nil
            let token = try await self.token(context, expected: nil)
            let result = try await self.api.queue(after: after, token: token)
            try await self.match(nil, context)
            let now = try self.stamp()
            guard result.items.count <= 20 else { throw GatewayAvatarReportReviewFailure.invalidResponse }
            var previous = after?.value ?? ""
            for item in result.items {
                guard item.reportID > previous,
                    reportReviewDates(
                        created: item.createdAtMilliseconds,
                        expires: item.expiresAtMilliseconds, lifetime: 2_592_000_000, now: now.milliseconds)
                else { throw GatewayAvatarReportReviewFailure.invalidResponse }
                previous = item.reportID
            }
            if let marker = result.next {
                guard marker.value >= previous, marker.value > (after?.value ?? "") else {
                    throw GatewayAvatarReportReviewFailure.invalidResponse
                }
            }
            self.storedPage = .init(id: UUID(), value: result, observed: now)
            self.denied = false
        }
    }
    public func inspect(_ item: GatewayAvatarReportReviewItem) async throws {
        try await exclusive {
            let context = try self.bound()
            guard self.storedPending == nil else {
                throw GatewayAvatarReportReviewJournalFailure.pendingExists
            }
            try await self.match(nil, context)
            guard self.storedPage?.value.items.contains(item) == true,
                reportReviewDates(
                    created: item.createdAtMilliseconds, expires: item.expiresAtMilliseconds,
                    lifetime: 2_592_000_000, now: try self.stamp().milliseconds)
            else { throw GatewayAvatarReportReviewFailure.stale }
            let token = try await self.token(context, expected: nil)
            let result = try await self.api.inspect(item, token: token)
            try await self.match(nil, context)
            try result.receipt.validate(origin: self.api.origin, token: token, stamp: self.stamp())
            guard result.receipt.item == item, gatewayUUID(result.receipt.inspectionID),
                reportReviewHash(result.receipt.contentHash), reportReviewText(result.reason, maximum: 500),
                result.receipt.expiresAtMilliseconds <= item.expiresAtMilliseconds
            else { throw GatewayAvatarReportReviewFailure.invalidResponse }
            if let avatar = result.avatar, let target = result.receipt.photoTarget {
                guard avatar.manifest.variant == .image,
                    avatar.manifest.reference.ownerID == target.ownerID,
                    avatar.manifest.reference.versionID == target.versionID,
                    avatar.image.width == avatar.manifest.width,
                    avatar.image.height == avatar.manifest.height,
                    (1...512).contains(avatar.image.width), (1...512).contains(avatar.image.height)
                else { throw GatewayAvatarReportReviewFailure.invalidResponse }
            } else {
                guard result.avatar == nil, result.receipt.photoTarget == nil else {
                    throw GatewayAvatarReportReviewFailure.invalidResponse
                }
            }
            let value = Inspection(id: UUID(), value: result)
            self.storedInspection = value
            self.displayID = nil
            self.denied = false
            try self.scheduleExpiry(value)
        }
    }
    public func decide(
        _ verdict: GatewayAvatarReportReviewVerdict, presentation: GatewayAvatarReportReviewPresentation
    )
        async throws
    {
        guard let shown = liveInspection(), shown.id == presentation.id, displayID == shown.id,
            storedPending == nil, !denied
        else { throw GatewayAvatarReportReviewHostFailure.displayRequired }
        guard verdict != .hidePhoto || shown.value.avatar != nil else {
            throw GatewayAvatarReportReviewFailure.invalidInput
        }
        try await exclusive {
            let context = try self.bound()
            let token = try await self.token(context, expected: nil)
            try shown.value.receipt.validate(origin: self.api.origin, token: token, stamp: self.stamp())
            let intent = try GatewayAvatarReportReviewDecisionIntent(
                receipt: shown.value.receipt,
                decisionID: UUID().uuidString.lowercased(), verdict: verdict)
            let prepared = try await self.journal.prepare(.init(decision: intent), lease: context.lease)
            try self.check(context)
            self.storedPending = prepared
            self.publicationChanged(.pending(prepared.intent))
            try self.check(context)
            let dispatched = try await self.journal.dispatched(prepared, lease: context.lease)
            try self.check(context)
            self.storedPending = dispatched
            try await self.match(dispatched, context)
            try intent.receipt.validate(origin: self.api.origin, token: token, stamp: self.stamp())
            let result = try await self.api.decide(intent, token: token)
            try await self.match(dispatched, context)
            guard result.intent == intent, gatewayUUID(result.revision) else {
                throw GatewayAvatarReportReviewFailure.invalidResponse
            }
            try intent.receipt.validate(origin: self.api.origin, token: token, stamp: self.stamp())
            let recovered = GatewayAvatarReportReviewRecoveryResult(
                intent: dispatched.intent.recovery, outcome: .confirmed(revision: result.revision))
            let resolved = try await self.journal.resolve(dispatched, result: recovered, lease: context.lease)
            try self.check(context)
            self.storedPending = resolved
            if let outcome = resolved.outcome, resolved.phase == .resolved, outcome.isTerminal {
                self.publicationChanged(.resolved(intent: resolved.intent, outcome: outcome))
                try self.check(context)
            }
            self.storedResolution = .init(id: UUID(), result: recovered)
            try self.check(context)
            self.storedPage = nil
        }
    }
    /// Exact persisted metadata only. No resubmission, fresh inspection, new ID or decision retry.
    public func recover() async throws {
        try await exclusive {
            let context = try self.bound()
            guard let entry = self.storedPending else {
                throw GatewayAvatarReportReviewJournalFailure.invalidTransition
            }
            self.storedResolution = nil
            let token = try await self.token(context, expected: entry)
            let result = try await self.api.recover(entry.intent.recovery, token: token)
            try await self.match(entry, context)
            guard result.intent == entry.intent.recovery else {
                throw GatewayAvatarReportReviewFailure.invalidResponse
            }
            let resolved = try await self.journal.resolve(entry, result: result, lease: context.lease)
            try self.check(context)
            self.storedPending = resolved
            if let outcome = resolved.outcome, resolved.phase == .resolved, outcome.isTerminal {
                self.publicationChanged(.resolved(intent: resolved.intent, outcome: outcome))
                try self.check(context)
            }
            self.storedResolution = result.outcome.isTerminal ? .init(id: UUID(), result: result) : nil
            try self.check(context)
            self.storedPage = nil
            self.denied = false
        }
    }
    /// Explicitly closes only the captured pending attempt; never re-sends or undoes a decision.
    public func retirePending(_ expected: GatewayAvatarReportReviewSavedIntent) async throws {
        guard canRetirePending, storedPending?.intent == expected else {
            throw GatewayAvatarReportReviewJournalFailure.invalidTransition
        }
        try await exclusive {
            let context = try self.bound()
            guard let entry = self.storedPending, entry.intent == expected else {
                throw GatewayAvatarReportReviewJournalFailure.invalidTransition
            }
            self.storedResolution = nil
            let retiring = try await self.journal.retiring(entry, lease: context.lease)
            try self.check(context)
            self.storedPending = retiring
            try await self.match(retiring, context)
            let token = try await self.token(context, expected: retiring)
            let result = try await self.api.retire(retiring.intent.recovery, token: token)
            try await self.match(retiring, context)
            guard result.intent == retiring.intent.recovery, result.outcome.isTerminal else {
                throw GatewayAvatarReportReviewFailure.invalidResponse
            }
            let resolved = try await self.journal.resolve(retiring, result: result, lease: context.lease)
            try self.check(context)
            self.storedPending = resolved
            if let outcome = resolved.outcome, resolved.phase == .resolved, outcome.isTerminal {
                self.publicationChanged(.resolved(intent: resolved.intent, outcome: outcome))
                try self.check(context)
            }
            self.storedResolution = .init(id: UUID(), result: result)
            self.storedPage = nil
            try self.check(context)
        }
    }
    public func acknowledgeResult(_ handle: GatewayAvatarReportReviewResolution) async throws {
        guard !isBusy else { throw GatewayAvatarReportReviewFailure.busy }
        let context = try bound()
        guard let resolution = storedResolution, resolution.id == handle.id, let entry = storedPending,
            entry.intent.recovery == resolution.result.intent, entry.phase == .resolved,
            resolution.result.outcome.isTerminal
        else { throw GatewayAvatarReportReviewJournalFailure.invalidTransition }
        try await exclusive {
            try await self.match(entry, context)
            try await self.journal.acknowledge(entry, lease: context.lease)
            try self.check(context)
            self.storedPending = nil
            self.storedResolution = nil
            self.storedPage = nil
        }
    }
}
