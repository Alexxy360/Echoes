import Foundation
import Observation
import Testing

@testable import EchoesCloudKit

actor OwnerPreviewHostAPI: GatewayAvatarOwnerPreviewAPI {
    nonisolated let origin: String
    let fixture: OwnerPreviewWireFixture
    let clock: OwnerPreviewClock
    let gate = PhotoGate()
    private var calls = 0
    private var wrongSelection = false
    private var fail = false
    private var denied = false
    private var ageAtReturn = 0
    init(
        fixture: OwnerPreviewWireFixture, clock: OwnerPreviewClock,
        origin: String = ownerPreviewOrigin.absoluteString
    ) {
        self.fixture = fixture
        self.clock = clock
        self.origin = origin
    }
    func set(wrongSelection: Bool = false, fail: Bool = false, denied: Bool = false) {
        self.wrongSelection = wrongSelection
        self.fail = fail
        self.denied = denied
    }
    func count() -> Int { calls }
    func ageBeforeReturn(_ value: Int) { ageAtReturn = value }
    func preview(_ query: GatewayAvatarOwnerPreviewQuery, token: GatewaySecret) async throws
        -> GatewayAvatarOwnerPreview
    {
        calls += 1
        let wrongSelection = wrongSelection
        let fail = fail
        let denied = denied
        await gate.enter()
        if denied { throw GatewayFailure.signInRequired }
        if fail { throw NSError(domain: "PRIVATE-PROVIDER-DETAILS", code: 9) }
        let selected =
            wrongSelection
            ? try GatewayAvatarOwnerPreviewQuery(
                ownerID: query.ownerID,
                selection: .init(
                    requestID: query.selection.requestID, versionID: query.selection.versionID,
                    generation: query.selection.generation, reviewRevision: UUID().uuidString.lowercased()))
            : query
        var response = try reviewHeader(
            fixture.image, "x-echoes-avatar-selection",
            [
                "requestID": selected.selection.requestID, "versionID": selected.selection.versionID,
                "generation": selected.selection.generation,
                "reviewRevision": selected.selection.reviewRevision,
            ])
        response = try reviewHeader(
            response, "x-echoes-avatar-manifest",
            ["ownerID": selected.ownerID, "versionID": selected.selection.versionID])
        let result = try await GatewayAvatarOwnerPreviewHTTPClient(
            configuration: .init(origin: URL(string: origin)!),
            transport: OwnerPreviewHTTPStub(response), isEnabled: { true }, date: { [clock] in clock.date() },
            uptime: { [clock] in clock.up() }
        ).preview(selected, token: token)
        clock.move(wall: ageAtReturn, monotonic: Double(ageAtReturn) / 1000)
        return result
    }
}
@MainActor @Observable final class OwnerPreviewHostFlags {
    var enabled = true
    var parent = true
}
@MainActor struct OwnerPreviewHostFixture {
    let wire: OwnerPreviewWireFixture
    let clock: OwnerPreviewClock
    let flags = OwnerPreviewHostFlags()
    let authorization: PhotoAuthorization
    let cloudKit: CloudKitConfiguration
    let api: OwnerPreviewHostAPI
    let host: GatewayAvatarOwnerPreviewHost
    init() throws {
        wire = try .init()
        clock = OwnerPreviewClock(wire.now)
        authorization = try .init()
        try authorization.select(wire.query.ownerID)
        cloudKit = try .init(containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
        api = OwnerPreviewHostAPI(fixture: wire, clock: clock)
        host = try .init(
            api: api, configuration: .init(origin: ownerPreviewOrigin), cloudKit: cloudKit,
            authorization: authorization,
            isEnabled: { [flags] in flags.enabled }, date: { [clock] in clock.date() },
            uptime: { [clock] in clock.up() })
        host.setForeground(true)
    }
    func open() throws { try host.open { flags.parent } }
    func show(acknowledge: Bool = true) async throws -> GatewayAvatarOwnerPreviewPresentation {
        if !host.isConnected { try open() }
        try await host.load(wire.query.selection)
        let handle = try #require(host.presentation)
        #expect(host.image(for: handle) != nil)
        if acknowledge { try host.acknowledgeDisplay(handle) }
        return handle
    }
}

@Test @MainActor func ownerPreviewHostRequiresCurrentDisplayAndConsumesExactConfirmationOnce() async throws {
    let f = try OwnerPreviewHostFixture()
    let handle = try await f.show(acknowledge: false)
    #expect(!f.host.canConfirm(handle))
    await #expect(throws: GatewayAvatarOwnerPreviewHostFailure.displayRequired) {
        try await f.host.confirmSelection(handle)
    }
    try f.host.acknowledgeDisplay(handle)
    #expect(f.host.canConfirm(handle))
    #expect(try await f.host.confirmSelection(handle) == f.wire.query.selection)
    #expect(f.host.presentation == nil && f.host.image(for: handle) == nil && !f.host.canConfirm(handle))
    #expect(await f.api.count() == 1 && f.authorization.tokenCalls == 2)
    await #expect(throws: GatewayAvatarOwnerPreviewHostFailure.displayRequired) {
        try await f.host.confirmSelection(handle)
    }
}

@Test @MainActor func ownerPreviewHostNewImageRequiresItsOwnDisplayAckAndRejectsOldHandle() async throws {
    let f = try OwnerPreviewHostFixture()
    let old = try await f.show()
    try await f.host.load(f.wire.query.selection)
    let fresh = try #require(f.host.presentation)
    #expect(fresh != old && f.host.image(for: old) == nil && !f.host.canConfirm(fresh))
    #expect(throws: GatewayAvatarOwnerPreviewHostFailure.displayRequired) {
        try f.host.acknowledgeDisplay(old)
    }
    try f.host.acknowledgeDisplay(fresh)
    #expect(f.host.canConfirm(fresh))
}

@Test @MainActor func ownerPreviewHostEveryGetterChecksNativePrivateParentActivationAndScene() async throws {
    for change in 0..<5 {
        let f = try OwnerPreviewHostFixture()
        let handle = try await f.show()
        switch change {
        case 0: try f.authorization.select(UUID().uuidString.lowercased())
        case 1: f.authorization.cloudName = "changed-private-icloud"
        case 2: f.flags.parent = false
        case 3: f.flags.enabled = false
        default: f.host.setForeground(false)
        }
        #expect(
            !f.host.isConnected && f.host.presentation == nil && f.host.image(for: handle) == nil
                && !f.host.canConfirm(handle))
        await #expect(throws: (any Error).self) { try await f.host.confirmSelection(handle) }
        f.host.invalidate()
    }
}

@Test @MainActor func ownerPreviewHostReopeningAndForegroundReturnNeverRestoreOldPixelsOrAck() async throws {
    let f = try OwnerPreviewHostFixture()
    let old = try await f.show()
    f.host.setForeground(false)
    f.host.setForeground(true)
    #expect(!f.host.isConnected && f.host.image(for: old) == nil)
    try f.open()
    #expect(f.host.presentation == nil && !f.host.canConfirm(old))
    let fresh = try await f.show(acknowledge: false)
    #expect(fresh != old && !f.host.canConfirm(fresh))
}

@Test @MainActor func ownerPreviewHostExpiryAndBothClockRollbacksDenyAllOldHandles() async throws {
    for (wall, monotonic) in [(30_000, 0.0), (0, 30.0), (-1, 0.0), (0, -0.01)] {
        let f = try OwnerPreviewHostFixture()
        let handle = try await f.show()
        let revision = f.host.presentationRevision
        f.clock.move(wall: wall, monotonic: monotonic)
        #expect(f.host.presentation == nil && f.host.image(for: handle) == nil && !f.host.canConfirm(handle))
        f.host.expirePresentation()
        #expect(f.host.presentationRevision != revision)
        await #expect(throws: GatewayAvatarOwnerPreviewHostFailure.displayRequired) {
            try await f.host.confirmSelection(handle)
        }
    }
}

@Test @MainActor func ownerPreviewHostRetainsOneSlotAcrossIgnoredProviderAndNewParentUntilActualReturn()
    async throws
{
    let f = try OwnerPreviewHostFixture()
    try f.open()
    await f.api.gate.arm()
    let pending = Task { try await f.host.load(f.wire.query.selection) }
    try await f.api.gate.wait()
    f.host.setForeground(false)
    f.host.setForeground(true)
    try f.open()
    #expect(f.host.isBusy && f.host.presentation == nil)
    await #expect(throws: GatewayAvatarFailure.busy) { try await f.host.load(f.wire.query.selection) }
    await f.api.gate.release()
    await #expect(throws: (any Error).self) { try await pending.value }
    #expect(!f.host.isBusy && f.host.presentation == nil)
    _ = try await f.show()
    #expect(await f.api.count() == 2)
}

@Test @MainActor func ownerPreviewHostPrivateScopeChangeDuringTokenOrProviderNeverRestoresImage() async throws
{
    for boundary in 0..<2 {
        let f = try OwnerPreviewHostFixture()
        try f.open()
        let gate = boundary == 0 ? f.authorization.gate : f.api.gate
        await gate.arm()
        let pending = Task { try await f.host.load(f.wire.query.selection) }
        try await gate.wait()
        f.authorization.cloudName = "changed-private-without-native-auth-change"
        await gate.release()
        await #expect(throws: GatewayAvatarOwnerPreviewHostFailure.superseded) { try await pending.value }
        #expect(f.host.presentation == nil && !f.host.isConnected)
        if boundary == 0 { #expect(await f.api.count() == 0) }
        f.host.invalidate()
    }
}

@Test @MainActor func ownerPreviewHostRejectsSubstitutedSelectionAndRedactsUnknownFailure() async throws {
    let f = try OwnerPreviewHostFixture()
    try f.open()
    await f.api.set(wrongSelection: true)
    await #expect(throws: GatewayAvatarFailure.superseded) { try await f.host.load(f.wire.query.selection) }
    #expect(f.host.presentation == nil)
    await f.api.set(fail: true)
    await #expect(throws: GatewayAvatarFailure.unavailable) { try await f.host.load(f.wire.query.selection) }
    #expect(f.host.presentation == nil)
    await f.api.set()
    let handle = try await f.show()
    #expect(
        !String(reflecting: handle).contains(f.wire.query.ownerID)
            && Mirror(reflecting: handle).children.isEmpty)
}

@Test @MainActor func ownerPreviewHostConfirmationWaitKeepsSlotAndExpiresBeforeReturningIntent() async throws
{
    let f = try OwnerPreviewHostFixture()
    let handle = try await f.show()
    await f.authorization.gate.arm()
    let confirming = Task { try await f.host.confirmSelection(handle) }
    try await f.authorization.gate.wait()
    #expect(f.host.isBusy && f.host.presentation == nil && f.host.image(for: handle) == nil)
    await #expect(throws: GatewayAvatarFailure.busy) { try await f.host.load(f.wire.query.selection) }
    f.clock.move(wall: 30_000, monotonic: 30)
    await f.authorization.gate.release()
    await #expect(throws: GatewayAvatarFailure.superseded) { try await confirming.value }
    #expect(!f.host.isBusy && f.host.presentation == nil)
}

@Test @MainActor func ownerPreviewHostConfirmationInvalidatedDuringCredentialsCannotReturnSelection()
    async throws
{
    let f = try OwnerPreviewHostFixture()
    let handle = try await f.show()
    await f.authorization.gate.arm()
    let confirming = Task { try await f.host.confirmSelection(handle) }
    try await f.authorization.gate.wait()
    f.host.invalidate()
    await f.authorization.gate.release()
    await #expect(throws: GatewayAvatarOwnerPreviewHostFailure.superseded) { try await confirming.value }
    #expect(f.host.presentation == nil)
}

@Test @MainActor func ownerPreviewHostExpiryNotifiesObservationWithoutRefreshOrGetterPolling() async throws {
    let f = try OwnerPreviewHostFixture()
    await f.api.ageBeforeReturn(29_000)
    let handle = try await f.show()
    let revision = f.host.presentationRevision
    f.clock.move(wall: 1001, monotonic: 1.001)
    for _ in 0..<600 where f.host.presentationRevision == revision {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(f.host.presentationRevision != revision)
    #expect(f.host.image(for: handle) == nil && !f.host.canConfirm(handle))
    #expect(await f.api.count() == 1)
}

@Test @MainActor func ownerPreviewHostInvalidSessionRejectsOnlyTheStillCurrentNativeBinding() async throws {
    for late in [false, true] {
        let f = try OwnerPreviewHostFixture()
        try f.open()
        await f.api.set(denied: true)
        await f.api.gate.arm()
        let pending = Task { try await f.host.load(f.wire.query.selection) }
        try await f.api.gate.wait()
        let other = UUID().uuidString.lowercased()
        if late { try f.authorization.select(other) }
        await f.api.gate.release()
        await #expect(throws: GatewayFailure.signInRequired) { try await pending.value }
        #expect(f.host.presentation == nil && !f.host.isConnected)
        #expect(f.authorization.rejected == (late ? 0 : 1))
        if late {
            #expect(f.authorization.communityAuthorization?.identity.accountID == other)
        } else {
            #expect(f.authorization.communityAuthorization == nil)
        }
        f.host.invalidate()
    }
}
