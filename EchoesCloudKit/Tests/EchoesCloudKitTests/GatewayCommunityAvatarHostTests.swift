import EchoesCore
import Foundation
import Observation
import Testing

@testable import EchoesCloudKit

@MainActor private final class HostCommunityClient: CommunityClient {
    var owner = "67000000-0000-4000-8000-000000000001"
    var people: [NearbyProfile] = []
    var page = MessagePage(messages: [], nextCursor: nil)
    var onBlock: (@MainActor () async throws -> Void)?
    func connect() async throws -> String { owner }
    func configuration() async throws -> URL? { nil }
    func visibilityGeneration() async throws -> Int { 0 }
    func publish(
        name: String, coordinate: Coordinate, measuredAt: Date, song: String, songID: String, generation: Int
    ) async throws {}
    func stopSharing() async throws -> Int { 0 }
    func nearby(coordinate: Coordinate) async throws -> [NearbyProfile] { people }
    func messages(coordinate: Coordinate, cursor: String?, knownIDs: [String]) async throws -> MessagePage {
        page
    }
    func send(text: String, name: String, coordinate: Coordinate, requestID: String) async throws
        -> ChatMessage
    { throw GatewayCommunityFailure.unavailable }
    func block(userID: String, blocked: Bool) async throws { try await onBlock?() }
    func blockedUsers() async throws -> [String] { [] }
    func report(messageID: String, reason: String) async throws {}
    func deleteOwnData() async throws { throw GatewayCommunityFailure.unavailable }
}
@MainActor private final class HostClock { var date = Date(timeIntervalSince1970: 1_794_603_600) }
@MainActor private struct HostFixture {
    let photo: PhotoFixture
    let data: HostCommunityClient
    let session: CommunitySession
    let host: GatewayCommunityAvatarHost
    let binding: GatewayCommunityAvatarBinding
    let clock = HostClock()
    let position = Coordinate(latitude: 51.1123456, longitude: 17.0345678)
    init() async throws {
        photo = try .init()
        data = HostCommunityClient()
        let clock = clock
        session = CommunitySession(client: data, now: { clock.date })
        host = try GatewayCommunityAvatarHost(
            api: photo.api, configuration: photo.config, cloudKit: photo.cloudKit,
            authorization: photo.source, cache: photo.cache, decoder: photo.decoder,
            isEnabled: { [state = photo.state] in state.enabled },
            uptime: { [state = photo.state] in state.time })
        binding = try host.bind(session: session, isCurrent: { true })
        data.people = [person(photo.reference)]
        await session.connect(name: "Maja")
        await session.setForeground(true)
        session.updateLocation(.init(coordinate: position, accuracy: 10, measuredAt: clock.date))
        await session.refreshUsers()
    }
    func person(
        _ reference: AvatarReference, version: String? = nil, name: String = "Maja", song: String = "",
        expiry: Double? = nil
    ) -> NearbyProfile {
        .init(
            id: reference.ownerID, name: name, coordinate: position, lastSong: song, appleMusicID: "",
            expiresAt: expiry ?? clock.date.timeIntervalSince1970 * 1000 + 600000,
            avatarVersionID: version ?? reference.versionID)
    }
    func message(_ reference: AvatarReference, id: String = "message-1", version: String? = nil)
        -> ChatMessage
    {
        .init(
            id: id, text: "Hej", senderName: "Maja", senderID: reference.ownerID,
            timestamp: clock.date.timeIntervalSince1970 * 1000,
            expiresAt: clock.date.timeIntervalSince1970 * 1000 + 7_200_000,
            avatarVersionID: version ?? reference.versionID)
    }
    func acquire(_ reference: AvatarReference? = nil, surface: GatewayCommunityAvatarSurface = .map) throws
        -> GatewayCommunityAvatarLease
    {
        try binding.acquire(reference: reference ?? photo.reference, surface: surface)
    }
    func close() {
        binding.invalidate()
        Task {
            await photo.api.gate.release()
            await photo.decoder.gate.release()
            await photo.source.gate.release()
            await photo.cache.activateGate.release()
        }
        photo.cleanup()
    }
}
@MainActor private func hostEventually(_ predicate: @MainActor () -> Bool) async throws {
    for _ in 0..<5000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayAvatarFailure.unavailable
}

private final class HostObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func read() -> Bool { lock.withLock { value } }
}

@Test @MainActor func avatarHostReadinessIsObservableBeforeRegistrationAndCannotReviveAnOldBinding()
    async throws
{
    let f = try await HostFixture()
    defer { f.close() }
    let cold = CommunitySession(client: f.data, now: { f.clock.date })
    let newer = try f.host.bind(session: cold, isCurrent: { true })
    defer { newer.invalidate() }
    #expect(!f.binding.isAvailable && !newer.isAvailable)
    #expect(throws: GatewayAvatarFailure.notFound) {
        try newer.acquire(reference: f.photo.reference, surface: .map)
    }
    await cold.connect(name: "Maja")
    await cold.setForeground(true)
    let ready = HostObservationFlag()
    withObservationTracking {
        #expect(!newer.isAvailable)
    } onChange: {
        ready.set()
    }
    cold.updateLocation(.init(coordinate: f.position, accuracy: 10, measuredAt: f.clock.date))
    #expect(ready.read() && newer.isAvailable && !f.binding.isAvailable)
    #expect(f.photo.source.tokenCalls == 0)
    await cold.refreshUsers()
    let lease = try newer.acquire(reference: f.photo.reference, surface: .map)
    try await hostEventually { newer.image(for: lease) != nil }
    let background = HostObservationFlag()
    withObservationTracking {
        #expect(newer.isAvailable)
    } onChange: {
        background.set()
    }
    await cold.setForeground(false)
    #expect(background.read() && !newer.isAvailable && newer.image(for: lease) == nil)
    await cold.setForeground(true)
    f.binding.invalidate()
    #expect(newer.isAvailable && !f.binding.isAvailable)
    let closed = HostObservationFlag()
    withObservationTracking {
        #expect(newer.isAvailable)
    } onChange: {
        closed.set()
    }
    newer.invalidate()
    #expect(closed.read() && !newer.isAvailable && !f.binding.isAvailable)
}

@Test @MainActor func avatarHostDefersAllIOUntilAViewRegistersAndCoalescesOnlyPendingFreshReads() async throws
{
    let f = try await HostFixture()
    defer { f.close() }
    await Task.yield()
    #expect(f.photo.source.tokenCalls == 0)
    let first = try f.acquire()
    let second = try f.acquire()
    try await hostEventually { f.binding.image(for: first) != nil && f.binding.image(for: second) != nil }
    #expect(await f.photo.api.captured().count == 1)
    let later = try f.acquire()
    #expect(f.binding.image(for: first) == nil)
    try await hostEventually { f.binding.image(for: later) != nil }
    #expect(f.binding.image(for: first) != nil && f.binding.image(for: second) != nil)
    #expect(await f.photo.api.captured().count == 2)
    #expect(await f.photo.api.captured().last?.query.knownSHA256 != nil)
    f.binding.release(first)
    #expect(f.binding.image(for: first) == nil && f.binding.image(for: second) != nil)
}

@Test @MainActor func avatarHostMetadataOnlyRefreshDoesNotRefetchOrRemoveCurrentPixels() async throws {
    let f = try await HostFixture()
    defer { f.close() }
    let lease = try f.acquire()
    try await hostEventually { f.binding.image(for: lease) != nil }
    f.data.people = [
        f.person(
            f.photo.reference, name: "Inne imię", song: "Nowy utwór",
            expiry: f.clock.date.timeIntervalSince1970 * 1000 + 601000)
    ]
    await f.session.refreshUsers()
    await Task.yield()
    #expect(f.binding.image(for: lease) != nil && !f.binding.isLoading(lease))
    #expect(await f.photo.api.captured().count == 1)
}

@Test @MainActor func avatarHostMapClearWinsOverOlderMessageMetadataAndCannotReuseOldPixelsAfterABA()
    async throws
{
    let f = try await HostFixture()
    defer { f.close() }
    f.session.isChatOpen = true
    f.data.page = .init(messages: [f.message(f.photo.reference)], nextCursor: nil)
    await f.session.refreshMessages()
    let lease = try f.acquire(surface: .message("message-1"))
    try await hostEventually { f.binding.image(for: lease) != nil }
    let old = f.data.people[0]
    f.data.people = [
        .init(
            id: old.id, name: old.name, coordinate: old.coordinate, lastSong: "", appleMusicID: "",
            expiresAt: old.expiresAt, avatarVersionID: nil)
    ]
    await f.session.refreshUsers()
    #expect(f.binding.image(for: lease) == nil)
    #expect(throws: GatewayAvatarFailure.notFound) { try f.acquire(surface: .message("message-1")) }
    await f.photo.api.gate.arm()
    f.data.people = [old]
    await f.session.refreshUsers()
    try await f.photo.api.gate.wait()
    #expect(f.binding.image(for: lease) == nil)
    await f.photo.api.gate.release()
    try await hostEventually { f.binding.image(for: lease) != nil }
    #expect(await f.photo.api.captured().count == 2)
}

@Test @MainActor func avatarHostBlocksPixelsBeforeBlockRPCAcknowledgementAndReauthorizesAfterFailure()
    async throws
{
    let f = try await HostFixture()
    defer { f.close() }
    let lease = try f.acquire()
    try await hostEventually { f.binding.image(for: lease) != nil }
    let blockGate = PhotoGate()
    await blockGate.arm()
    defer { Task { await blockGate.release() } }
    f.data.onBlock = {
        await blockGate.enter()
        throw GatewayCommunityFailure.unavailable
    }
    let blocking = Task { await f.session.block(userID: f.photo.reference.ownerID) }
    try await blockGate.wait()
    #expect(f.session.blockingUserIDs.contains(f.photo.reference.ownerID))
    #expect(f.binding.image(for: lease) == nil)
    await f.photo.api.gate.arm()
    await blockGate.release()
    await blocking.value
    try await f.photo.api.gate.wait()
    #expect(f.binding.image(for: lease) == nil)
    await f.photo.api.gate.release()
    try await hostEventually { f.binding.image(for: lease) != nil }
    #expect(await f.photo.api.captured().count == 2)
}

@Test @MainActor func avatarHostBackgroundForegroundFencesLateReadsAndRequiresFreshAuthorization()
    async throws
{
    let f = try await HostFixture()
    defer { f.close() }
    await f.photo.api.gate.arm()
    let lease = try f.acquire()
    try await f.photo.api.gate.wait()
    await f.session.setForeground(false)
    #expect(f.binding.image(for: lease) == nil)
    await f.session.setForeground(true)
    try await hostEventually { f.binding.image(for: lease) != nil }
    let count = await f.photo.api.captured().count
    #expect(count == 2)
    await f.photo.api.gate.release()
    await Task.yield()
    #expect(f.binding.image(for: lease) != nil)
}

@Test @MainActor func avatarHostRebindingKeepsFourUnsettledSlotsAndOldBindingsCannotClearNewAccount()
    async throws
{
    let f = try await HostFixture()
    defer { f.close() }
    let references = try (0..<4).map { _ in
        try AvatarReference(ownerID: UUID().uuidString.lowercased(), versionID: f.photo.reference.versionID)
    }
    f.data.people = references.map { f.person($0) }
    await f.session.refreshUsers()
    await f.photo.api.gate.arm(4)
    let old = try references.map { try f.acquire($0) }
    try await f.photo.api.gate.wait(4)
    try f.photo.source.select("67000000-0000-4000-8000-000000000002")
    let data = HostCommunityClient()
    data.owner = "67000000-0000-4000-8000-000000000002"
    data.people = [f.person(f.photo.reference)]
    let session = CommunitySession(client: data, now: { f.clock.date })
    let newer = try f.host.bind(session: session, isCurrent: { true })
    defer { newer.invalidate() }
    await session.connect(name: "Nowe konto")
    await session.setForeground(true)
    session.updateLocation(.init(coordinate: f.position, accuracy: 10, measuredAt: f.clock.date))
    await session.refreshUsers()
    let fresh = try newer.acquire(reference: f.photo.reference, surface: .map)
    for _ in 0..<20 { await Task.yield() }
    #expect(await f.photo.api.captured().count == 4)
    f.binding.invalidate()
    for lease in old {
        f.binding.release(lease)
        #expect(f.binding.image(for: lease) == nil)
    }
    await f.photo.api.gate.release()
    try await hostEventually { newer.image(for: fresh) != nil }
    #expect(await f.photo.api.captured().count == 5)
    #expect(await f.photo.api.captured().last?.token.value.hasPrefix(data.owner + ".") == true)
    f.binding.invalidate()
    #expect(newer.image(for: fresh) != nil)
}

@Test @MainActor func avatarHostReleasingThumbnailKeepsSeparatelyPresentedFullImage() async throws {
    let f = try await HostFixture()
    defer { f.close() }
    let small = try f.acquire()
    let full = try f.acquire(surface: .profile)
    try await hostEventually { f.binding.image(for: small) != nil && f.binding.image(for: full) != nil }
    f.binding.release(small)
    #expect(f.binding.image(for: small) == nil && f.binding.image(for: full) != nil)
    f.binding.release(full)
    #expect(f.binding.image(for: full) == nil)
}

@Test @MainActor func avatarHostCapsReadAdmissionAndRetryDoesNotCreateAnAutomaticLoop() async throws {
    let f = try await HostFixture()
    defer { f.close() }
    for _ in 0..<12 {
        let lease = try f.acquire()
        try await hostEventually { f.binding.image(for: lease) != nil }
        f.binding.release(lease)
    }
    let denied = try f.acquire()
    for _ in 0..<10 { await Task.yield() }
    #expect(f.binding.image(for: denied) == nil && !f.binding.isLoading(denied))
    #expect(await f.photo.api.captured().count == 12)
    f.binding.retry(denied)
    #expect(await f.photo.api.captured().count == 12)
    f.photo.state.time += 61
    f.binding.retry(denied)
    try await hostEventually { f.binding.image(for: denied) != nil }
    #expect(await f.photo.api.captured().count == 13)
}

@Test @MainActor func avatarHostHasSeparateFullImageCeilingAndBoundedConsumerRegistrations() async throws {
    let f = try await HostFixture()
    defer { f.close() }
    for _ in 0..<4 {
        let lease = try f.acquire(surface: .profile)
        try await hostEventually { f.binding.image(for: lease) != nil }
        f.binding.release(lease)
    }
    let denied = try f.acquire(surface: .profile)
    await Task.yield()
    #expect(f.binding.image(for: denied) == nil)
    #expect(await f.photo.api.captured().count == 4)
    f.binding.release(denied)
    let leases = try (0..<320).map { _ in try f.acquire() }
    #expect(throws: GatewayAvatarFailure.limited(retryAfterSeconds: nil)) { try f.acquire() }
    try await hostEventually { f.binding.image(for: leases[0]) != nil }
    #expect(await f.photo.api.captured().count == 5)
    for lease in leases { f.binding.release(lease) }
    #expect(f.binding.image(for: leases[0]) == nil)
}

@Test @MainActor func avatarHostChecksParentExpiryAndChatClosureWithoutRelyingOnANetworkRefresh() async throws
{
    let f = try await HostFixture()
    defer { f.close() }
    f.session.isChatOpen = true
    f.data.page = .init(messages: [f.message(f.photo.reference)], nextCursor: nil)
    await f.session.refreshMessages()
    let chat = try f.acquire(surface: .message("message-1"))
    try await hostEventually { f.binding.image(for: chat) != nil }
    f.session.isChatOpen = false
    #expect(f.binding.image(for: chat) == nil)
    #expect(throws: GatewayAvatarFailure.notFound) { try f.acquire(surface: .message("message-1")) }
    f.data.people = [f.person(f.photo.reference, expiry: f.clock.date.timeIntervalSince1970 * 1000 + 100)]
    await f.session.refreshUsers()
    let map = try f.acquire()
    try await hostEventually { f.binding.image(for: map) != nil }
    f.clock.date = f.clock.date.addingTimeInterval(0.2)
    #expect(f.binding.image(for: map) == nil)
}

@Test @MainActor func avatarHostConnectFailureStopsLoadingAndRequiresExplicitRetry() async throws {
    let f = try await HostFixture()
    defer { f.close() }
    f.photo.source.tokenError = true
    let lease = try f.acquire()
    try await hostEventually { !f.binding.isLoading(lease) }
    #expect(f.binding.image(for: lease) == nil && f.photo.source.tokenCalls == 1)
    #expect(await f.photo.api.captured().isEmpty)
    await f.session.refreshUsers()
    #expect(f.photo.source.tokenCalls == 1)
    f.photo.source.tokenError = false
    f.binding.retry(lease)
    try await hostEventually { f.binding.image(for: lease) != nil }
    #expect(await f.photo.api.captured().count == 1)
}
