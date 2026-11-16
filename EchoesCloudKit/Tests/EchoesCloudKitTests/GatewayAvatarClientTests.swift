import CoreGraphics
import CryptoKit
import EchoesCore
import Foundation
import ImageIO
import Observation
import Testing

@testable import EchoesCloudKit

private let photoViewerA = "67000000-0000-4000-8000-000000000001"
private let photoViewerB = "67000000-0000-4000-8000-000000000002"

/// Deliberately ignores cancellation while held, so fences must work even for uncooperative providers.
private actor PhotoGate {
    private var armed = 0
    private var arrived = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    func arm(_ count: Int = 1) {
        armed = count
        arrived = 0
    }
    func enter() async {
        guard armed > 0 else { return }
        armed -= 1
        arrived += 1
        await withCheckedContinuation { held.append($0) }
    }
    func wait(_ count: Int = 1) async throws {
        for _ in 0..<5000 {
            if arrived >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw GatewayAvatarFailure.unavailable
    }
    func release() {
        let pending = held
        held = []
        for waiter in pending { waiter.resume() }
    }
}
@MainActor @Observable private final class PhotoAuthorization: GatewayAvatarAuthorizationSource {
    var communityAuthorization: GatewayCommunityAuthorization?
    var cloudName = "synthetic-photo-icloud"
    var foreground = true
    var tokenCalls = 0
    var tokenError = false
    var rejected = 0
    let gate = PhotoGate()
    init() throws { try select(photoViewerA) }
    func select(
        _ id: String, apple: String = "synthetic-photo-apple", cloud: String = "synthetic-photo-icloud"
    ) throws {
        foreground = true
        cloudName = cloud
        communityAuthorization = try .init(
            accountID: id, binding: .init(appleUserID: apple, cloudKitRecordName: cloud), revision: UUID())
    }
    func privateDataScope(configuration: CloudKitConfiguration) -> PrivateAccountScope? {
        guard foreground, let communityAuthorization else { return nil }
        return try? .init(
            configuration: configuration, accountID: communityAuthorization.identity.accountID,
            cloudKitRecordName: cloudName)
    }
    func communityAccessToken(for expected: GatewayCommunityAuthorization) async throws -> GatewaySecret {
        guard communityAuthorization == expected else { throw GatewayFailure.signInRequired }
        tokenCalls += 1
        await gate.enter()
        if tokenError { throw NSError(domain: "PRIVATE-NATIVE-DETAILS-DO-NOT-EXPOSE", code: 7) }
        // Return the captured token even if the native account changed during the await.
        return try .init(expected.identity.accountID + "." + String(repeating: "a", count: 43))
    }
    func rejectCommunityAccess(for expected: GatewayCommunityAuthorization) async {
        guard communityAuthorization == expected else { return }
        rejected += 1
        communityAuthorization = nil
    }
}
private func photoEntry(_ query: GatewayAvatarQuery, large: Bool = false) throws -> GatewayAvatarCacheEntry {
    if large && query.variant == .image { return try largePhotoEntry(query) }
    let f = try AvatarWireFixture(query.variant)
    let raw = try #require(f.downloaded.headers["x-echoes-avatar-manifest"])
    var object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    object["ownerID"] = query.reference.ownerID
    object["versionID"] = query.reference.versionID
    let manifest = try AvatarManifest(
        data: JSONSerialization.data(withJSONObject: object), expected: query.reference,
        variant: query.variant)
    return .init(manifest: manifest, bytes: f.downloaded.body)
}
private actor PhotoAPI: GatewayAvatarReadAPI {
    nonisolated let origin = "https://photo-client.example.invalid"
    enum Mode: Sendable {
        case normal, large, force204, wrong204, wrong200, corrupt200, deny, notFound, unavailable,
            unknownError
    }
    struct Call: Sendable {
        let query: GatewayAvatarQuery
        let token: GatewaySecret
    }
    private var calls: [Call] = []
    private var mode: Mode = .normal
    let gate = PhotoGate()
    func set(_ value: Mode) { mode = value }
    func captured() -> [Call] { calls }
    func read(_ query: GatewayAvatarQuery, token: GatewaySecret) async throws -> GatewayAvatarReply {
        calls.append(.init(query: query, token: token))
        let capturedMode = mode
        let entry = try photoEntry(query, large: capturedMode == .large)
        await gate.enter()
        switch capturedMode {
        case .deny: throw GatewayFailure.signInRequired
        case .notFound: throw GatewayAvatarFailure.notFound
        case .unavailable: throw GatewayAvatarFailure.unavailable
        case .unknownError: throw NSError(domain: "PRIVATE-NETWORK-DETAILS-DO-NOT-EXPOSE", code: 9)
        case .wrong204, .wrong200:
            let wrong = try GatewayAvatarQuery(
                reference: .init(
                    ownerID: query.reference.ownerID, versionID: "67000000-0000-4000-8000-000000000099"),
                variant: query.variant)
            let value = try photoEntry(wrong)
            return capturedMode == .wrong204
                ? .revalidated(manifest: value.manifest)
                : .downloaded(manifest: value.manifest, bytes: value.bytes)
        case .corrupt200:
            var bytes = entry.bytes
            bytes[bytes.count / 2] ^= 1
            return .downloaded(manifest: entry.manifest, bytes: bytes)
        case .force204: return .revalidated(manifest: entry.manifest)
        case .normal, .large:
            return query.knownSHA256 == entry.manifest.sha256
                ? .revalidated(manifest: entry.manifest)
                : .downloaded(manifest: entry.manifest, bytes: entry.bytes)
        }
    }
}
private actor PhotoCache: GatewayAvatarCaching {
    let real: GatewayAvatarCache
    let activateGate = PhotoGate(), readGate = PhotoGate(), storeGate = PhotoGate()
    private var readFailure: GatewayAvatarCacheFailure?
    private var storeFailure: GatewayAvatarCacheFailure?
    private var replacement: GatewayAvatarCacheEntry?
    private(set) var stores = 0
    init(root: URL) throws { real = try .init(root: root) }
    func failRead(_ error: GatewayAvatarCacheFailure?) { readFailure = error }
    func failStore(_ error: GatewayAvatarCacheFailure?) { storeFailure = error }
    func replaceRead(_ value: GatewayAvatarCacheEntry?) { replacement = value }
    func activate(scope: GatewayAvatarCacheScope) async -> GatewayAvatarCacheLease {
        await activateGate.enter()
        return await real.activate(scope: scope)
    }
    func fence(_ lease: GatewayAvatarCacheLease) async { await real.fence(lease) }
    func read(reference: AvatarReference, variant: AvatarVariant, lease: GatewayAvatarCacheLease) async throws
        -> GatewayAvatarCacheEntry?
    {
        if let readFailure { throw readFailure }
        let result = try await real.read(reference: reference, variant: variant, lease: lease)
        await readGate.enter()
        return replacement ?? result
    }
    func store(_ bytes: Data, manifest: AvatarManifest, lease: GatewayAvatarCacheLease) async throws {
        stores += 1
        await storeGate.enter()
        if let storeFailure { throw storeFailure }
        try await real.store(bytes, manifest: manifest, lease: lease)
    }
}
private actor PhotoDecoder: GatewayAvatarDecoding {
    let gate = PhotoGate()
    func decode(_ bytes: Data, manifest: AvatarManifest) async throws -> ValidatedAvatar {
        await gate.enter()
        // Ignore caller cancellation for this model; the presentation client still must fence it.
        return try await Task.detached { try AvatarPayloadValidator.decode(bytes, manifest: manifest) }.value
    }
}
@MainActor @Observable private final class PhotoState {
    var enabled = true
    var visible = true
    var hiddenOwners: Set<String> = []
    var versions: [String: String] = [:]
    var time: Double = 100
    func allows(_ reference: AvatarReference) -> Bool {
        visible && !hiddenOwners.contains(reference.ownerID)
            && (versions[reference.ownerID] == nil || versions[reference.ownerID] == reference.versionID)
    }
}
@MainActor private struct PhotoFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "echoes-photo-client-" + UUID().uuidString)
    let source: PhotoAuthorization
    let state = PhotoState()
    let api = PhotoAPI()
    let cache: PhotoCache
    let decoder = PhotoDecoder()
    let config: GatewayConfiguration
    let cloudKit: CloudKitConfiguration
    let reference: AvatarReference
    let client: GatewayAvatarClient
    init() throws {
        source = try .init()
        cache = try .init(root: root)
        config = try .init(origin: URL(string: api.origin)!)
        cloudKit = try .init(containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
        reference = try AvatarWireFixture().query.reference
        client = try .init(
            api: api, configuration: config, cloudKit: cloudKit, authorization: source, cache: cache,
            decoder: decoder,
            isEnabled: { [state] in state.enabled }, isVisible: { [state] in state.allows($0) },
            uptime: { [state] in state.time })
    }
    func load(_ reference: AvatarReference? = nil, variant: AvatarVariant = .thumbnail) async throws
        -> GatewayAvatarPresentation
    {
        try await client.load(
            reference: reference ?? self.reference, variant: variant,
            coordinate: .init(latitude: 51.11, longitude: 17.03))
    }
    func cleanup() {
        client.invalidate()
        try? FileManager.default.removeItem(at: root)
    }
}

@Test @MainActor func avatarClientFreshDownloadAndDiskHitBothRequireFreshNativeTokenAndServer() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    #expect(try await f.client.connect() == photoViewerA)
    let first = try await f.load()
    #expect(f.client.image(for: first)?.width == 128)
    let second = try await f.load()
    #expect(f.client.image(for: first) == nil)
    #expect(f.client.image(for: second)?.width == 128)
    let calls = await f.api.captured()
    #expect(calls.count == 2 && calls[0].query.knownSHA256 == nil && calls[1].query.knownSHA256 != nil)
    let stores = await f.cache.stores
    #expect(f.source.tokenCalls == 3 && stores == 1)
    #expect(!String(reflecting: second).contains(f.reference.ownerID))
    #expect(Mirror(reflecting: second).children.isEmpty)
}

@Test @MainActor func avatarClientNewViewerCannotBorrowPreviousViewersDiskCandidateOrHandle() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let old = try await f.load()
    try f.source.select(photoViewerB)
    #expect(f.client.image(for: old) == nil)
    try await f.client.connect()
    let fresh = try await f.load()
    #expect(f.client.image(for: fresh) != nil)
    let calls = await f.api.captured()
    #expect(calls.count == 2 && calls[1].query.knownSHA256 == nil)
    #expect(calls[1].token.value.hasPrefix(photoViewerB + "."))
}

@Test @MainActor func avatarClientRefuses204WithoutCandidateAndMismatchingManifestsOrPixels() async throws {
    for mode in [PhotoAPI.Mode.force204, .wrong200, .corrupt200] {
        let f = try PhotoFixture()
        defer { f.cleanup() }
        try await f.client.connect()
        await f.api.set(mode)
        await #expect(throws: GatewayAvatarFailure.invalidResponse) { try await f.load() }
    }
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    _ = try await f.load()
    await f.api.set(.wrong204)
    await #expect(throws: GatewayAvatarFailure.invalidResponse) { try await f.load() }
}

@Test @MainActor func avatarClientNeverFallsBackToCachedPixelsAfterRefusalOrNetworkFailure() async throws {
    for (mode, error) in [
        (PhotoAPI.Mode.notFound, GatewayAvatarFailure.notFound), (.unavailable, .unavailable),
    ] {
        let f = try PhotoFixture()
        defer { f.cleanup() }
        try await f.client.connect()
        let old = try await f.load()
        await f.api.set(mode)
        await #expect(throws: error) { try await f.load() }
        #expect(f.client.image(for: old) == nil)
    }
}

@Test @MainActor func avatarClientRejectedSessionClosesAllHandlesAndRejectsOnlyItsNativeSnapshot()
    async throws
{
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let old = try await f.load()
    await f.api.set(.deny)
    await #expect(throws: GatewayFailure.signInRequired) { try await f.load() }
    #expect(f.source.rejected == 1 && f.source.communityAuthorization == nil)
    #expect(f.client.image(for: old) == nil)
}

@Test @MainActor func avatarClientCacheReadOrWriteFailureStillAllowsFreshAuthorizedNetworkImage() async throws
{
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    await f.cache.failRead(.unavailable)
    await f.cache.failStore(.unavailable)
    let handle = try await f.load()
    #expect(f.client.image(for: handle) != nil)
    #expect(await f.api.captured().count == 1)
}

@Test @MainActor func avatarClientInactiveCacheLeaseClosesTheEntirePresentationContext() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let old = try await f.load()
    await f.cache.failRead(.inactive)
    await #expect(throws: GatewayAvatarFailure.superseded) { try await f.load(variant: .image) }
    #expect(f.client.image(for: old) == nil)
    await #expect(throws: GatewayFailure.signInRequired) { try await f.load() }
}

@Test @MainActor func avatarClientPresentationExpiresFromRequestStartAndNeverSurvivesClockRollback()
    async throws
{
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let first = try await f.load()
    let revision = f.client.presentationRevision
    f.state.time += 30
    #expect(f.client.image(for: first) == nil)
    f.client.refreshExpiredPresentations()
    #expect(f.client.presentationRevision != revision)
    let next = try await f.load()
    f.state.time -= 1
    #expect(f.client.image(for: next) == nil)
}

@Test @MainActor func avatarClientBackgroundVisibilityAndOwnerInvalidationSynchronouslyHideHandles()
    async throws
{
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let background = try await f.load()
    f.source.foreground = false
    #expect(f.client.image(for: background) == nil)
    f.source.foreground = true
    let hidden = try await f.load()
    f.state.hiddenOwners.insert(f.reference.ownerID)
    #expect(f.client.image(for: hidden) == nil)
    f.state.hiddenOwners.removeAll()
    let owner = try await f.load()
    f.client.invalidate(ownerID: f.reference.ownerID)
    #expect(f.client.image(for: owner) == nil)
    let global = try await f.load()
    f.client.invalidateVisibility()
    #expect(f.client.image(for: global) == nil)
}

@Test @MainActor func avatarClientAccountChangeDuringDiskReadStopsBeforeTokenAndServer() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    _ = try await f.load()
    let gate = await f.cache.readGate
    await gate.arm()
    let operation = Task { try await f.load() }
    defer {
        operation.cancel()
        Task { await gate.release() }
    }
    try await gate.wait()
    try f.source.select(photoViewerB)
    await gate.release()
    await #expect(throws: GatewayAvatarFailure.superseded) { try await operation.value }
    #expect(await f.api.captured().count == 1)
    #expect(f.source.tokenCalls == 2)
}

@Test @MainActor func avatarClientAccountChangeDuringTokenReadNeverDispatchesTheCapturedBearer() async throws
{
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let gate = f.source.gate
    await gate.arm()
    let operation = Task { try await f.load() }
    defer {
        operation.cancel()
        Task { await gate.release() }
    }
    try await gate.wait()
    try f.source.select(photoViewerB)
    await gate.release()
    await #expect(throws: GatewayAvatarFailure.superseded) { try await operation.value }
    #expect(await f.api.captured().isEmpty)
}

@Test @MainActor func avatarClientOldNetworkResultCannotPopulateOrClearTheNewViewer() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let gate = await f.api.gate
    await gate.arm()
    let old = Task { try await f.load() }
    defer {
        old.cancel()
        Task { await gate.release() }
    }
    try await gate.wait()
    try f.source.select(photoViewerB)
    try await f.client.connect()
    let new = try await f.load()
    await gate.release()
    await #expect(throws: GatewayFailure.cancelled) { try await old.value }
    #expect(f.client.image(for: new) != nil && f.source.rejected == 0)
}

@Test @MainActor func avatarClientLate401ForOldViewerNeverRejectsTheNewNativeSession() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    await f.api.set(.deny)
    let gate = await f.api.gate
    await gate.arm()
    let old = Task { try await f.load() }
    defer {
        old.cancel()
        Task { await gate.release() }
    }
    try await gate.wait()
    await f.api.set(.normal)
    try f.source.select(photoViewerB)
    try await f.client.connect()
    let new = try await f.load()
    await gate.release()
    await #expect(throws: GatewayAvatarFailure.superseded) { try await old.value }
    #expect(f.client.image(for: new) != nil && f.source.rejected == 0)
    #expect(f.source.communityAuthorization?.identity.accountID == photoViewerB)
}

@Test @MainActor func avatarClientPrivateICloudScopeChangeCutsLateBytesEvenWithSameGatewaySnapshot()
    async throws
{
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let gate = await f.api.gate
    await gate.arm()
    let operation = Task { try await f.load() }
    defer {
        operation.cancel()
        Task { await gate.release() }
    }
    try await gate.wait()
    f.source.cloudName = "other-native-icloud"
    await gate.release()
    await #expect(throws: GatewayAvatarFailure.superseded) { try await operation.value }
    #expect(await f.cache.stores == 0)
    #expect(f.source.rejected == 0)
}

@Test @MainActor func avatarClientVisibilityPredicateCutsLateNetworkResultWithoutRelyingOnCancellation()
    async throws
{
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let gate = await f.api.gate
    await gate.arm()
    let operation = Task { try await f.load() }
    defer {
        operation.cancel()
        Task { await gate.release() }
    }
    try await gate.wait()
    f.state.visible = false
    await gate.release()
    await #expect(throws: GatewayAvatarFailure.superseded) { try await operation.value }
    #expect(await f.cache.stores == 0)
}

@Test @MainActor func avatarClientSlowResponseCannotRenewPresentationTimeFromItsArrival() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let gate = await f.api.gate
    await gate.arm()
    let operation = Task { try await f.load() }
    defer {
        operation.cancel()
        Task { await gate.release() }
    }
    try await gate.wait()
    f.state.time += 20
    await gate.release()
    let handle = try await operation.value
    #expect(f.client.image(for: handle) != nil)
    f.state.time += 10
    #expect(f.client.image(for: handle) == nil)
}

@Test @MainActor func avatarClientTotalDeadlineRejectsEvenAValidLateNetworkImage() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let gate = await f.api.gate
    await gate.arm()
    let operation = Task { try await f.load() }
    defer {
        operation.cancel()
        Task { await gate.release() }
    }
    try await gate.wait()
    f.state.time += 31
    await gate.release()
    await #expect(throws: GatewayAvatarFailure.superseded) { try await operation.value }
    #expect(await f.cache.stores == 0)
}

@Test @MainActor func avatarClientAccountChangeDuringCachedDecodeStopsBeforeCacheRevalidation() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    _ = try await f.load()
    let gate = await f.decoder.gate
    await gate.arm()
    let operation = Task { try await f.load() }
    defer {
        operation.cancel()
        Task { await gate.release() }
    }
    try await gate.wait()
    try f.source.select(photoViewerB)
    await gate.release()
    await #expect(throws: GatewayAvatarFailure.superseded) { try await operation.value }
    #expect(await f.api.captured().count == 1)
}

@Test @MainActor func avatarClientNewVersionSurvivesOldDecoderCompletionThatIgnoresCancellation() async throws
{
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let gate = await f.decoder.gate
    await gate.arm()
    let old = Task { try await f.load() }
    defer {
        old.cancel()
        Task { await gate.release() }
    }
    try await gate.wait()
    let next = try AvatarReference(
        ownerID: f.reference.ownerID, versionID: "67000000-0000-4000-8000-000000000077")
    f.state.versions[next.ownerID] = next.versionID
    let new = try await f.load(next)
    await gate.release()
    await #expect(throws: GatewayFailure.cancelled) { try await old.value }
    #expect(f.client.image(for: new) != nil)
}

@Test @MainActor func avatarClientVisibilityChangeDuringCacheWritePreventsPixelPublication() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let gate = await f.cache.storeGate
    await gate.arm()
    let operation = Task { try await f.load() }
    defer {
        operation.cancel()
        Task { await gate.release() }
    }
    try await gate.wait()
    f.state.hiddenOwners.insert(f.reference.ownerID)
    await gate.release()
    await #expect(throws: GatewayAvatarFailure.superseded) { try await operation.value }
    f.state.hiddenOwners.removeAll()
    let fresh = try await f.load()
    #expect(f.client.image(for: fresh) != nil)
    let calls = await f.api.captured()
    #expect(calls.count == 2 && calls.last?.query.knownSHA256 != nil)
}

@Test @MainActor func avatarClientInvalidatedConnectRetainsItsSlotUntilLateLeaseIsFenced() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    let gate = await f.cache.activateGate
    await gate.arm()
    let operation = Task { try await f.client.connect() }
    defer {
        operation.cancel()
        Task { await gate.release() }
    }
    try await gate.wait()
    f.client.invalidate()
    await #expect(throws: GatewayAvatarFailure.busy) { try await f.client.connect() }
    await gate.release()
    await #expect(throws: GatewayAvatarFailure.superseded) { try await operation.value }
    #expect(f.source.tokenCalls == 0)
    #expect(try await f.client.connect() == photoViewerA)
    #expect(f.client.image(for: try await f.load()) != nil)
}

@Test @MainActor func avatarClientCancelledRequestsKeepBackpressureUntilUncooperativeProviderSettles()
    async throws
{
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let gate = await f.api.gate
    await gate.arm(4)
    var operations: [Task<GatewayAvatarPresentation, any Error>] = []
    for i in 11...14 {
        let reference = try AvatarReference(
            ownerID: String(format: "67000000-0000-4000-8000-%012d", i), versionID: f.reference.versionID)
        operations.append(Task { try await f.load(reference) })
    }
    defer {
        for operation in operations { operation.cancel() }
        Task { await gate.release() }
    }
    try await gate.wait(4)
    f.client.invalidate()
    try await f.client.connect()
    await #expect(throws: GatewayAvatarFailure.limited(retryAfterSeconds: nil)) { try await f.load() }
    await gate.release()
    for operation in operations {
        await #expect(throws: GatewayFailure.cancelled) { try await operation.value }
    }
    #expect(f.client.image(for: try await f.load()) != nil)
}

@Test @MainActor func avatarClientBoundsDecodedHandlesAcrossManyVisibleOwners() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    var handles: [GatewayAvatarPresentation] = []
    for i in 100...134 {
        let reference = try AvatarReference(
            ownerID: String(format: "67000000-0000-4000-8000-%012d", i), versionID: f.reference.versionID)
        handles.append(try await f.load(reference))
    }
    #expect(handles.prefix(3).allSatisfy { f.client.image(for: $0) == nil })
    #expect(handles.suffix(32).allSatisfy { f.client.image(for: $0) != nil })
}

@Test @MainActor func avatarClientIgnoresForeignCacheManifestAndRequiresFreshBytes() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let wrong = try GatewayAvatarQuery(
        reference: .init(ownerID: photoViewerB, versionID: f.reference.versionID), variant: .thumbnail)
    await f.cache.replaceRead(try photoEntry(wrong))
    let handle = try await f.load()
    #expect(f.client.image(for: handle) != nil)
    #expect(await f.api.captured().first?.query.knownSHA256 == nil)
}

@Test @MainActor func avatarClientDisabledOrUnconnectedNeverReadsDiskOrDispatchesBearer() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    await #expect(throws: GatewayFailure.signInRequired) { try await f.load() }
    f.state.enabled = false
    await #expect(throws: GatewayAvatarFailure.unavailable) { try await f.client.connect() }
    await #expect(throws: GatewayAvatarFailure.unavailable) { try await f.load() }
    #expect(await f.api.captured().isEmpty)
    #expect(f.source.tokenCalls == 0)
}

@Test func nativeAvatarDecoderCancelledBeforeStartNeverProducesPixels() async throws {
    let wire = try AvatarWireFixture()
    let entry = try photoEntry(wire.query)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await NativeGatewayAvatarDecoder().decode(entry.bytes, manifest: entry.manifest)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

private func largePhotoEntry(_ query: GatewayAvatarQuery) throws -> GatewayAvatarCacheEntry {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 2048, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let data = output as Data
    let fields: [String: Any] = [
        "schemaVersion": 1, "ownerID": query.reference.ownerID, "versionID": query.reference.versionID,
        "variant": "image", "byteCount": data.count, "width": 512, "height": 512,
        "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
    ]
    let manifest = try AvatarManifest(
        data: JSONSerialization.data(withJSONObject: fields), expected: query.reference, variant: .image)
    return .init(manifest: manifest, bytes: data)
}

@Test @MainActor func avatarClientDecodedByteQuotaEvictsBeforeHandleCountLimit() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    await f.api.set(.large)
    var handles: [GatewayAvatarPresentation] = []
    for i in 200...208 {
        let reference = try AvatarReference(
            ownerID: String(format: "67000000-0000-4000-8000-%012d", i), versionID: f.reference.versionID)
        handles.append(try await f.load(reference, variant: .image))
    }
    #expect(f.client.image(for: handles[0]) == nil)
    let images = handles.compactMap { f.client.image(for: $0) }
    #expect(images.count < 9 && images.count > 0)
    #expect(images.reduce(0) { $0 + $1.bytesPerRow * $1.height } <= 8 * 1024 * 1024)
    #expect(images.allSatisfy { $0.width == 512 && $0.height == 512 })
}

private final class PhotoObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func read() -> Bool { lock.withLock { value } }
}
@Test @MainActor func avatarClientRenderObservationTracksNativeAndPresentationInvalidation() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let handle = try await f.load()
    let native = PhotoObservationFlag()
    withObservationTracking {
        #expect(f.client.image(for: handle) != nil)
    } onChange: {
        native.set()
    }
    f.source.foreground = false
    #expect(native.read() && f.client.image(for: handle) == nil)
    f.source.foreground = true
    let fresh = try await f.load()
    let policy = PhotoObservationFlag()
    withObservationTracking {
        #expect(f.client.image(for: fresh) != nil)
    } onChange: {
        policy.set()
    }
    f.client.invalidateVisibility()
    #expect(policy.read() && f.client.image(for: fresh) == nil)
}

private actor PhotoWireTransport: GatewayAvatarTransport {
    private(set) var count = 0
    func send(_ request: URLRequest, query: GatewayAvatarQuery) async throws -> GatewayAvatarHTTPResponse {
        count += 1
        let fixture = try AvatarWireFixture(query.variant)
        return query.knownSHA256 == nil ? fixture.downloaded : fixture.revalidated
    }
}
@Test @MainActor func avatarClientActualServerFixtureBridgesHTTPDiskAndNativeImageIO() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    let transport = PhotoWireTransport()
    let api = GatewayAvatarHTTPClient(configuration: f.config, transport: transport, isEnabled: { true })
    let client = try GatewayAvatarClient(
        api: api, configuration: f.config, cloudKit: f.cloudKit, authorization: f.source, cache: f.cache,
        isEnabled: { true }, isVisible: { [state = f.state] in state.allows($0) })
    defer { client.invalidate() }
    try await client.connect()
    let first = try await client.load(reference: f.reference, variant: .thumbnail)
    #expect(client.image(for: first)?.width == 128)
    let second = try await client.load(reference: f.reference, variant: .thumbnail)
    #expect(client.image(for: first) == nil && client.image(for: second)?.width == 128)
    #expect(await transport.count == 2)
    #expect(f.source.tokenCalls == 3)
}

@Test @MainActor func avatarClientCorruptDiskCandidateDoesNotSendItsHashForRevalidation() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let query = try GatewayAvatarQuery(reference: f.reference, variant: .thumbnail)
    let original = try photoEntry(query)
    var bytes = original.bytes
    bytes[bytes.count / 2] ^= 1
    await f.cache.replaceRead(.init(manifest: original.manifest, bytes: bytes))
    let handle = try await f.load()
    #expect(f.client.image(for: handle) != nil)
    #expect(await f.api.captured().first?.query.knownSHA256 == nil)
}

@Test @MainActor func avatarClientLostCacheLeaseDuringStoreClosesPreviouslyAuthorizedVariants() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let old = try await f.load()
    await f.cache.failStore(.inactive)
    await #expect(throws: GatewayAvatarFailure.superseded) { try await f.load(variant: .image) }
    #expect(f.client.image(for: old) == nil && f.source.rejected == 0)
    await #expect(throws: GatewayFailure.signInRequired) { try await f.load() }
}

@Test @MainActor func avatarClientSameAccountNewNativeRevisionAndVisibilityABACutOldPresentations()
    async throws
{
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let first = try await f.load()
    try f.source.select(photoViewerA)
    #expect(f.client.image(for: first) == nil)
    try await f.client.connect()
    let gate = await f.api.gate
    await gate.arm()
    let old = Task { try await f.load() }
    defer {
        old.cancel()
        Task { await gate.release() }
    }
    try await gate.wait()
    f.state.visible = false
    f.client.invalidateVisibility()
    f.state.visible = true
    await gate.release()
    await #expect(throws: GatewayFailure.cancelled) { try await old.value }
    let next = try await f.load()
    #expect(f.client.image(for: next) != nil)
}

@Test @MainActor func avatarClientBackpressureNeverKeepsEarlierPixelsAsFallbackForNewDisplayAttempt()
    async throws
{
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let old = try await f.load()
    let gate = await f.api.gate
    await gate.arm(4)
    var operations: [Task<GatewayAvatarPresentation, any Error>] = []
    for i in 300...303 {
        let reference = try AvatarReference(
            ownerID: String(format: "67000000-0000-4000-8000-%012d", i), versionID: f.reference.versionID)
        operations.append(Task { try await f.load(reference) })
    }
    defer {
        for operation in operations { operation.cancel() }
        Task { await gate.release() }
    }
    try await gate.wait(4)
    await #expect(throws: GatewayAvatarFailure.limited(retryAfterSeconds: nil)) { try await f.load() }
    #expect(f.client.image(for: old) == nil)
    f.client.invalidate()
    await gate.release()
    for operation in operations {
        await #expect(throws: GatewayFailure.cancelled) { try await operation.value }
    }
}

@Test @MainActor func avatarClientCallerCancellationBeforeDispatchNeverReadsAnAccessToken() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await f.load()
    }
    await #expect(throws: GatewayFailure.cancelled) { try await task.value }
    #expect(f.source.tokenCalls == 1)
    #expect(await f.api.captured().isEmpty)
}

@Test @MainActor func avatarClientAutomaticallyExpiresAndReschedulesObservablePixelsWithoutRefresh()
    async throws
{
    let f = try PhotoFixture()
    defer { f.cleanup() }
    let client = try GatewayAvatarClient(
        api: f.api, configuration: f.config, cloudKit: f.cloudKit, authorization: f.source, cache: f.cache,
        isEnabled: { true }, isVisible: { [state = f.state] in state.allows($0) })
    defer { client.invalidate() }
    try await client.connect()
    let handle = try await client.load(reference: f.reference, variant: .thumbnail)
    try await Task.sleep(for: .seconds(1))
    let laterReference = try AvatarReference(ownerID: photoViewerB, versionID: f.reference.versionID)
    let later = try await client.load(reference: laterReference, variant: .thumbnail)
    let flag = PhotoObservationFlag()
    withObservationTracking {
        #expect(client.image(for: handle) != nil)
    } onChange: {
        flag.set()
    }
    let deadline = ContinuousClock.now + .seconds(35)
    while !flag.read(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
    #expect(flag.read())
    #expect(client.image(for: handle) == nil)
    if client.image(for: later) != nil {
        let rescheduled = PhotoObservationFlag()
        withObservationTracking {
            #expect(client.image(for: later) != nil)
        } onChange: {
            rescheduled.set()
        }
        while !rescheduled.read(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(rescheduled.read())
        print("ECHOES_AVATAR_CLIENT_EXPIRY_RESCHEDULE=observed")
    }
    #expect(client.image(for: later) == nil)
}

@Test @MainActor func avatarClientInvalidClockCannotCreateAnInvalidTimerOrResurrectOtherPixels() async throws
{
    let f = try PhotoFixture()
    defer { f.cleanup() }
    try await f.client.connect()
    _ = try await f.load()
    let reference = try AvatarReference(ownerID: photoViewerB, versionID: f.reference.versionID)
    let other = try await f.load(reference)
    f.state.time = .nan
    f.client.invalidate(ownerID: f.reference.ownerID)
    f.state.time = 100
    #expect(f.client.image(for: other) == nil)
}

@Test @MainActor func avatarClientUnknownNativeOrNetworkErrorsNeverEscapeTheirPrivateDetails() async throws {
    let f = try PhotoFixture()
    defer { f.cleanup() }
    f.source.tokenError = true
    await #expect(throws: GatewayAvatarFailure.unavailable) { try await f.client.connect() }
    f.source.tokenError = false
    try await f.client.connect()
    let old = try await f.load()
    await f.api.set(.unknownError)
    await #expect(throws: GatewayAvatarFailure.unavailable) { try await f.load() }
    #expect(f.client.image(for: old) == nil)
}
