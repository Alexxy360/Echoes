import EchoesCore
import Foundation
import Observation
import Testing

@testable import EchoesCloudKit

actor PhotoReportHostAPI: GatewayAvatarReportAPI {
    nonisolated let origin: String
    var outcome = GatewayAvatarReportOutcome.accepted
    var loseACK = false, signIn = false
    var calls: [String] = []
    var submissions: [GatewayAvatarReportSubmission] = []
    var identities: [GatewayAvatarReportIdentity] = []
    let gate = PhotoGate()
    init(origin: String = "https://photo-client.example.invalid") { self.origin = origin }
    func set(_ outcome: GatewayAvatarReportOutcome, loseACK: Bool = false, signIn: Bool = false) {
        self.outcome = outcome
        self.loseACK = loseACK
        self.signIn = signIn
    }
    private func result(_ identity: GatewayAvatarReportIdentity, action: String) async throws
        -> GatewayAvatarReportResult
    {
        calls.append(action)
        identities.append(identity)
        let result = GatewayAvatarReportResult(identity: identity, outcome: outcome)
        let lost = loseACK
        let denied = signIn
        await gate.enter()
        if denied { throw GatewayFailure.signInRequired }
        if lost { throw GatewayAvatarReportFailure.unavailable }
        return result
    }
    func submit(_ submission: GatewayAvatarReportSubmission, token: GatewaySecret) async throws
        -> GatewayAvatarReportResult
    {
        submissions.append(submission)
        return try await result(submission.identity, action: "submit")
    }
    func recover(_ identity: GatewayAvatarReportIdentity, token: GatewaySecret) async throws
        -> GatewayAvatarReportResult
    {
        try await result(identity, action: "recover")
    }
    func cancel(_ identity: GatewayAvatarReportIdentity, token: GatewaySecret) async throws
        -> GatewayAvatarReportResult
    {
        try await result(identity, action: "cancel")
    }
}
@MainActor @Observable final class PhotoReportHostState {
    var enabled = true
    var parent = true
    var cancellation = true
}
@MainActor struct PhotoReportHostFixture {
    let avatar: CommunityAvatarHostFixture
    let api = PhotoReportHostAPI()
    let storage = PhotoReportJournalMemoryStorage()
    let journal: GatewayAvatarReportJournal
    let state = PhotoReportHostState()
    let host: GatewayAvatarReportHost
    init() async throws {
        avatar = try await CommunityAvatarHostFixture()
        journal = GatewayAvatarReportJournal(storage: storage)
        let avatar = avatar
        let state = state
        host = try .init(
            api: api, configuration: avatar.photo.config, cloudKit: avatar.photo.cloudKit,
            authorization: avatar.photo.source, journal: journal, isEnabled: { state.enabled },
            canCancel: { state.cancellation },
            date: { avatar.clock.date }, uptime: { avatar.photo.state.time })
    }
    func connect() async throws {
        host.setForeground(true)
        try await host.connect(isCurrent: { [state] in state.parent })
    }
    func show(acknowledge: Bool = true) async throws -> (
        GatewayCommunityAvatarLease, GatewayAvatarReportPhoto, GatewayAvatarReportPresentation
    ) {
        try await connect()
        let lease = try avatar.acquire(surface: .profile)
        try await communityAvatarEventually { avatar.binding.image(for: lease) != nil }
        let photo = try avatar.binding.reportPhoto(for: lease)
        try host.present(photo)
        let handle = try #require(host.presentation)
        _ = try #require(host.image(for: handle))
        if acknowledge { try host.acknowledgeDisplay(handle) }
        return (lease, photo, handle)
    }
    func close() {
        host.invalidate()
        storage.readGate.release()
        storage.gate.release()
        avatar.close()
        Task { await api.gate.release() }
    }
}

@Test @MainActor func avatarReportHostRequiresProtectedFullPhotoAndActualDisplayBeforeConsentDispatch()
    async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let map = try f.avatar.acquire()
    #expect(throws: GatewayAvatarReportHostFailure.displayRequired) {
        try f.avatar.binding.reportPhoto(for: map)
    }
    let (_, photo, _) = try await f.show(acknowledge: false)
    try f.host.present(photo)
    let shown = try #require(f.host.presentation)
    #expect(throws: GatewayAvatarReportHostFailure.displayRequired) { try f.host.acknowledgeDisplay(shown) }
    _ = try #require(f.host.image(for: shown))
    #expect(!f.host.canSubmit)
    await #expect(throws: GatewayAvatarReportHostFailure.displayRequired) {
        try await f.host.submit(reason: "reason", presentation: shown)
    }
    #expect(await f.api.calls.isEmpty && f.host.pendingOperation == nil)
    try f.host.acknowledgeDisplay(shown)
    #expect(f.host.canSubmit)
    await #expect(throws: GatewayAvatarReportFailure.invalidInput) {
        try await f.host.submit(reason: "  ", presentation: shown)
    }
    #expect(f.host.canSubmit && f.host.pendingOperation == nil)
    #expect(await f.api.calls.isEmpty)
}
@Test @MainActor func avatarReportHostSubmitsExactShownVersionCurrentCoordinateAndPersistsBeforeAPI()
    async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, _, shown) = try await f.show()
    let position = Coordinate(latitude: 51.1123, longitude: 17.0345)
    f.avatar.session.updateLocation(.init(coordinate: position, accuracy: 8, measuredAt: f.avatar.clock.date))
    await f.api.gate.arm()
    let work = Task { try await f.host.submit(reason: "  Powód  ", presentation: shown) }
    try await f.api.gate.wait()
    let submissions = await f.api.submissions
    #expect(submissions.count == 1 && submissions[0].reference == f.avatar.photo.reference)
    #expect(submissions[0].coordinate == position && submissions[0].reason == "Powód")
    let scope = try GatewayAvatarReportScope(
        configuration: f.avatar.photo.config,
        owner: #require(f.avatar.photo.source.privateDataScope(configuration: f.avatar.photo.cloudKit)),
        binding: #require(f.avatar.photo.source.communityAuthorization).identity.binding)
    let pending = try #require(try await f.journal.peek(scope: scope))
    #expect(pending.phase == .dispatched && pending.intent == submissions[0].identity)
    #expect(f.host.isBusy && f.host.image(for: shown) == nil)
    await f.api.gate.release()
    try await work.value
    #expect(f.host.outcome == .accepted && f.host.pendingOperation?.phase == .resolved)
    let result = try #require(f.host.resolution)
    try await f.host.acknowledgeResult(result)
    #expect(f.host.pendingOperation == nil && f.host.presentation == nil)
}
@Test @MainActor func avatarReportHostLostACKReopensOnlyOriginalMetadataAndNeverRepeatsSubmission()
    async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, _, shown) = try await f.show()
    await f.api.set(.accepted, loseACK: true)
    await #expect(throws: GatewayAvatarReportFailure.unavailable) {
        try await f.host.submit(reason: "PRIVATE", presentation: shown)
    }
    #expect(!f.host.isConnected)
    try await f.connect()
    let pending = try #require(f.host.pendingOperation)
    #expect(pending.phase == .dispatched && f.host.presentation == nil && !f.host.canSubmit)
    await f.api.set(.accepted)
    try await f.host.recover()
    #expect(f.host.outcome == .accepted)
    #expect(await f.api.calls == ["submit", "recover"])
    #expect(await f.api.identities == [pending.intent, pending.intent])
}
@Test @MainActor func avatarReportHostUnknownResultCannotAckOrReplaceUntilExplicitCancellationConfirmsFence()
    async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, photo, shown) = try await f.show()
    await f.api.set(.accepted, loseACK: true)
    await #expect(throws: GatewayAvatarReportFailure.unavailable) {
        try await f.host.submit(reason: "PRIVATE", presentation: shown)
    }
    try await f.connect()
    let identity = try #require(f.host.pendingOperation?.intent)
    await f.api.set(.unconfirmed)
    try await f.host.recover()
    #expect(f.host.outcome == .unconfirmed && f.host.resolution == nil && f.host.canCancelPending)
    #expect(throws: GatewayAvatarReportJournalFailure.pendingExists) { try f.host.present(photo) }
    await f.api.set(.cancelled)
    try await f.host.cancelPending()
    #expect(f.host.outcome == .cancelled && f.host.pendingOperation?.phase == .resolved)
    try await f.host.acknowledgeResult(#require(f.host.resolution))
    #expect(f.host.pendingOperation == nil)
    #expect(await f.api.identities.allSatisfy { $0 == identity })
}
@Test @MainActor func avatarReportHostLostCancelACKKeepsCancellingThroughAcceptedAndUnknownRecovery()
    async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, _, shown) = try await f.show()
    await f.api.set(.accepted, loseACK: true)
    await #expect(throws: GatewayAvatarReportFailure.unavailable) {
        try await f.host.submit(reason: "PRIVATE", presentation: shown)
    }
    try await f.connect()
    let identity = try #require(f.host.pendingOperation?.intent)
    await f.api.set(.cancelled, loseACK: true)
    await #expect(throws: GatewayAvatarReportFailure.unavailable) { try await f.host.cancelPending() }
    try await f.connect()
    #expect(f.host.pendingOperation?.phase == .cancelling)
    f.state.cancellation = false
    for outcome in [GatewayAvatarReportOutcome.accepted, .unconfirmed] {
        await f.api.set(outcome)
        try await f.host.recover()
        #expect(f.host.pendingOperation?.phase == .cancelling && f.host.resolution == nil)
    }
    await #expect(throws: GatewayAvatarReportFailure.unavailable) { try await f.host.cancelPending() }
    f.state.cancellation = true
    await f.api.set(.cancelled)
    try await f.host.cancelPending()
    #expect(f.host.pendingOperation?.phase == .resolved && f.host.outcome == .cancelled)
    #expect(await f.api.identities.allSatisfy { $0 == identity })
}
@Test @MainActor func avatarReportHostBackgroundRetainsBusyUntilActualLateAPICompletesAndPreservesRecovery()
    async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, _, shown) = try await f.show()
    await f.api.gate.arm()
    let work = Task { try await f.host.submit(reason: "PRIVATE", presentation: shown) }
    try await f.api.gate.wait()
    f.host.setForeground(false)
    #expect(f.host.isBusy && !f.host.isConnected && f.host.image(for: shown) == nil)
    await #expect(throws: GatewayAvatarReportFailure.busy) { try await f.connect() }
    await f.api.gate.release()
    _ = await work.result
    #expect(!f.host.isBusy)
    try await f.connect()
    #expect(f.host.pendingOperation?.phase == .dispatched)
    try await f.host.recover()
    #expect(f.host.outcome == .accepted)
    #expect(await f.api.calls == ["submit", "recover"])
}
@Test @MainActor
func avatarReportHostParentFenceDuringDurablePrepareWithholdsMutationAndKeepsOwnPendingMetadata() async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, _, shown) = try await f.show()
    f.storage.gate.arm()
    let work = Task { try await f.host.submit(reason: "PRIVATE", presentation: shown) }
    try await communityAvatarEventually { f.storage.gate.hasEntered() }
    f.state.parent = false
    f.storage.gate.release()
    _ = await work.result
    #expect((await f.api.calls).isEmpty && !f.host.isConnected)
    f.state.parent = true
    try await f.connect()
    #expect(f.host.pendingOperation?.phase == .prepared)
}
@Test @MainActor func avatarReportHostTokenNativeChangeBeforeDispatchNeverBorrowedByNewAccount() async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, _, shown) = try await f.show()
    await f.avatar.photo.source.gate.arm()
    let work = Task { try await f.host.submit(reason: "PRIVATE", presentation: shown) }
    try await f.avatar.photo.source.gate.wait()
    try f.avatar.photo.source.select("67000000-0000-4000-8000-000000000002")
    await f.avatar.photo.source.gate.release()
    _ = await work.result
    #expect((await f.api.calls).isEmpty && !f.host.isConnected && f.host.pendingOperation == nil)
}
@Test @MainActor func avatarReportHostOriginalPhotoClaimCannotBorrowRefreshedOrReleasedPixels() async throws {
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (lease, photo, shown) = try await f.show()
    f.avatar.binding.retry(lease)
    #expect(f.host.image(for: shown) == nil && !f.host.canSubmit)
    try await communityAvatarEventually { f.avatar.binding.image(for: lease) != nil }
    #expect(throws: GatewayAvatarReportHostFailure.displayRequired) { try f.host.present(photo) }
    let fresh = try f.avatar.binding.reportPhoto(for: lease)
    try f.host.present(fresh)
    let handle = try #require(f.host.presentation)
    f.avatar.binding.release(lease)
    #expect(f.host.image(for: handle) == nil)
    #expect(throws: GatewayAvatarReportHostFailure.displayRequired) { try f.host.acknowledgeDisplay(handle) }
}
@Test @MainActor func avatarReportHostExpiryRollbackParentAndObservedNativeFenceNeverReviveConsent()
    async throws
{
    for mode in [
        "expiry", "wall-rollback", "uptime-rollback", "parent", "native", "private", "activation",
        "wall-partial-rollback", "uptime-partial-rollback",
    ] {
        let f = try await PhotoReportHostFixture()
        defer { f.close() }
        let (_, _, shown) = try await f.show()
        let wall = f.avatar.clock.date
        let tick = f.avatar.photo.state.time
        let native = f.avatar.photo.source.communityAuthorization
        let cloud = f.avatar.photo.source.cloudName
        switch mode {
        case "expiry": f.avatar.clock.date += 30
        case "wall-partial-rollback":
            f.avatar.clock.date += 10
            _ = f.host.image(for: shown)
            f.avatar.clock.date -= 5
        case "uptime-partial-rollback":
            f.avatar.photo.state.time += 10
            _ = f.host.image(for: shown)
            f.avatar.photo.state.time -= 5
        case "wall-rollback": f.avatar.clock.date -= 1
        case "uptime-rollback": f.avatar.photo.state.time -= 1
        case "parent": f.state.parent = false
        case "native": try f.avatar.photo.source.select("67000000-0000-4000-8000-000000000002")
        case "private": f.avatar.photo.source.cloudName = "other-private-owner"
        default: f.state.enabled = false
        }
        #expect(f.host.image(for: shown) == nil && !f.host.canSubmit)
        f.avatar.clock.date = wall
        f.avatar.photo.state.time = tick
        f.state.parent = true
        f.avatar.photo.source.communityAuthorization = native
        f.avatar.photo.source.cloudName = cloud
        f.state.enabled = true
        #expect(f.host.image(for: shown) == nil && !f.host.canSubmit)
        #expect((await f.api.calls).isEmpty)
    }
}
@Test @MainActor func avatarReportHostConfirmedPendingReopensAsExactResultWithoutNetworkReplay() async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, _, shown) = try await f.show()
    try await f.host.submit(reason: "PRIVATE", presentation: shown)
    let old = try #require(f.host.resolution)
    try await f.connect()
    let fresh = try #require(f.host.resolution)
    #expect(old != fresh && f.host.outcome == .accepted)
    await #expect(throws: GatewayAvatarReportJournalFailure.invalidTransition) {
        try await f.host.acknowledgeResult(old)
    }
    try await f.host.acknowledgeResult(fresh)
    #expect((await f.api.calls) == ["submit"] && f.host.pendingOperation == nil)
}
@Test @MainActor func avatarReportHostRejectsForgedActionOutcomeAndCancelFlagRevokedAfterIO() async throws {
    for mode in ["accepted-cancel", "flag"] {
        let f = try await PhotoReportHostFixture()
        defer { f.close() }
        let (_, _, shown) = try await f.show()
        await f.api.set(.accepted, loseACK: true)
        await #expect(throws: GatewayAvatarReportFailure.unavailable) {
            try await f.host.submit(reason: "PRIVATE", presentation: shown)
        }
        try await f.connect()
        await f.api.set(mode == "flag" ? .cancelled : .accepted)
        await f.api.gate.arm()
        let work = Task { try await f.host.cancelPending() }
        try await f.api.gate.wait()
        if mode == "flag" { f.state.cancellation = false }
        await f.api.gate.release()
        let result = await work.result
        #expect(throws: (any Error).self) { try result.get() }
        try await f.connect()
        #expect(f.host.pendingOperation?.phase == .cancelling && f.host.resolution == nil)
    }
}
@Test @MainActor func avatarReportHostSignInFailureRevokesOnlyCapturedSessionWithoutErasingPending()
    async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, _, shown) = try await f.show()
    await f.api.set(.accepted, signIn: true)
    await #expect(throws: GatewayFailure.signInRequired) {
        try await f.host.submit(reason: "PRIVATE", presentation: shown)
    }
    #expect(f.avatar.photo.source.rejected == 1 && f.avatar.photo.source.communityAuthorization == nil)
    try f.avatar.photo.source.select("67000000-0000-4000-8000-000000000001")
    try await f.connect()
    #expect(f.host.pendingOperation?.phase == .dispatched)
    let stored = f.storage.records.values.map { String(data: $0, encoding: .utf8) ?? "" }.joined()
    for value in ["PRIVATE", "reason", "coordinate", "versionID", "image", "Bearer"] {
        #expect(!stored.contains(value))
    }
}
@Test @MainActor func avatarReportHostConfigurationAndPhotoOriginArePinnedAndPublicDescriptionsRedacted()
    async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, photo, shown) = try await f.show()
    #expect(throws: GatewayFailure.configuration) {
        try GatewayAvatarReportHost(
            api: f.api, configuration: .init(origin: URL(string: "https://wrong.example.invalid")!),
            cloudKit: f.avatar.photo.cloudKit, authorization: f.avatar.photo.source, journal: f.journal)
    }
    for value in [String(describing: photo), String(reflecting: photo), String(describing: shown)] {
        #expect(
            !value.contains(f.avatar.photo.reference.ownerID)
                && !value.contains(f.avatar.photo.reference.versionID))
    }
    #expect(Mirror(reflecting: photo).children.isEmpty)
    let foreignAPI = PhotoReportHostAPI(origin: "https://foreign-photo.example.invalid")
    let foreign = try GatewayAvatarReportHost(
        api: foreignAPI,
        configuration: .init(origin: URL(string: foreignAPI.origin)!), cloudKit: f.avatar.photo.cloudKit,
        authorization: f.avatar.photo.source,
        journal: .init(storage: PhotoReportJournalMemoryStorage()), isEnabled: { true })
    foreign.setForeground(true)
    try await foreign.connect()
    defer { foreign.invalidate() }
    #expect(throws: GatewayAvatarReportHostFailure.displayRequired) { try foreign.present(photo) }
    #expect(await foreignAPI.calls.isEmpty)

}

@Test @MainActor func avatarReportHostRechecksExactPhotoAfterLastJournalReadBeforeDispatch() async throws {
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (lease, _, shown) = try await f.show()
    // First dispatched read is write-readback; second is the final journal.pending check.
    f.storage.pauseDispatchedRead(2)
    let work = Task { try await f.host.submit(reason: "PRIVATE", presentation: shown) }
    try await communityAvatarEventually { f.storage.readGate.hasEntered() }
    f.avatar.binding.release(lease)
    f.storage.readGate.release()
    _ = await work.result
    #expect(await f.api.calls.isEmpty)
    try await f.connect()
    #expect(f.host.pendingOperation?.phase == .dispatched)
}
@Test @MainActor func avatarReportHostDefaultsClosedBeforeTokenJournalAndNetworkIO() async throws {
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let host = try GatewayAvatarReportHost(
        api: f.api, configuration: f.avatar.photo.config,
        cloudKit: f.avatar.photo.cloudKit, authorization: f.avatar.photo.source, journal: f.journal)
    host.setForeground(true)
    let before = f.avatar.photo.source.tokenCalls
    let writes = f.storage.writes
    await #expect(throws: GatewayFailure.signInRequired) { try await host.connect() }
    #expect(f.avatar.photo.source.tokenCalls == before && f.storage.writes == writes)
    #expect(await f.api.calls.isEmpty)
}
