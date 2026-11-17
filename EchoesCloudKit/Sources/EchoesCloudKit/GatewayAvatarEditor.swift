import CoreGraphics
import Foundation
import ImageIO
import Observation

public enum GatewayAvatarEditorAction: Sendable {
    case refresh, submit, recover, retryUpload, publish, clear, discardUnsentOrSuperseded
}

/// One owner-photo UI host per Runtime. Its single unsettled slot includes provider preparation,
/// and survives closed/replaced sheets until the dependency actually returns.
@MainActor @Observable public final class GatewayAvatarEditorHost {
    private struct Context {
        let id: UUID
        let native: GatewayCommunityAuthorization
        let owner: PrivateAccountScope
        let isCurrent: @MainActor () -> Bool
    }
    fileprivate let controller: GatewayAvatarOwnerController
    private let cloudKit: CloudKitConfiguration
    private let source: any GatewayAvatarAuthorizationSource
    private let isEnabled: @MainActor () -> Bool
    private var context: Context?
    @ObservationIgnored private weak var editor: GatewayAvatarEditorSession?
    @ObservationIgnored private var cancelWork: (@MainActor () -> Void)?
    private var working: UUID?
    fileprivate var preparing = false
    public init(
        controller: GatewayAvatarOwnerController, cloudKit: CloudKitConfiguration,
        authorization: any GatewayAvatarAuthorizationSource,
        isEnabled: @escaping @MainActor () -> Bool = { false }
    ) throws {
        guard cloudKit.containerIdentifier == "iCloud.mpvEcho.Echo", cloudKit.environment == .development
        else { throw GatewayFailure.configuration }
        self.controller = controller
        self.cloudKit = cloudKit
        source = authorization
        self.isEnabled = isEnabled
    }
    public func open(isCurrent: @escaping @MainActor () -> Bool) throws -> GatewayAvatarEditorSession {
        guard isEnabled(), isCurrent(), let native = source.communityAuthorization,
            let scope = source.privateDataScope(configuration: cloudKit),
            scope.accountID == native.identity.accountID
        else { throw GatewayFailure.signInRequired }
        invalidate()
        let id = UUID()
        context = .init(id: id, native: native, owner: scope, isCurrent: isCurrent)
        let value = GatewayAvatarEditorSession(id: id, host: self)
        editor = value
        return value
    }
    public func invalidate() {
        context = nil
        editor?.clearLocal()
        editor = nil
        cancelWork?()
        controller.invalidate()
        // working deliberately stays occupied until the real provider/controller returns.
    }
    fileprivate func close(_ id: UUID) { if context?.id == id { invalidate() } }
    fileprivate func current(_ id: UUID) -> Bool {
        guard let context, context.id == id else { return false }
        return isEnabled() && context.isCurrent() && source.communityAuthorization == context.native
            && source.privateDataScope(configuration: cloudKit) == context.owner
    }
    fileprivate var busy: Bool { working != nil || controller.isBusy }
    private func check(_ id: UUID) throws {
        guard current(id) else { throw GatewayAvatarOwnerFailure.superseded }
        if Task.isCancelled { throw GatewayFailure.cancelled }
    }
    private func begin(_ id: UUID) throws -> UUID {
        try check(id)
        guard !busy else { throw GatewayAvatarMutationFailure.busy }
        let token = UUID()
        working = token
        editor?.storedError = nil
        return token
    }
    private func finish(_ token: UUID) {
        if working == token {
            working = nil
            preparing = false
            cancelWork = nil
        }
    }
    fileprivate func prepare(
        _ session: GatewayAvatarEditorSession, load: @escaping @Sendable () async throws -> PreparedAvatar
    ) async {
        do {
            let token = try begin(session.id)
            defer { finish(token) }
            preparing = true
            session.clearLocal()
            let task = Task.detached(priority: .utility) { () async throws -> AvatarEditorDraft in
                let prepared = try await load()
                try Task.checkCancellation()
                return try AvatarEditorDraft(prepared)
            }
            cancelWork = { task.cancel() }
            let draft = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try check(session.id)
            session.draft = draft
        } catch { session.fail(error) }
    }
    fileprivate func perform(_ action: GatewayAvatarEditorAction, session: GatewayAvatarEditorSession) async {
        do {
            let token = try begin(session.id)
            defer { finish(token) }
            cancelWork = { [controller] in controller.invalidate() }
            switch action {
            case .refresh:
                if !controller.isConnected {
                    try await controller.connect()
                    try check(session.id)
                }
                try await controller.refresh()
            case .submit:
                guard session.storedConsent, let draft = session.draft else {
                    throw GatewayAvatarMutationFailure.invalidInput
                }
                session.clearLocal()
                try await controller.submit(draft.prepared, consentVersion: 1)
            case .recover: try await controller.recover()
            case .retryUpload: try await controller.retryUpload()
            case .publish: try await controller.publish()
            case .clear:
                session.clearLocal()
                try await controller.clear()
            case .discardUnsentOrSuperseded: try await controller.discardUnsentOrSuperseded()
            }
            try check(session.id)
        } catch { session.fail(error) }
    }
}

private struct AvatarEditorDraft: Sendable {
    let id = UUID()
    let prepared: PreparedAvatar
    let preview: CGImage
    init(_ prepared: PreparedAvatar) throws {
        guard prepared.thumbnail.count <= AvatarPreparer.maximumThumbnailBytes,
            let source = CGImageSourceCreateWithData(prepared.thumbnail as CFData, nil),
            CGImageSourceGetCount(source) == 1,
            let fields = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = fields[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = fields[kCGImagePropertyPixelHeight] as? NSNumber,
            (1...128).contains(width.intValue), (1...128).contains(height.intValue),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
            (1...128).contains(image.width), (1...128).contains(image.height)
        else { throw AvatarPreparationFailure.encodingFailed }
        self.prepared = prepared
        preview = image
    }
}

/// A specific sheet and native account binding. Old sheets cannot read or invalidate a new one.
@MainActor @Observable public final class GatewayAvatarEditorSession: Identifiable {
    public let id: UUID
    private let host: GatewayAvatarEditorHost
    fileprivate var draft: AvatarEditorDraft?
    fileprivate var storedConsent = false
    fileprivate var storedError: String?
    fileprivate init(id: UUID, host: GatewayAvatarEditorHost) {
        self.id = id
        self.host = host
    }
    public var isCurrent: Bool { host.current(id) }
    public var isBusy: Bool { host.busy }
    public var isConnected: Bool { isCurrent && host.controller.isConnected }
    public var needsRefresh: Bool { !isCurrent || host.controller.needsRefresh }
    public var snapshot: GatewayAvatarOwnerSnapshot? { isCurrent ? host.controller.snapshot : nil }
    public var pendingOperation: GatewayAvatarUploadJournalEntry? {
        isCurrent ? host.controller.pendingOperation : nil
    }
    public var selectionID: UUID? { isCurrent ? draft?.id : nil }
    public var preview: CGImage? { isCurrent ? draft?.preview : nil }
    public var errorMessage: String? { isCurrent ? storedError : nil }
    public var consentAccepted: Bool { isCurrent && draft != nil && storedConsent }
    public var canChoosePhoto: Bool { isConnected && !isBusy && !needsRefresh && pendingOperation == nil }
    public var canSubmit: Bool { canChoosePhoto && consentAccepted }
    public var isPreparingPhoto: Bool { isCurrent && host.preparing }
    public var canRefresh: Bool { isCurrent && !isBusy }
    public var canClear: Bool { isConnected && !isBusy }
    public var canRecover: Bool {
        guard isConnected, !isBusy, let entry = pendingOperation else { return false }
        if case .clear = entry.intent { return true }
        return entry.phase != .prepared
    }
    public var canRetryUpload: Bool {
        guard isConnected, !isBusy, let entry = pendingOperation, entry.hasSource,
            case .upload = entry.intent
        else { return false }
        return entry.phase == .prepared || entry.phase == .dispatched
    }
    public var canPublish: Bool {
        guard isConnected, !isBusy, !needsRefresh, let entry = pendingOperation,
            case .upload(let intent) = entry.intent, let value = snapshot, value.status == .approved
        else { return false }
        return entry.phase != .prepared && value.requestID == intent.requestID
            && value.versionID == intent.versionID
            && value.generation == intent.expectedGeneration + 1
    }
    public var canDiscardPending: Bool {
        guard isConnected, !isBusy, !needsRefresh, let entry = pendingOperation, let value = snapshot else {
            return false
        }
        let id: String
        let generation: Int
        switch entry.intent {
        case .upload(let intent): (id, generation) = (intent.requestID, intent.expectedGeneration)
        case .clear(let request, let expected): (id, generation) = (request, expected)
        }
        return value.requestID != id
            && (value.generation > generation || entry.phase == .prepared && value.generation == generation)
    }
    public func consent(_ accepted: Bool, for selection: UUID) {
        guard isCurrent, !isBusy, draft?.id == selection else { return }
        storedConsent = accepted
    }
    public func discardSelection() {
        guard isCurrent, !isBusy else { return }
        clearLocal()
    }
    public func close() { host.close(id) }
    public func prepare(load: @escaping @Sendable () async throws -> PreparedAvatar) async {
        guard canChoosePhoto else { return }
        await host.prepare(self, load: load)
    }
    public func perform(_ action: GatewayAvatarEditorAction) async {
        await host.perform(action, session: self)
    }
    fileprivate func clearLocal() {
        draft = nil
        storedConsent = false
        storedError = nil
    }
    fileprivate func fail(_ error: any Error) {
        guard isCurrent, !Task.isCancelled, !(error is CancellationError),
            error as? GatewayFailure != .cancelled,
            error as? GatewayAvatarOwnerFailure != .superseded
        else { return }
        if let value = error as? AvatarPreparationFailure {
            storedError = value.errorDescription
        } else if let value = error as? GatewayAvatarMutationFailure {
            storedError = value.errorDescription
        } else if let value = error as? GatewayAvatarUploadJournalFailure {
            storedError = value.errorDescription
        } else if let value = error as? GatewayFailure {
            storedError = value.errorDescription
        } else {
            storedError = "Nie udało się przygotować zdjęcia lub potwierdzić operacji. Spróbuj ponownie."
        }
    }
}
