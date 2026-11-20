import CoreGraphics
import Foundation
import Observation

public enum GatewayAvatarReportHostFailure: Error, Equatable, Sendable, LocalizedError {
    case superseded, displayRequired
    public var errorDescription: String? {
        switch self {
        case .superseded: "Konto lub ekran zmieniły się. Otwórz zgłoszenie ponownie."
        case .displayRequired: "Najpierw wyświetl aktualne zdjęcie i potwierdź zgłoszenie."
        }
    }
}
public struct GatewayAvatarReportPresentation: Equatable, Sendable, CustomStringConvertible, CustomReflectable
{
    fileprivate let id: UUID
    public var description: String { "GatewayAvatarReportPresentation(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReportResolution: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    fileprivate let id: UUID
    public var description: String { "GatewayAvatarReportResolution(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Foreground reporting of one exact protected photo. Recovery/cancellation use only durable own
/// metadata; they never restore pixels, consent, a reason, GPS or permission to repeat submission.
@MainActor @Observable public final class GatewayAvatarReportHost {
    private struct Context {
        let id: UUID, epoch: UUID
        let authorization: GatewayCommunityAuthorization
        let scope: GatewayAvatarReportScope
        let lease: GatewayAvatarReportJournalLease
        let isCurrent: @MainActor () -> Bool
    }
    private final class Photo {
        let id = UUID()
        let value: GatewayAvatarReportPhoto
        let wall: TimeInterval, uptime: TimeInterval
        let started = ContinuousClock.now
        var floorWall: TimeInterval, floorUptime: TimeInterval
        init(value: GatewayAvatarReportPhoto, wall: TimeInterval, uptime: TimeInterval) {
            self.value = value
            self.wall = wall
            self.uptime = uptime
            floorWall = wall
            floorUptime = uptime
        }
    }
    private struct Resolution {
        let id: UUID
        let result: GatewayAvatarReportResult
    }
    private let api: any GatewayAvatarReportAPI
    private let configuration: GatewayConfiguration
    private let cloudKit: CloudKitConfiguration
    private let authorization: any GatewayAvatarAuthorizationSource
    private let journal: GatewayAvatarReportJournal
    private let isEnabled: @MainActor () -> Bool
    private let canCancel: @MainActor () -> Bool
    private let date: @MainActor () -> Date
    private let uptime: @MainActor () -> TimeInterval
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var retiredContextID: UUID?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var slot: UUID?
    @ObservationIgnored private var operation: Task<Void, any Error>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var photo: Photo?
    @ObservationIgnored private var renderedID: UUID?
    @ObservationIgnored private var displayedID: UUID?
    @ObservationIgnored private var storedPending: GatewayAvatarReportJournalEntry?
    @ObservationIgnored private var storedResolution: Resolution?
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
    public var pendingOperation: GatewayAvatarReportJournalEntry? {
        _ = presentationRevision
        return isConnected ? storedPending : nil
    }
    public var outcome: GatewayAvatarReportOutcome? {
        _ = presentationRevision
        return isConnected && !isBusy ? storedResolution?.result.outcome : nil
    }
    public var resolution: GatewayAvatarReportResolution? {
        _ = presentationRevision
        guard isConnected, !isBusy, storedPending?.phase == .resolved, let result = storedResolution else {
            return nil
        }
        return .init(id: result.id)
    }
    public var canCancelPending: Bool {
        _ = presentationRevision
        return isConnected && !isBusy && canCancel() && storedPending != nil
            && storedPending?.phase != .resolved
    }
    public var presentation: GatewayAvatarReportPresentation? {
        _ = presentationRevision
        guard let value = livePhoto() else { return nil }
        return .init(id: value.id)
    }
    public var canSubmit: Bool {
        _ = presentationRevision
        guard let value = livePhoto() else { return false }
        return displayedID == value.id
    }
    public init(
        api: any GatewayAvatarReportAPI, configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration,
        authorization: any GatewayAvatarAuthorizationSource, journal: GatewayAvatarReportJournal,
        isEnabled: @escaping @MainActor () -> Bool = { false },
        canCancel: @escaping @MainActor () -> Bool = { false },
        date: @escaping @MainActor () -> Date = { Date() },
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
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
        self.canCancel = canCancel
        self.date = date
        self.uptime = uptime
    }
    private func current(_ value: Context) -> Bool {
        guard context?.id == value.id, retiredContextID != value.id else { return false }
        let valid =
            foreground && isEnabled() && epoch == value.epoch && value.isCurrent()
            && journal.isActive(value.lease) && authorization.communityAuthorization == value.authorization
            && authorization.privateDataScope(configuration: cloudKit) == value.scope.owner
        if !valid { retiredContextID = value.id }
        return valid
    }
    private func check(_ value: Context) throws {
        guard current(value) else { throw GatewayAvatarReportHostFailure.superseded }
        if Task.isCancelled { throw GatewayFailure.cancelled }
    }
    private func bound() throws -> Context {
        guard let context else { throw GatewayFailure.signInRequired }
        try check(context)
        return context
    }
    private func dropPhoto(notify: Bool = true) {
        photo = nil
        renderedID = nil
        displayedID = nil
        expiryTask?.cancel()
        expiryTask = nil
        if notify { presentationRevision = UUID() }
    }
    private func reset() {
        if let context { journal.fence(context.lease) }
        context = nil
        retiredContextID = nil
        epoch = UUID()
        storedPending = nil
        storedResolution = nil
        dropPhoto()
    }
    public func invalidate() {
        reset()
        operation?.cancel()
    }
    public func setForeground(_ value: Bool) {
        foreground = value
        if !value { invalidate() }
    }
    private func checkPhoto(_ value: Photo, context: Context) throws {
        try check(context)
        let wall = date().timeIntervalSince1970
        let tick = uptime()
        guard value.started.duration(to: .now) < .seconds(30),
            wall.isFinite, wall >= value.floorWall, wall - value.wall < 30,
            tick.isFinite, tick >= value.floorUptime, tick - value.uptime < 30,
            value.value.origin == api.origin, value.value.authorization == context.authorization,
            value.value.owner == context.scope.owner,
            value.value.reference.ownerID != context.authorization.identity.accountID
        else { throw GatewayAvatarReportHostFailure.displayRequired }
        _ = try value.value.snapshot()
        value.floorWall = wall
        value.floorUptime = tick
    }
    private func livePhoto() -> Photo? {
        guard isConnected, !isBusy, storedPending == nil, let photo, let context else { return nil }
        do {
            try checkPhoto(photo, context: context)
            return photo
        } catch {
            // Render getters retire ignored state without publishing during a SwiftUI update.
            dropPhoto(notify: false)
            return nil
        }
    }
    public func image(for handle: GatewayAvatarReportPresentation) -> CGImage? {
        guard let photo = livePhoto(), photo.id == handle.id,
            let image = try? photo.value.snapshot().image
        else { return nil }
        renderedID = photo.id
        return image
    }
    public func present(_ value: GatewayAvatarReportPhoto) throws {
        guard !isBusy, storedPending == nil else { throw GatewayAvatarReportJournalFailure.pendingExists }
        let context = try bound()
        let wall = date().timeIntervalSince1970
        let tick = uptime()
        dropPhoto()
        guard wall.isFinite, wall >= 0, tick.isFinite, tick >= 0 else {
            throw GatewayAvatarReportHostFailure.displayRequired
        }
        let photo = Photo(value: value, wall: wall, uptime: tick)
        try checkPhoto(photo, context: context)
        self.photo = photo
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard self?.photo?.id == photo.id else { return }
            // A real-time deadline also fences a suspended or stalled injected clock.
            self?.dropPhoto()
        }
        presentationRevision = UUID()
    }
    public func acknowledgeDisplay(_ handle: GatewayAvatarReportPresentation) throws {
        guard let photo = livePhoto(), photo.id == handle.id, renderedID == photo.id else {
            throw GatewayAvatarReportHostFailure.displayRequired
        }
        displayedID = photo.id
        presentationRevision = UUID()
    }
    private func safe(_ error: any Error) -> any Error {
        if error is CancellationError { return GatewayFailure.cancelled }
        if error is GatewayFailure || error is GatewayAvatarReportFailure
            || error is GatewayAvatarReportHostFailure || error is GatewayAvatarReportJournalFailure
        {
            return error
        }
        return GatewayAvatarReportFailure.unavailable
    }
    private func exclusive(_ body: @escaping @MainActor () async throws -> Void) async throws {
        guard slot == nil else { throw GatewayAvatarReportFailure.busy }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        let id = UUID()
        let start = epoch
        slot = id
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
                throw GatewayAvatarReportHostFailure.superseded
            }
            if Task.isCancelled { throw GatewayFailure.cancelled }
        } catch {
            if epoch == start {
                if error as? GatewayFailure == .signInRequired, let context, current(context) {
                    await authorization.rejectCommunityAccess(for: context.authorization)
                }
                if epoch == start { reset() }
            }
            throw safe(error)
        }
    }
    public func connect(isCurrent: @escaping @MainActor () -> Bool = { true }) async throws {
        guard !isBusy else { throw GatewayAvatarReportFailure.busy }
        reset()
        try await exclusive {
            let start = self.epoch
            guard self.foreground, self.isEnabled(), isCurrent(),
                let native = self.authorization.communityAuthorization,
                let owner = self.authorization.privateDataScope(configuration: self.cloudKit),
                owner.accountID == native.identity.accountID
            else { throw GatewayFailure.signInRequired }
            @MainActor func opening() throws {
                guard self.foreground, self.isEnabled(), isCurrent(), self.epoch == start,
                    self.authorization.communityAuthorization == native,
                    self.authorization.privateDataScope(configuration: self.cloudKit) == owner
                else { throw GatewayAvatarReportHostFailure.superseded }
                try Task.checkCancellation()
            }
            _ = try await self.authorization.communityAccessToken(for: native)
            try opening()
            let scope = try GatewayAvatarReportScope(
                configuration: self.configuration, owner: owner, binding: native.identity.binding)
            let lease = try await self.journal.open(scope: scope)
            do {
                try opening()
                let pending = try await self.journal.pending(lease: lease)
                try opening()
                self.context = .init(
                    id: UUID(), epoch: start, authorization: native, scope: scope, lease: lease,
                    isCurrent: isCurrent)
                self.storedPending = pending
                if let pending, pending.phase == .resolved, let outcome = pending.outcome {
                    self.storedResolution = .init(
                        id: UUID(), result: .init(identity: pending.intent, outcome: outcome))
                }
                try self.check(self.bound())
            } catch {
                self.journal.fence(lease)
                throw error
            }
        }
    }
    private func match(_ entry: GatewayAvatarReportJournalEntry?, _ context: Context) async throws {
        try check(context)
        let actual = try await journal.pending(lease: context.lease)
        try check(context)
        guard actual == entry else { throw GatewayAvatarReportJournalFailure.inactive }
    }
    private func token(_ context: Context, entry: GatewayAvatarReportJournalEntry?) async throws
        -> GatewaySecret
    {
        try await match(entry, context)
        let token = try await authorization.communityAccessToken(for: context.authorization)
        try await match(entry, context)
        return token
    }
    public func submit(reason: String, presentation: GatewayAvatarReportPresentation) async throws {
        guard let photo = livePhoto(), photo.id == presentation.id, displayedID == photo.id else {
            throw GatewayAvatarReportHostFailure.displayRequired
        }
        let context = try bound()
        let identity = try GatewayAvatarReportIdentity(
            accountID: context.authorization.identity.accountID, requestID: UUID().uuidString.lowercased())
        let initial = try GatewayAvatarReportSubmission(
            identity: identity, reference: photo.value.reference, reason: reason,
            coordinate: photo.value.snapshot().coordinate)
        dropPhoto()
        try await exclusive {
            let token = try await self.token(context, entry: nil)
            try self.checkPhoto(photo, context: context)
            let prepared = try await self.journal.prepare(identity, lease: context.lease)
            try self.check(context)
            self.storedPending = prepared
            try self.checkPhoto(photo, context: context)
            let entry = try await self.journal.dispatched(prepared, lease: context.lease)
            try self.check(context)
            self.storedPending = entry
            try await self.match(entry, context)
            try self.checkPhoto(photo, context: context)
            let submission = try GatewayAvatarReportSubmission(
                identity: identity, reference: photo.value.reference, reason: initial.reason,
                coordinate: photo.value.snapshot().coordinate)
            let result = try await self.api.submit(submission, token: token)
            try await self.match(entry, context)
            try self.checkPhoto(photo, context: context)
            guard result.identity == identity, result.outcome == .accepted else {
                throw GatewayAvatarReportFailure.invalidResponse
            }
            let resolved = try await self.journal.resolve(entry, result: result, lease: context.lease)
            try self.check(context)
            try self.checkPhoto(photo, context: context)
            self.storedPending = resolved
            self.storedResolution = .init(id: UUID(), result: result)
        }
    }
    public func recover() async throws { try await reconcile(cancellation: false) }
    public func cancelPending() async throws { try await reconcile(cancellation: true) }
    private func reconcile(cancellation: Bool) async throws {
        let context = try bound()
        guard let expected = storedPending, expected.phase != .resolved else {
            throw GatewayAvatarReportJournalFailure.invalidTransition
        }
        guard !cancellation || canCancel() else { throw GatewayAvatarReportFailure.unavailable }
        dropPhoto()
        try await exclusive {
            let token = try await self.token(context, entry: expected)
            var entry = expected
            if cancellation {
                guard self.canCancel() else { throw GatewayAvatarReportFailure.unavailable }
                entry = try await self.journal.cancelling(expected, lease: context.lease)
                try self.check(context)
                self.storedPending = entry
                try await self.match(entry, context)
                guard self.canCancel() else { throw GatewayAvatarReportFailure.unavailable }
            }
            let result =
                try await
                (cancellation
                ? self.api.cancel(entry.intent, token: token) : self.api.recover(entry.intent, token: token))
            try await self.match(entry, context)
            guard result.identity == entry.intent, !cancellation || result.outcome == .cancelled else {
                throw GatewayAvatarReportFailure.invalidResponse
            }
            if cancellation && !self.canCancel() { throw GatewayAvatarReportFailure.unavailable }
            let resolved = try await self.journal.resolve(entry, result: result, lease: context.lease)
            try self.check(context)
            if cancellation && !self.canCancel() { throw GatewayAvatarReportFailure.unavailable }
            self.storedPending = resolved
            self.storedResolution = .init(id: UUID(), result: result)
        }
    }
    public func acknowledgeResult(_ handle: GatewayAvatarReportResolution) async throws {
        let context = try bound()
        guard let result = storedResolution, result.id == handle.id, let entry = storedPending,
            entry.phase == .resolved, entry.intent == result.result.identity,
            entry.outcome == result.result.outcome
        else { throw GatewayAvatarReportJournalFailure.invalidTransition }
        try await exclusive {
            try await self.match(entry, context)
            try await self.journal.acknowledge(entry, lease: context.lease)
            try self.check(context)
            self.storedPending = nil
            self.storedResolution = nil
            self.dropPhoto()
        }
    }
}
