import CoreGraphics
import EchoesCore
import Foundation
import Observation

@MainActor public protocol GatewayAvatarAuthorizationSource: GatewayCommunityAuthorizationSource {
    func privateDataScope(configuration: CloudKitConfiguration) -> PrivateAccountScope?
}
public protocol GatewayAvatarCaching: Sendable {
    func activate(scope: GatewayAvatarCacheScope) async -> GatewayAvatarCacheLease
    func fence(_ lease: GatewayAvatarCacheLease) async
    func read(reference: AvatarReference, variant: AvatarVariant, lease: GatewayAvatarCacheLease) async throws
        -> GatewayAvatarCacheEntry?
    func store(_ bytes: Data, manifest: AvatarManifest, lease: GatewayAvatarCacheLease) async throws
}
extension GatewayAvatarCache: GatewayAvatarCaching {}

public protocol GatewayAvatarDecoding: Sendable {
    func decode(_ bytes: Data, manifest: AvatarManifest) async throws -> ValidatedAvatar
}
public struct NativeGatewayAvatarDecoder: GatewayAvatarDecoding {
    public init() {}
    public func decode(_ bytes: Data, manifest: AvatarManifest) async throws -> ValidatedAvatar {
        try Task.checkCancellation()
        let operation = Task.detached(priority: .utility) {
            try AvatarPayloadValidator.decode(bytes, manifest: manifest)
        }
        let value = try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        return value
    }
}

/// No pixels or authorization token escape in this value. Resolve through the current client only.
public struct GatewayAvatarPresentation: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    fileprivate let id: UUID
    public var description: String { "GatewayAvatarPresentation(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A foreground presentation client. Every load performs a fresh server read, including disk hits.
/// The host must synchronously invalidate on native/background/domain/visibility changes and supply
/// an authoritative current selection predicate. This is not an offline authorization store.
@MainActor @Observable public final class GatewayAvatarClient {
    private struct Context {
        let id: UUID
        let authorization: GatewayCommunityAuthorization
        let scope: GatewayAvatarCacheScope
        let lease: GatewayAvatarCacheLease
    }
    private struct Selection {
        let version: String
        let epoch: UUID
    }
    private struct Request {
        let id: UUID
        let context: Context
        let reference: AvatarReference
        let variant: AvatarVariant
        let coordinate: Coordinate?
        let visibility: UUID
        let selection: UUID
        let startedAt: Double
    }
    private struct Pending {
        let request: Request
        let task: Task<GatewayAvatarPresentation, any Error>
    }
    private struct Image {
        let request: Request
        let avatar: ValidatedAvatar
        let expiresAt: Double
        let bytes: Int
        let order: UInt64
    }
    private let api: any GatewayAvatarReadAPI
    private let cache: any GatewayAvatarCaching
    private let decoder: any GatewayAvatarDecoding
    private let configuration: GatewayConfiguration
    private let cloudKit: CloudKitConfiguration
    private let authorization: any GatewayAvatarAuthorizationSource
    private let isEnabled: @MainActor () -> Bool
    private let isVisible: @MainActor (AvatarReference) -> Bool
    private let uptime: @MainActor () -> Double
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var connecting: UUID?
    @ObservationIgnored private var visibility = UUID()
    @ObservationIgnored private var selections: [String: Selection] = [:]
    @ObservationIgnored private var pending: [UUID: Pending] = [:]
    @ObservationIgnored private var images: [UUID: Image] = [:]
    @ObservationIgnored private var imageOrder: UInt64 = 0
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    public private(set) var presentationRevision = UUID()
    /// One presentation lasts at most 30 seconds from request start, never from a later cache hit.
    public static let maximumPresentationSeconds: Double = 30
    private static let maximumImageBytes = 8 * 1024 * 1024

    public init(
        api: any GatewayAvatarReadAPI, configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration,
        authorization: any GatewayAvatarAuthorizationSource, cache: any GatewayAvatarCaching,
        decoder: any GatewayAvatarDecoding = NativeGatewayAvatarDecoder(),
        isEnabled: @escaping @MainActor () -> Bool,
        isVisible: @escaping @MainActor (AvatarReference) -> Bool,
        uptime: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        guard api.origin == configuration.origin.absoluteString,
            cloudKit.containerIdentifier == "iCloud.mpvEcho.Echo", cloudKit.environment == .development
        else { throw GatewayFailure.configuration }
        self.api = api
        self.configuration = configuration
        self.cloudKit = cloudKit
        self.authorization = authorization
        self.cache = cache
        self.decoder = decoder
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.uptime = uptime
    }
    /// Cancels work but keeps unsettled slots occupied, even when an injected provider ignores cancel.
    /// A still-running connect also retains its slot until its lease acquisition/token await settles.
    public func invalidate() {
        let lease = context?.lease
        context = nil
        visibility = UUID()
        selections.removeAll()
        images.removeAll()
        expiryTask?.cancel()
        expiryTask = nil
        for operation in pending.values { operation.task.cancel() }
        presentationRevision = UUID()
        if let lease { Task { [cache] in await cache.fence(lease) } }
    }
    public func invalidateVisibility() {
        visibility = UUID()
        selections.removeAll()
        images.removeAll()
        for operation in pending.values { operation.task.cancel() }
        expiryTask?.cancel()
        expiryTask = nil
        presentationRevision = UUID()
    }

    /// Releasing a thumbnail must not remove a separately displayed full-size image.
    public func invalidate(reference: AvatarReference, variant: AvatarVariant) {
        images = images.filter {
            $0.value.request.reference != reference || $0.value.request.variant != variant
        }
        for operation in pending.values
        where operation.request.reference == reference && operation.request.variant == variant {
            operation.task.cancel()
        }
        presentationRevision = UUID()
        pruneSelections()
        scheduleExpiry()
    }
    public func invalidate(ownerID: String) { invalidateOwner(ownerID, excluding: nil) }

    @discardableResult public func connect() async throws -> String {
        guard connecting == nil else { throw GatewayAvatarFailure.busy }
        invalidate()
        let operation = UUID()
        let epoch = visibility
        connecting = operation
        defer { if connecting == operation { connecting = nil } }
        guard isEnabled() else { throw GatewayAvatarFailure.unavailable }
        guard let native = authorization.communityAuthorization,
            let privateScope = authorization.privateDataScope(configuration: cloudKit),
            privateScope.accountID == native.identity.accountID
        else { throw GatewayFailure.signInRequired }
        let scope = try GatewayAvatarCacheScope(
            configuration: configuration, privateScope: privateScope, binding: native.identity.binding)
        let lease = await cache.activate(scope: scope)
        do {
            try checkConnection(operation, epoch: epoch, native: native, scope: scope)
            _ = try await authorization.communityAccessToken(for: native)
            try checkConnection(operation, epoch: epoch, native: native, scope: scope)
            context = .init(id: operation, authorization: native, scope: scope, lease: lease)
            return privateScope.accountID
        } catch {
            await cache.fence(lease)
            throw sanitized(error)
        }
    }
    private func checkConnection(
        _ operation: UUID, epoch: UUID, native: GatewayCommunityAuthorization, scope: GatewayAvatarCacheScope
    ) throws {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isEnabled(), connecting == operation, visibility == epoch,
            authorization.communityAuthorization == native,
            authorization.privateDataScope(configuration: cloudKit) == scope.privateScope
        else { throw GatewayAvatarFailure.superseded }
    }
    private func current(_ expected: Context) -> Bool {
        context?.id == expected.id && isEnabled()
            && authorization.communityAuthorization == expected.authorization
            && authorization.privateDataScope(configuration: cloudKit) == expected.scope.privateScope
    }
    private func check(_ request: Request) throws {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        let now = uptime()
        guard current(request.context), visibility == request.visibility,
            selections[request.reference.ownerID]?.epoch == request.selection,
            selections[request.reference.ownerID]?.version == request.reference.versionID,
            isVisible(request.reference), now.isFinite, now >= request.startedAt,
            now < request.startedAt + Self.maximumPresentationSeconds
        else { throw GatewayAvatarFailure.superseded }
    }

    /// New display attempt: never reuses a previous in-memory authorization or a caller-provided hash.
    public func load(
        reference: AvatarReference, variant: AvatarVariant, coordinate: Coordinate? = nil
    ) async throws -> GatewayAvatarPresentation {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard connecting == nil else { throw GatewayAvatarFailure.busy }
        guard isEnabled() else { throw GatewayAvatarFailure.unavailable }
        guard let context, current(context) else { throw GatewayFailure.signInRequired }
        guard isVisible(reference) else { throw GatewayAvatarFailure.notFound }
        _ = try GatewayAvatarQuery(reference: reference, variant: variant, coordinate: coordinate)
        let startedAt = uptime()
        guard startedAt.isFinite, startedAt >= 0 else { throw GatewayAvatarFailure.superseded }
        if selections[reference.ownerID]?.version != reference.versionID {
            invalidateOwner(reference.ownerID, excluding: nil)
        }
        for operation in pending.values
        where operation.request.reference == reference && operation.request.variant == variant {
            operation.task.cancel()
        }
        // A new display attempt invalidates earlier handles for this exact variant immediately.
        images = images.filter {
            $0.value.request.reference != reference || $0.value.request.variant != variant
        }
        presentationRevision = UUID()
        // Revoke old work/pixels even if backpressure denies this new attempt.
        guard pending.count < 4 else { throw GatewayAvatarFailure.limited(retryAfterSeconds: nil) }
        if selections[reference.ownerID] == nil {
            selections[reference.ownerID] = .init(version: reference.versionID, epoch: UUID())
        }
        let request = Request(
            id: UUID(), context: context, reference: reference, variant: variant, coordinate: coordinate,
            visibility: visibility, selection: selections[reference.ownerID]!.epoch, startedAt: startedAt)
        let task = Task { try await perform(request) }
        pending[request.id] = .init(request: request, task: task)
        defer {
            pending.removeValue(forKey: request.id)
            pruneSelections()
        }
        return try await withTaskCancellationHandler {
            let handle = try await task.value
            try check(request)
            guard images[handle.id]?.request.id == request.id else { throw GatewayAvatarFailure.superseded }
            return handle
        } onCancel: {
            task.cancel()
        }
    }
    private func perform(_ request: Request) async throws -> GatewayAvatarPresentation {
        do {
            try check(request)
            var candidate: GatewayAvatarCacheEntry?
            var cachedImage: ValidatedAvatar?
            do {
                candidate = try await cache.read(
                    reference: request.reference, variant: request.variant, lease: request.context.lease)
            } catch {
                try check(request)
                if error is CancellationError { throw GatewayFailure.cancelled }
                if error as? GatewayAvatarCacheFailure == .inactive { throw error }
            }
            try check(request)
            if let value = candidate {
                if value.manifest.reference == request.reference, value.manifest.variant == request.variant,
                    value.bytes.count == value.manifest.byteCount,
                    value.bytes.count <= request.variant.maximumBytes
                {
                    do { cachedImage = try await decoder.decode(value.bytes, manifest: value.manifest) } catch
                    {
                        try check(request)
                        if error is CancellationError { throw GatewayFailure.cancelled }
                    }
                    try check(request)
                    if cachedImage?.manifest != value.manifest { cachedImage = nil }
                }
                if cachedImage == nil { candidate = nil }
            }
            let token = try await authorization.communityAccessToken(for: request.context.authorization)
            try check(request)
            let query = try GatewayAvatarQuery(
                reference: request.reference, variant: request.variant, coordinate: request.coordinate,
                knownSHA256: candidate?.manifest.sha256)
            let reply = try await api.read(query, token: token)
            try check(request)
            let decoded: ValidatedAvatar
            switch reply {
            case .revalidated(let manifest):
                guard let candidate, let cachedImage, candidate.manifest == manifest,
                    cachedImage.manifest == manifest
                else { throw GatewayAvatarFailure.invalidResponse }
                decoded = cachedImage
            case .downloaded(let manifest, let bytes):
                guard manifest.reference == request.reference, manifest.variant == request.variant,
                    bytes.count == manifest.byteCount, bytes.count <= request.variant.maximumBytes
                else { throw GatewayAvatarFailure.invalidResponse }
                do { decoded = try await decoder.decode(bytes, manifest: manifest) } catch {
                    try check(request)
                    if error is CancellationError { throw GatewayFailure.cancelled }
                    throw GatewayAvatarFailure.invalidResponse
                }
                try check(request)
                guard decoded.manifest == manifest else { throw GatewayAvatarFailure.invalidResponse }
                do { try await cache.store(bytes, manifest: manifest, lease: request.context.lease) } catch {
                    try check(request)
                    if error is CancellationError { throw GatewayFailure.cancelled }
                    if error as? GatewayAvatarCacheFailure == .inactive { throw error }
                    // Cache is optional. A fresh validated network image can still be presented.
                }
                try check(request)
            }
            try check(request)
            return try present(decoded, request: request)
        } catch {
            if error as? GatewayAvatarCacheFailure == .inactive {
                if context?.id == request.context.id { invalidate() }
                throw GatewayAvatarFailure.superseded
            }
            if error as? GatewayFailure == .signInRequired {
                let native = authorization.communityAuthorization
                guard context?.id == request.context.id,
                    native == request.context.authorization || native == nil
                else { throw GatewayAvatarFailure.superseded }
                await authorization.rejectCommunityAccess(for: request.context.authorization)
                if context?.id == request.context.id { invalidate() }
                throw GatewayFailure.signInRequired
            }
            try check(request)
            // A fresh refusal/error also clears earlier variants; never fall back to old pixels.
            invalidateOwner(request.reference.ownerID, excluding: request.id)
            throw sanitized(error)
        }
    }
    private func sanitized(_ error: any Error) -> any Error {
        if error is CancellationError { return GatewayFailure.cancelled }
        if let value = error as? GatewayAvatarFailure { return value }
        if let value = error as? GatewayFailure { return value }
        return GatewayAvatarFailure.unavailable
    }

    /// Resolve on each render. The host must observe presentationRevision and never retain pixels
    /// after invalidation. Pixels already copied by an authorized caller cannot be remotely revoked.
    public func image(for presentation: GatewayAvatarPresentation) -> CGImage? {
        _ = presentationRevision
        guard let value = images[presentation.id], current(value.request.context),
            visibility == value.request.visibility,
            selections[value.request.reference.ownerID]?.epoch == value.request.selection,
            isVisible(value.request.reference)
        else { return nil }
        let now = uptime()
        guard now.isFinite, now >= value.request.startedAt, now < value.expiresAt else { return nil }
        return value.avatar.image
    }
    private func present(_ avatar: ValidatedAvatar, request: Request) throws -> GatewayAvatarPresentation {
        try check(request)
        let image = avatar.image
        guard avatar.manifest.reference == request.reference, avatar.manifest.variant == request.variant,
            image.width == avatar.manifest.width, image.height == avatar.manifest.height,
            image.bytesPerRow > 0, image.height > 0,
            image.bytesPerRow <= Self.maximumImageBytes / image.height
        else { throw GatewayAvatarFailure.invalidResponse }
        refreshExpiredPresentations()
        let size = image.bytesPerRow * image.height
        while images.count >= 32 || images.values.reduce(0, { $0 + $1.bytes }) + size > Self.maximumImageBytes
        {
            guard let oldest = images.min(by: { $0.value.order < $1.value.order }) else {
                throw GatewayAvatarFailure.limited(retryAfterSeconds: nil)
            }
            images.removeValue(forKey: oldest.key)
        }
        imageOrder &+= 1
        let id = UUID()
        images[id] = .init(
            request: request, avatar: avatar,
            expiresAt: request.startedAt + Self.maximumPresentationSeconds, bytes: size, order: imageOrder)
        presentationRevision = UUID()
        scheduleExpiry()
        return .init(id: id)
    }
    public func refreshExpiredPresentations() {
        let now = uptime()
        let previous = images.count
        images = images.filter {
            now.isFinite && now >= $0.value.request.startedAt && now < $0.value.expiresAt
        }
        if previous != images.count { presentationRevision = UUID() }
        pruneSelections()
    }
    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard let earliest = images.values.map(\.expiresAt).min() else { return }
        let now = uptime()
        guard now.isFinite, now >= 0 else {
            refreshExpiredPresentations()
            return
        }
        let delay = max(0, earliest - now)
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.refreshExpiredPresentations()
            self.scheduleExpiry()
        }
    }
    private func invalidateOwner(_ owner: String, excluding requestID: UUID?) {
        selections.removeValue(forKey: owner)
        images = images.filter { $0.value.request.reference.ownerID != owner }
        for operation in pending.values
        where operation.request.reference.ownerID == owner && operation.request.id != requestID {
            operation.task.cancel()
        }
        presentationRevision = UUID()
        scheduleExpiry()
    }
    private func pruneSelections() {
        let owners = Set(
            images.values.map { $0.request.reference.ownerID }
                + pending.values.map { $0.request.reference.ownerID })
        selections = selections.filter { owners.contains($0.key) }
    }
}
