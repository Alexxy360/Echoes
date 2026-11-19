import Foundation
import Observation

public enum GatewayReportReviewHostFailure: Error, Equatable, Sendable, LocalizedError {
    case superseded, displayRequired
    public var errorDescription: String? {
        switch self {
        case .superseded: "Konto lub ekran moderacji zmieniły się. Otwórz panel ponownie."
        case .displayRequired: "Najpierw wyświetl aktualną treść zgłoszenia."
        }
    }
}
public struct GatewayReportReviewMaterial: Sendable, CustomStringConvertible, CustomReflectable {
    public let reason: String
    public let message: GatewayReportReviewMessage?
    public var description: String { "GatewayReportReviewMaterial(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayReportReviewPageHandle: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    fileprivate let id: UUID
    public var description: String { "GatewayReportReviewPageHandle(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayReportReviewPresentation: Hashable, Sendable, CustomStringConvertible, CustomReflectable
{
    fileprivate let id: UUID
    public var description: String { "GatewayReportReviewPresentation(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayReportReviewResolution: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    fileprivate let id: UUID
    public var description: String { "GatewayReportReviewResolution(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// One foreground operator host. UI resolves opaque handles on each render and acknowledges
/// actual current display. Persisted metadata never restores text or a permission to decide.
@MainActor @Observable public final class GatewayReportReviewHost {
    private struct Context {
        let id: UUID, epoch: UUID
        let authorization: GatewayCommunityAuthorization
        let scope: GatewayReportReviewScope
        let lease: GatewayReportReviewJournalLease
        let isCurrent: @MainActor () -> Bool
    }
    private struct Page {
        let id: UUID
        let value: GatewayReportReviewPage
        let observed: ReportReviewStamp
    }
    private struct Inspection {
        let id: UUID
        let value: GatewayReportReviewInspection
    }
    private struct Resolution {
        let id: UUID
        let result: GatewayReportReviewRecoveryResult
    }
    private let api: any GatewayReportReviewAPI
    private let configuration: GatewayConfiguration
    private let cloudKit: CloudKitConfiguration
    private let authorization: any GatewayAvatarAuthorizationSource
    private let journal: GatewayReportReviewJournal
    private let isEnabled: @MainActor () -> Bool
    private let date: @MainActor () -> Date
    private let uptime: @MainActor () -> TimeInterval
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
    @ObservationIgnored private var storedPending: GatewayReportReviewJournalEntry?
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
    public var queue: [GatewayReportReviewItem] {
        _ = presentationRevision
        guard let page = livePage(), let now = try? stamp() else { return [] }
        return page.value.items.filter {
            $0.createdAtMilliseconds <= now.milliseconds && $0.expiresAtMilliseconds > now.milliseconds
        }
    }
    public var pendingOperation: GatewayReportReviewJournalEntry? {
        _ = presentationRevision
        return isConnected ? storedPending : nil
    }
    public var outcome: GatewayReportReviewOutcome? {
        _ = presentationRevision
        return isConnected && !isBusy ? storedResolution?.result.outcome : nil
    }
    public var resolution: GatewayReportReviewResolution? {
        _ = presentationRevision
        guard isConnected, !isBusy, let value = storedResolution else { return nil }
        return .init(id: value.id)
    }
    public var presentation: GatewayReportReviewPresentation? {
        _ = presentationRevision
        guard let value = liveInspection() else { return nil }
        return .init(id: value.id)
    }
    public var canDecide: Bool {
        _ = presentationRevision
        guard let value = liveInspection() else { return false }
        return displayID == value.id && storedPending == nil && !denied
    }
    public init(
        api: any GatewayReportReviewAPI, configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration,
        authorization: any GatewayAvatarAuthorizationSource, journal: GatewayReportReviewJournal,
        isEnabled: @escaping @MainActor () -> Bool = { false },
        date: @escaping @MainActor () -> Date = { Date() },
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
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
    }
    private func stamp() throws -> ReportReviewStamp { try .init(date: date(), uptime: uptime()) }
    private func current(_ value: Context) -> Bool {
        guard context?.id == value.id, retiredContextID != value.id else { return false }
        let valid =
            foreground && isEnabled() && epoch == value.epoch && value.isCurrent()
            && journal.isActive(value.lease)
            && authorization.communityAuthorization == value.authorization
            && authorization.privateDataScope(configuration: cloudKit) == value.scope.owner
        if !valid { retiredContextID = value.id }
        return valid
    }
    private func check(_ value: Context) throws {
        guard current(value) else { throw GatewayReportReviewHostFailure.superseded }
        if Task.isCancelled { throw GatewayFailure.cancelled }
    }
    private func bound() throws -> Context {
        guard let context else { throw GatewayFailure.signInRequired }
        try check(context)
        return context
    }
    private func dropPresentation() {
        storedInspection = nil
        retiredInspectionID = nil
        displayID = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        presentationRevision = UUID()
    }
    private func reset() {
        if let context { journal.fence(context.lease) }
        context = nil
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
    public func material(for handle: GatewayReportReviewPresentation) -> GatewayReportReviewMaterial? {
        guard let value = liveInspection(), value.id == handle.id else { return nil }
        return .init(reason: value.value.reason, message: value.value.message)
    }
    public var canHideMessage: Bool {
        _ = presentationRevision
        return canDecide && liveInspection()?.value.message != nil
    }
    public func acknowledgeDisplay(_ handle: GatewayReportReviewPresentation) throws {
        guard let value = liveInspection(), value.id == handle.id else {
            throw GatewayReportReviewHostFailure.displayRequired
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
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
            guard self?.storedInspection?.id == id else { return }
            self?.expirePresentation()
        }
    }
    private func safe(_ error: any Error) -> any Error {
        if error is CancellationError { return GatewayFailure.cancelled }
        if let value = error as? GatewayReportReviewFailure { return value }
        if let value = error as? GatewayReportReviewHostFailure { return value }
        if let value = error as? GatewayReportReviewJournalFailure { return value }
        if let value = error as? GatewayFailure { return value }
        return GatewayReportReviewFailure.unavailable
    }
    private func exclusive(_ body: @escaping @MainActor () async throws -> Void) async throws {
        guard slot == nil else { throw GatewayReportReviewFailure.busy }
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
                throw GatewayReportReviewHostFailure.superseded
            }
            if Task.isCancelled { throw GatewayFailure.cancelled }
        } catch {
            if epoch == start {
                dropPresentation()
                if error is CancellationError || error as? GatewayFailure == .cancelled { reset() }
                if let failure = error as? GatewayReportReviewJournalFailure,
                    failure == .inactive || failure == .unavailable
                {
                    reset()
                }
                if error as? GatewayReportReviewFailure == .denied {
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
        guard slot == nil else { throw GatewayReportReviewFailure.busy }
        reset()
        try await exclusive {
            guard self.foreground, self.isEnabled(), isCurrent() else {
                throw GatewayReportReviewHostFailure.superseded
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
            else { throw GatewayReportReviewHostFailure.superseded }
            try Task.checkCancellation()
            let scope = try GatewayReportReviewScope(
                configuration: self.configuration, owner: owner, binding: native.identity.binding)
            let lease = try await self.journal.open(scope: scope)
            do {
                @MainActor func checkOpening() throws {
                    guard self.foreground, self.isEnabled(), isCurrent(), self.epoch == start,
                        self.authorization.communityAuthorization == native,
                        self.authorization.privateDataScope(configuration: self.cloudKit) == owner
                    else { throw GatewayReportReviewHostFailure.superseded }
                    try Task.checkCancellation()
                }
                try checkOpening()
                let pending = try await self.journal.pending(lease: lease)
                try checkOpening()
                self.context = .init(
                    id: UUID(), epoch: start, authorization: native, scope: scope, lease: lease,
                    isCurrent: isCurrent)
                self.storedPending = pending
                try self.check(self.bound())
            } catch {
                self.journal.fence(lease)
                throw error
            }
        }
    }
    private func match(_ expected: GatewayReportReviewJournalEntry?, _ context: Context) async throws {
        try check(context)
        let actual = try await journal.pending(lease: context.lease)
        try check(context)
        guard actual == expected else { throw GatewayReportReviewJournalFailure.inactive }
    }
    private func token(_ context: Context, expected: GatewayReportReviewJournalEntry?) async throws
        -> GatewaySecret
    {
        try await match(expected, context)
        let token = try await authorization.communityAccessToken(for: context.authorization)
        try await match(expected, context)
        return token
    }
    public func refreshQueue() async throws { try await loadPage(after: nil) }
    public var page: GatewayReportReviewPageHandle? {
        _ = presentationRevision
        guard let value = livePage() else { return nil }
        return .init(id: value.id)
    }
    public var hasNextPage: Bool {
        _ = presentationRevision
        return livePage()?.value.next != nil
    }
    public func nextPage(_ handle: GatewayReportReviewPageHandle) async throws {
        guard !isBusy else { throw GatewayReportReviewFailure.busy }
        guard let value = livePage(), value.id == handle.id, let cursor = value.value.next else {
            throw GatewayReportReviewFailure.stale
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
    private func loadPage(after: GatewayReportReviewCursor?) async throws {
        try await exclusive {
            let context = try self.bound()
            guard self.storedPending == nil else { throw GatewayReportReviewJournalFailure.pendingExists }
            try await self.match(nil, context)
            self.storedPage = nil
            let token = try await self.token(context, expected: nil)
            let result = try await self.api.queue(after: after, token: token)
            try await self.match(nil, context)
            let now = try self.stamp()
            guard result.items.count <= 20 else { throw GatewayReportReviewFailure.invalidResponse }
            var previous = after?.value ?? ""
            for item in result.items {
                guard item.reportID > previous,
                    reportReviewDates(
                        created: item.createdAtMilliseconds,
                        expires: item.expiresAtMilliseconds, lifetime: 2_592_000_000, now: now.milliseconds)
                else { throw GatewayReportReviewFailure.invalidResponse }
                previous = item.reportID
            }
            if let marker = result.next {
                guard marker.value >= previous, marker.value > (after?.value ?? "") else {
                    throw GatewayReportReviewFailure.invalidResponse
                }
            }
            self.storedPage = .init(id: UUID(), value: result, observed: now)
            self.denied = false
        }
    }
    public func inspect(_ item: GatewayReportReviewItem) async throws {
        try await exclusive {
            let context = try self.bound()
            guard self.storedPending == nil else { throw GatewayReportReviewJournalFailure.pendingExists }
            try await self.match(nil, context)
            guard self.storedPage?.value.items.contains(item) == true,
                reportReviewDates(
                    created: item.createdAtMilliseconds, expires: item.expiresAtMilliseconds,
                    lifetime: 2_592_000_000, now: try self.stamp().milliseconds)
            else { throw GatewayReportReviewFailure.stale }
            let token = try await self.token(context, expected: nil)
            let result = try await self.api.inspect(item, token: token)
            try await self.match(nil, context)
            try result.receipt.validate(origin: self.api.origin, token: token, stamp: self.stamp())
            guard result.receipt.item == item, gatewayUUID(result.receipt.inspectionID),
                reportReviewHash(result.receipt.contentHash), reportReviewMessageID(result.messageID),
                reportReviewText(result.reason, maximum: 500),
                result.receipt.messageAvailable == (result.message != nil)
            else { throw GatewayReportReviewFailure.invalidResponse }
            if let message = result.message {
                guard gatewayUUID(message.authorID), reportReviewText(message.name, maximum: 40),
                    reportReviewText(message.text, maximum: 500),
                    reportReviewDates(
                        created: message.createdAtMilliseconds, expires: message.expiresAtMilliseconds,
                        lifetime: 7_200_000, now: try self.stamp().milliseconds),
                    result.receipt.expiresAtMilliseconds <= message.expiresAtMilliseconds
                else { throw GatewayReportReviewFailure.invalidResponse }
            }
            let value = Inspection(id: UUID(), value: result)
            self.storedInspection = value
            self.displayID = nil
            self.denied = false
            try self.scheduleExpiry(value)
        }
    }
    public func decide(_ verdict: GatewayReportReviewVerdict, presentation: GatewayReportReviewPresentation)
        async throws
    {
        guard let shown = liveInspection(), shown.id == presentation.id, displayID == shown.id,
            storedPending == nil, !denied
        else { throw GatewayReportReviewHostFailure.displayRequired }
        guard verdict != .hideMessage || shown.value.message != nil else {
            throw GatewayReportReviewFailure.invalidInput
        }
        try await exclusive {
            let context = try self.bound()
            let token = try await self.token(context, expected: nil)
            try shown.value.receipt.validate(origin: self.api.origin, token: token, stamp: self.stamp())
            let intent = try GatewayReportReviewDecisionIntent(
                receipt: shown.value.receipt,
                decisionID: UUID().uuidString.lowercased(), verdict: verdict)
            let prepared = try await self.journal.prepare(.init(decision: intent), lease: context.lease)
            try self.check(context)
            self.storedPending = prepared
            let dispatched = try await self.journal.dispatched(prepared, lease: context.lease)
            try self.check(context)
            self.storedPending = dispatched
            try await self.match(dispatched, context)
            try intent.receipt.validate(origin: self.api.origin, token: token, stamp: self.stamp())
            let result = try await self.api.decide(intent, token: token)
            try await self.match(dispatched, context)
            guard result.intent == intent, gatewayUUID(result.revision) else {
                throw GatewayReportReviewFailure.invalidResponse
            }
            try intent.receipt.validate(origin: self.api.origin, token: token, stamp: self.stamp())
            let recovered = GatewayReportReviewRecoveryResult(
                intent: dispatched.intent, outcome: .confirmed(revision: result.revision))
            let resolved = try await self.journal.resolve(dispatched, result: recovered, lease: context.lease)
            try self.check(context)
            self.storedPending = resolved
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
                throw GatewayReportReviewJournalFailure.invalidTransition
            }
            self.storedResolution = nil
            let token = try await self.token(context, expected: entry)
            let result = try await self.api.recover(entry.intent, token: token)
            try await self.match(entry, context)
            guard result.intent == entry.intent else { throw GatewayReportReviewFailure.invalidResponse }
            let resolved = try await self.journal.resolve(entry, result: result, lease: context.lease)
            try self.check(context)
            self.storedPending = resolved
            self.storedResolution = .init(id: UUID(), result: result)
            try self.check(context)
            self.storedPage = nil
            self.denied = false
        }
    }
    public func acknowledgeResult(_ handle: GatewayReportReviewResolution) async throws {
        guard !isBusy else { throw GatewayReportReviewFailure.busy }
        let context = try bound()
        guard let resolution = storedResolution, resolution.id == handle.id, let entry = storedPending,
            entry.intent == resolution.result.intent
        else { throw GatewayReportReviewJournalFailure.invalidTransition }
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
