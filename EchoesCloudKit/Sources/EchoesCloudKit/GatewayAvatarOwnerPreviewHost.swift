import CoreGraphics
import Foundation
import Observation

public enum GatewayAvatarOwnerPreviewHostFailure: Error, Equatable, Sendable, LocalizedError {
    case superseded, displayRequired
    public var errorDescription: String? {
        switch self {
        case .superseded: "Konto lub ekran zdjęcia zmieniły się. Otwórz go ponownie."
        case .displayRequired: "Wyświetl aktualny podgląd zdjęcia przed potwierdzeniem publikacji."
        }
    }
}
public struct GatewayAvatarOwnerPreviewPresentation: Hashable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    fileprivate let id: UUID
    public var description: String { "GatewayAvatarOwnerPreviewPresentation(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// One owner preview per Runtime. Caller synchronously invalidates on native/private/parent/scene
/// barriers; getters independently recheck them. UI holds only opaque handles and ACKs actual display.
/// Confirmation consumes the image, rechecks a freshly obtained bearer and returns exact metadata.
/// It never publishes, fabricates consent, persists pixels or substitutes for the owner's journal.
@MainActor @Observable public final class GatewayAvatarOwnerPreviewHost {
    private struct Context {
        let id: UUID, epoch: UUID
        let native: GatewayCommunityAuthorization
        let owner: PrivateAccountScope
        let isCurrent: @MainActor () -> Bool
    }
    private struct Inspection {
        let id: UUID
        let value: GatewayAvatarOwnerPreview
    }
    private let api: any GatewayAvatarOwnerPreviewAPI
    private let configuration: GatewayConfiguration
    private let cloudKit: CloudKitConfiguration
    private let source: any GatewayAvatarAuthorizationSource
    private let isEnabled: @MainActor () -> Bool
    private let date: @MainActor () -> Date
    private let uptime: @MainActor () -> TimeInterval
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var slot: UUID?
    @ObservationIgnored private var cancelWork: (@MainActor () -> Void)?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var storedInspection: Inspection?
    @ObservationIgnored private var displayID: UUID?
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
    public var presentation: GatewayAvatarOwnerPreviewPresentation? {
        _ = presentationRevision
        guard let value = live() else { return nil }
        return .init(id: value.id)
    }
    public init(
        api: any GatewayAvatarOwnerPreviewAPI, configuration: GatewayConfiguration,
        cloudKit: CloudKitConfiguration, authorization: any GatewayAvatarAuthorizationSource,
        isEnabled: @escaping @MainActor () -> Bool = { false },
        date: @escaping @MainActor () -> Date = { Date() },
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        guard api.origin == configuration.origin.absoluteString,
            cloudKit.containerIdentifier == "iCloud.mpvEcho.Echo", cloudKit.environment == .development
        else { throw GatewayFailure.configuration }
        self.api = api
        self.configuration = configuration
        self.cloudKit = cloudKit
        source = authorization
        self.isEnabled = isEnabled
        self.date = date
        self.uptime = uptime
    }
    public func setForeground(_ value: Bool) {
        foreground = value
        if !value { invalidate() }
    }
    public func open(isCurrent: @escaping @MainActor () -> Bool) throws {
        guard foreground, isEnabled(), isCurrent(), let native = source.communityAuthorization,
            let owner = source.privateDataScope(configuration: cloudKit),
            owner.accountID == native.identity.accountID
        else { throw GatewayFailure.signInRequired }
        invalidate()
        context = .init(id: UUID(), epoch: epoch, native: native, owner: owner, isCurrent: isCurrent)
        presentationRevision = UUID()
    }
    public func invalidate() {
        context = nil
        epoch = UUID()
        dropPresentation()
        cancelWork?()
        // The slot is retained until actual token/provider/decode work returns.
    }
    private func stamp() throws -> AvatarOwnerPreviewStamp { try .init(date: date(), uptime: uptime()) }
    private func current(_ expected: Context) -> Bool {
        context?.id == expected.id && epoch == expected.epoch && foreground && isEnabled()
            && expected.isCurrent() && source.communityAuthorization == expected.native
            && source.privateDataScope(configuration: cloudKit) == expected.owner
    }
    private func check(_ expected: Context) throws {
        guard current(expected) else { throw GatewayAvatarOwnerPreviewHostFailure.superseded }
        if Task.isCancelled { throw GatewayFailure.cancelled }
    }
    private func bound() throws -> Context {
        guard let context else { throw GatewayFailure.signInRequired }
        try check(context)
        return context
    }
    private func live() -> Inspection? {
        guard isConnected, !isBusy, let value = storedInspection,
            (try? value.value.observed.validate(stamp())) != nil
        else { return nil }
        return value
    }
    public func image(for handle: GatewayAvatarOwnerPreviewPresentation) -> CGImage? {
        guard let value = live(), value.id == handle.id else { return nil }
        return value.value.avatar.image
    }
    public func canConfirm(_ handle: GatewayAvatarOwnerPreviewPresentation) -> Bool {
        guard let value = live(), value.id == handle.id else { return false }
        return displayID == value.id
    }
    public func matches(
        _ handle: GatewayAvatarOwnerPreviewPresentation, selection: GatewayAvatarPublishIntent
    ) -> Bool {
        guard let value = live(), value.id == handle.id else { return false }
        return value.value.query.selection == selection
    }
    public func acknowledgeDisplay(_ handle: GatewayAvatarOwnerPreviewPresentation) throws {
        guard let value = live(), value.id == handle.id else {
            throw GatewayAvatarOwnerPreviewHostFailure.displayRequired
        }
        displayID = value.id
        presentationRevision = UUID()
    }
    private func dropPresentation() {
        storedInspection = nil
        displayID = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        presentationRevision = UUID()
    }
    public func expirePresentation() {
        guard let value = storedInspection else { return }
        if !isConnected || (try? value.value.observed.validate(stamp())) == nil { dropPresentation() }
    }
    private func scheduleExpiry(_ value: Inspection) throws {
        let now = try stamp()
        let observed = value.value.observed
        try observed.validate(now)
        let milliseconds = Int(
            min(
                Double(30_000 - (now.milliseconds - observed.milliseconds)),
                (30 - (now.uptime - observed.uptime)) * 1000
            ).rounded(.up))
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
            guard self?.storedInspection?.id == value.id else { return }
            self?.expirePresentation()
        }
    }
    private func safe(_ error: any Error) -> any Error {
        if error is CancellationError { return GatewayFailure.cancelled }
        if let value = error as? GatewayAvatarOwnerPreviewHostFailure { return value }
        if let value = error as? GatewayAvatarFailure { return value }
        if let value = error as? GatewayFailure { return value }
        return GatewayAvatarFailure.unavailable
    }
    private func exclusive<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        guard !isBusy else { throw GatewayAvatarFailure.busy }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        let id = UUID()
        let start = epoch
        slot = id
        dropPresentation()
        let task = Task { try await body() }
        cancelWork = { task.cancel() }
        defer {
            if slot == id {
                slot = nil
                cancelWork = nil
                presentationRevision = UUID()
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard epoch == start, let context else { throw GatewayAvatarOwnerPreviewHostFailure.superseded }
            try check(context)
            return result
        } catch {
            if epoch == start {
                dropPresentation()
                if error is CancellationError || error as? GatewayFailure == .cancelled { invalidate() }
                if error as? GatewayFailure == .signInRequired, let context, current(context) {
                    await source.rejectCommunityAccess(for: context.native)
                    if epoch == start, self.context?.id == context.id { invalidate() }
                }
            }
            throw safe(error)
        }
    }
    public func load(_ selection: GatewayAvatarPublishIntent) async throws {
        let context = try bound()
        try await exclusive {
            try self.check(context)
            let token = try await self.source.communityAccessToken(for: context.native)
            try self.check(context)
            let query = try GatewayAvatarOwnerPreviewQuery(
                ownerID: context.owner.accountID, selection: selection)
            let result = try await self.api.preview(query, token: token)
            try self.check(context)
            try result.validate(
                query: query, origin: self.configuration.origin.absoluteString, token: token,
                stamp: self.stamp())
            guard result.avatar.manifest.reference.ownerID == context.owner.accountID,
                result.avatar.manifest.reference.versionID == selection.versionID,
                result.avatar.manifest.variant == .image,
                result.avatar.image.width == result.avatar.manifest.width,
                result.avatar.image.height == result.avatar.manifest.height
            else { throw GatewayAvatarFailure.invalidResponse }
            let value = Inspection(id: UUID(), value: result)
            self.storedInspection = value
            try self.scheduleExpiry(value)
        }
    }
    /// Call only for the user's explicit final confirmation. Consumes the displayed handle before
    /// awaiting credentials; a failed/expired confirmation requires a new explicit preview.
    public func confirmSelection(_ handle: GatewayAvatarOwnerPreviewPresentation) async throws
        -> GatewayAvatarPublishIntent
    {
        let context = try bound()
        guard let shown = live(), shown.id == handle.id, displayID == shown.id else {
            throw GatewayAvatarOwnerPreviewHostFailure.displayRequired
        }
        return try await exclusive {
            try self.check(context)
            let token = try await self.source.communityAccessToken(for: context.native)
            try self.check(context)
            try shown.value.validate(
                query: shown.value.query, origin: self.configuration.origin.absoluteString,
                token: token, stamp: self.stamp())
            return shown.value.query.selection
        }
    }
}
