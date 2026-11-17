import Foundation
import Testing

@testable import EchoesCloudKit

actor ReviewHostAPI: GatewayAvatarReviewAPI {
    nonisolated let origin = "https://review-host.example.invalid"
    enum Mode: Sendable { case normal, denied, signIn, unknown, lostACK, beforeAccept, superseded }
    var mode: Mode = .normal
    var calls: [String] = []
    var decisions: [GatewayAvatarReviewDecisionIntent] = []
    var recoveries: [GatewayAvatarReviewRecoveryIntent] = []
    var applied: [String: String] = [:]
    let fixture: ReviewWireFixture
    let clock: ReviewClock
    let gate = PhotoGate()
    private var pauseAction = ""
    var beforeDecision: (@Sendable (GatewayAvatarReviewDecisionIntent) async throws -> Void)?
    init(fixture: ReviewWireFixture, clock: ReviewClock) {
        self.fixture = fixture
        self.clock = clock
    }
    func setMode(_ value: Mode) { mode = value }
    func pause(_ action: String) async {
        pauseAction = action
        await gate.arm()
    }
    func before(_ callback: @escaping @Sendable (GatewayAvatarReviewDecisionIntent) async throws -> Void) {
        beforeDecision = callback
    }
    private func begin(_ action: String) throws {
        calls.append(action)
        switch mode {
        case .denied: throw GatewayAvatarReviewFailure.denied
        case .signIn: throw GatewayFailure.signInRequired
        case .unknown: throw NSError(domain: "PRIVATE-TOKEN-URL-SENTINEL", code: 9)
        default: break
        }
    }
    private func hold(_ action: String) async {
        if pauseAction == action {
            pauseAction = ""
            await gate.enter()
        }
    }
    func queue(token: GatewaySecret) async throws -> [GatewayAvatarReviewItem] {
        try begin("queue")
        let value = try await reviewClient(
            ReviewHTTPStub(fixture.queue), clock: clock, origin: URL(string: origin)!
        ).queue(token: token)
        await hold("queue")
        return value
    }
    func inspect(_ item: GatewayAvatarReviewItem, token: GatewaySecret) async throws
        -> GatewayAvatarReviewInspection
    {
        try begin("inspect")
        let value = try await reviewClient(
            ReviewHTTPStub(fixture.image), clock: clock, origin: URL(string: origin)!
        ).inspect(item, token: token)
        await hold("inspect")
        return value
    }
    func decide(_ intent: GatewayAvatarReviewDecisionIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReviewDecisionResult
    {
        try begin("decide")
        decisions.append(intent)
        let callback = beforeDecision
        beforeDecision = nil
        try await callback?(intent)
        if mode == .beforeAccept { throw GatewayAvatarReviewFailure.unavailable }
        let revision = UUID().uuidString.lowercased()
        applied[intent.decisionID] = revision
        await hold("decide")
        if mode == .lostACK { throw GatewayAvatarReviewFailure.unavailable }
        return .init(intent: intent, revision: revision)
    }
    func recover(_ intent: GatewayAvatarReviewRecoveryIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReviewRecoveryResult
    {
        try begin("recover")
        recoveries.append(intent)
        let outcome: GatewayAvatarReviewOutcome =
            mode == .superseded
            ? .superseded
            : applied[intent.decisionID].map { .confirmed(revision: $0) } ?? .notApplied
        await hold("recover")
        return .init(intent: intent, outcome: outcome)
    }
}
@MainActor final class ReviewHostFlags {
    var enabled = true
    var parent = true
}
@MainActor struct ReviewHostFixture {
    let wire: ReviewWireFixture
    let clock: ReviewClock
    let flags = ReviewHostFlags()
    let authorization: PhotoAuthorization
    let storage: ReviewMemoryStorage
    let journal: GatewayAvatarReviewJournal
    let scope: GatewayAvatarReviewScope
    let api: ReviewHostAPI
    let host: GatewayAvatarReviewHost
    init(
        storage: ReviewMemoryStorage? = nil, api: ReviewHostAPI? = nil,
        willDecide: @escaping @MainActor (String) -> Void = { _ in }
    ) throws {
        wire = try .init()
        clock = ReviewClock(wire.now)
        authorization = try .init()
        try authorization.select(
            reviewModeratorA, apple: "synthetic-review-apple", cloud: "synthetic-review-cloud")
        self.storage = storage ?? ReviewMemoryStorage()
        journal = .init(storage: self.storage)
        scope = try reviewStoreScope()
        self.api = api ?? ReviewHostAPI(fixture: wire, clock: clock)
        host = try GatewayAvatarReviewHost(
            api: self.api,
            configuration: .init(origin: URL(string: self.api.origin)!), cloudKit: scope.owner.configuration,
            authorization: authorization, journal: journal, isEnabled: { [flags] in flags.enabled },
            date: { [clock] in clock.date() }, uptime: { [clock] in clock.up() }, willDecide: willDecide)
        host.setForeground(true)
    }
    func connect() async throws { try await host.connect { flags.parent } }
    func show(acknowledge: Bool = true) async throws -> GatewayAvatarReviewPresentation {
        if !host.isConnected { try await connect() }
        try await host.refreshQueue()
        try await host.inspect(wire.item)
        let shown = try #require(host.presentation)
        #expect(host.image(for: shown) != nil)
        if acknowledge { try host.acknowledgeDisplay(shown) }
        return shown
    }
}

@Test @MainActor func avatarReviewHostRequiresActualCurrentDisplayAndPersistsDispatchedIntentBeforeAPI()
    async throws
{
    let f = try ReviewHostFixture()
    let shown = try await f.show(acknowledge: false)
    #expect(!f.host.canDecide)
    await #expect(throws: GatewayAvatarReviewHostFailure.displayRequired) {
        try await f.host.decide(.approved, presentation: shown)
    }
    #expect(await f.api.decisions.isEmpty)
    try f.host.acknowledgeDisplay(shown)
    await f.api.before { intent in
        await MainActor.run {
            #expect(f.host.pendingOperation?.phase == .dispatched)
            #expect(f.host.pendingOperation?.intent == GatewayAvatarReviewRecoveryIntent(decision: intent))
            #expect(f.host.presentation == nil && f.host.image(for: shown) == nil)
        }
    }
    try await f.host.decide(.approved, presentation: shown)
    #expect(f.host.pendingOperation?.phase == .resolved && f.host.outcome != nil)
    #expect(await f.api.calls == ["queue", "inspect", "decide"])
    let result = try #require(f.host.resolution)
    try await f.host.acknowledgeResult(result)
    #expect(f.host.pendingOperation == nil && f.host.outcome == nil && f.host.queue.isEmpty)
    await #expect(throws: GatewayAvatarReviewHostFailure.displayRequired) {
        try await f.host.decide(.rejected, presentation: shown)
    }
}

@Test @MainActor func avatarReviewHostLostACKSurvivesRestartAndOnlyReadsExactSavedDecision() async throws {
    let f = try ReviewHostFixture()
    let shown = try await f.show()
    await f.api.setMode(.lostACK)
    await #expect(throws: GatewayAvatarReviewFailure.unavailable) {
        try await f.host.decide(.approved, presentation: shown)
    }
    let saved = try #require(f.host.pendingOperation)
    #expect(saved.phase == .dispatched && f.host.outcome == nil && f.host.presentation == nil)
    f.host.invalidate()
    f.clock.move(wall: 91_000, monotonic: 91)
    try await f.connect()
    #expect(f.host.pendingOperation == saved && f.host.outcome == nil && f.host.resolution == nil)
    await f.api.setMode(.normal)
    try await f.host.recover()
    #expect(await f.api.recoveries == [saved.intent])
    #expect(await f.api.decisions.count == 1)
    guard case .confirmed = f.host.outcome else {
        Issue.record("Expected exact recovered decision")
        return
    }
    try await f.host.acknowledgeResult(#require(f.host.resolution))
    #expect(f.host.pendingOperation == nil)
}

@Test @MainActor func avatarReviewHostPendingResultBlocksNewInspectionQueueAndReplacementVerdict()
    async throws
{
    let f = try ReviewHostFixture()
    let shown = try await f.show()
    await f.api.setMode(.lostACK)
    await #expect(throws: GatewayAvatarReviewFailure.unavailable) {
        try await f.host.decide(.approved, presentation: shown)
    }
    let saved = f.host.pendingOperation
    await #expect(throws: GatewayAvatarReviewJournalFailure.pendingExists) { try await f.host.refreshQueue() }
    await #expect(throws: GatewayAvatarReviewHostFailure.displayRequired) {
        try await f.host.decide(.rejected, presentation: shown)
    }
    #expect(f.host.pendingOperation == saved && f.host.isConnected)
    #expect(await f.api.decisions.count == 1)
}

@Test @MainActor func avatarReviewHostNotAppliedAndSupersededNeedExplicitResultAcknowledgement() async throws
{
    for mode in [ReviewHostAPI.Mode.beforeAccept, .superseded] {
        let f = try ReviewHostFixture()
        let shown = try await f.show()
        await f.api.setMode(.beforeAccept)
        await #expect(throws: GatewayAvatarReviewFailure.unavailable) {
            try await f.host.decide(.rejected, presentation: shown)
        }
        await f.api.setMode(mode)
        try await f.host.recover()
        #expect(f.host.outcome == (mode == .superseded ? .superseded : .notApplied))
        #expect(f.host.pendingOperation != nil && !f.host.canDecide && f.host.presentation == nil)
        try await f.host.acknowledgeResult(#require(f.host.resolution))
        #expect(f.host.pendingOperation == nil)
    }
}

@Test @MainActor func avatarReviewHostOldPresentationCannotAuthorizeFreshInspectionOrExpiredPixels()
    async throws
{
    let f = try ReviewHostFixture()
    let old = try await f.show()
    try await f.host.inspect(f.wire.item)
    let fresh = try #require(f.host.presentation)
    #expect(old != fresh && f.host.image(for: old) == nil && !f.host.canDecide)
    #expect(throws: GatewayAvatarReviewHostFailure.displayRequired) { try f.host.acknowledgeDisplay(old) }
    try f.host.acknowledgeDisplay(fresh)
    #expect(f.host.canDecide)
    f.clock.move(monotonic: 90)
    #expect(f.host.image(for: fresh) == nil && f.host.presentation == nil && !f.host.canDecide)
    f.host.expirePresentation()
    await #expect(throws: GatewayAvatarReviewHostFailure.displayRequired) {
        try await f.host.decide(.approved, presentation: fresh)
    }
    #expect(await f.api.decisions.isEmpty)
}

@Test @MainActor func avatarReviewHostBackgroundParentAndNativeIdentityFenceEveryGetter() async throws {
    for mode in ["background", "parent", "account", "icloud", "apple", "activation"] {
        let f = try ReviewHostFixture()
        let shown = try await f.show()
        switch mode {
        case "background": f.host.setForeground(false)
        case "parent": f.flags.parent = false
        case "account": try f.authorization.select(reviewModeratorB)
        case "icloud": f.authorization.cloudName = "other-cloud"
        case "apple":
            try f.authorization.select(
                reviewModeratorA, apple: "other-apple", cloud: "synthetic-review-cloud")
        default: f.flags.enabled = false
        }
        #expect(
            !f.host.isConnected && f.host.queue.isEmpty && f.host.presentation == nil
                && f.host.image(for: shown) == nil && !f.host.canDecide)
        await #expect(throws: GatewayAvatarReviewHostFailure.displayRequired) {
            try await f.host.decide(.approved, presentation: shown)
        }
        #expect(await f.api.decisions.isEmpty)
        f.host.invalidate()
    }
}

@Test @MainActor func avatarReviewHostLateInspectionKeepsUnsettledSlotAndCannotRestoreAfterBackground()
    async throws
{
    let f = try ReviewHostFixture()
    try await f.connect()
    try await f.host.refreshQueue()
    await f.api.pause("inspect")
    let task = Task { try await f.host.inspect(f.wire.item) }
    try await f.api.gate.wait()
    f.host.setForeground(false)
    f.host.setForeground(true)
    #expect(f.host.isBusy && f.host.presentation == nil)
    await #expect(throws: GatewayAvatarReviewFailure.busy) { try await f.connect() }
    await f.api.gate.release()
    await #expect(throws: GatewayAvatarReviewHostFailure.superseded) { try await task.value }
    #expect(!f.host.isBusy && f.host.presentation == nil && !f.host.isConnected)
    try await f.connect()
    #expect(f.host.presentation == nil)
}

@Test @MainActor func avatarReviewHostAccountSwapDuringNativeTokenStopsBeforeInspectAndPreservesNewAccount()
    async throws
{
    let f = try ReviewHostFixture()
    try await f.connect()
    try await f.host.refreshQueue()
    await f.authorization.gate.arm()
    let task = Task { try await f.host.inspect(f.wire.item) }
    try await f.authorization.gate.wait()
    try f.authorization.select(reviewModeratorB)
    await f.authorization.gate.release()
    await #expect(throws: GatewayAvatarReviewHostFailure.superseded) { try await task.value }
    #expect(await f.api.calls == ["queue"])
    #expect(
        f.authorization.communityAuthorization?.identity.accountID == reviewModeratorB
            && f.authorization.rejected == 0)
    f.host.invalidate()
}

@Test @MainActor func avatarReviewHostLateDecisionRemainsDurableButCannotCrossAccountOrScene() async throws {
    let f = try ReviewHostFixture()
    let shown = try await f.show()
    await f.api.pause("decide")
    let task = Task { try await f.host.decide(.approved, presentation: shown) }
    try await f.api.gate.wait()
    f.host.setForeground(false)
    #expect(f.host.isBusy && f.host.outcome == nil && f.host.pendingOperation == nil)
    await f.api.gate.release()
    await #expect(throws: GatewayAvatarReviewHostFailure.superseded) { try await task.value }
    f.host.setForeground(true)
    try await f.connect()
    #expect(f.host.pendingOperation?.phase == .dispatched && f.host.outcome == nil)
    try await f.host.recover()
    guard case .confirmed = f.host.outcome else {
        Issue.record("Expected preserved decision")
        return
    }
}

@Test @MainActor func avatarReviewHostRoleDenialDoesNotSignOutButInvalidSessionDoes() async throws {
    for mode in [ReviewHostAPI.Mode.denied, .signIn, .unknown] {
        let f = try ReviewHostFixture()
        try await f.connect()
        await f.api.setMode(mode)
        do {
            try await f.host.refreshQueue()
            Issue.record("Expected failure")
        } catch {
            #expect(!error.localizedDescription.contains("PRIVATE"))
            if mode == .denied {
                #expect(error as? GatewayAvatarReviewFailure == .denied && f.host.isRoleDenied)
            } else if mode == .signIn {
                #expect(error as? GatewayFailure == .signInRequired && !f.host.isConnected)
            } else {
                #expect(error as? GatewayAvatarReviewFailure == .unavailable)
            }
        }
        #expect(f.authorization.rejected == (mode == .signIn ? 1 : 0))
        f.host.invalidate()
    }
}

@Test @MainActor func avatarReviewHostStorageFailureBeforeDispatchNeverSendsAndAmbiguousIntentCanBeRecovered()
    async throws
{
    for phase in ["prepare", "dispatch", "resolve"] {
        let f = try ReviewHostFixture()
        let shown = try await f.show()
        f.storage.failAt = f.storage.writes + (phase == "prepare" ? 1 : phase == "dispatch" ? 2 : 3)
        f.storage.afterWrite = true
        await #expect(throws: GatewayAvatarReviewJournalFailure.unavailable) {
            try await f.host.decide(.approved, presentation: shown)
        }
        #expect(!f.host.isConnected && f.host.presentation == nil)
        #expect(await f.api.decisions.count == (phase == "resolve" ? 1 : 0))
        f.storage.failAt = nil
        try await f.connect()
        #expect(f.host.pendingOperation != nil && f.host.outcome == nil)
        try await f.host.recover()
        if phase == "resolve" {
            guard case .confirmed = f.host.outcome else {
                Issue.record("Applied result missing")
                return
            }
        } else {
            #expect(f.host.outcome == .notApplied)
        }
    }
}

@Test @MainActor func avatarReviewHostDeletionFencesLateWorkAndNeverRestoresErasedJournal() async throws {
    let f = try ReviewHostFixture()
    let shown = try await f.show()
    await f.api.pause("decide")
    let task = Task { try await f.host.decide(.approved, presentation: shown) }
    try await f.api.gate.wait()
    f.host.invalidate()
    try f.journal.fenceForAccountDeletion(binding: f.scope.binding, accountID: reviewModeratorA)
    try await f.journal.erase(owner: f.scope.owner)
    await f.api.gate.release()
    await #expect(throws: GatewayAvatarReviewHostFailure.superseded) { try await task.value }
    #expect(f.storage.records.isEmpty && f.host.outcome == nil)
    await #expect(throws: GatewayAvatarReviewJournalFailure.inactive) { try await f.connect() }
}

@Test @MainActor func avatarReviewHostRestoredResolvedRecordNeedsFreshOutcomeAndRejectsOldAcknowledgement()
    async throws
{
    let f = try ReviewHostFixture()
    let shown = try await f.show()
    try await f.host.decide(.approved, presentation: shown)
    let old = try #require(f.host.resolution)
    f.host.invalidate()
    try await f.connect()
    #expect(f.host.pendingOperation?.phase == .resolved && f.host.resolution == nil && f.host.outcome == nil)
    await #expect(throws: GatewayAvatarReviewJournalFailure.invalidTransition) {
        try await f.host.acknowledgeResult(old)
    }
    try await f.host.recover()
    await #expect(throws: GatewayAvatarReviewJournalFailure.invalidTransition) {
        try await f.host.acknowledgeResult(old)
    }
    try await f.host.acknowledgeResult(#require(f.host.resolution))
}

@Test @MainActor func avatarReviewHostReadsConcreteServerRecoveryIntoRealJournalWithoutAnyDecision()
    async throws
{
    let rows = try ReviewRecoveryWireFixture().rows
    for row in rows {
        let f = try ReviewHostFixture()
        let lease = try await f.journal.open(scope: f.scope)
        _ = try await f.journal.prepare(row.intent, lease: lease)
        let client = try reviewClient(
            ReviewHTTPStub(row.response), clock: f.clock, origin: URL(string: f.api.origin)!)
        let host = try GatewayAvatarReviewHost(
            api: client, configuration: .init(origin: URL(string: f.api.origin)!),
            cloudKit: f.scope.owner.configuration, authorization: f.authorization, journal: f.journal,
            isEnabled: { true }, date: { f.clock.date() }, uptime: { f.clock.up() })
        host.setForeground(true)
        try await host.connect()
        try await host.recover()
        #expect(
            host.pendingOperation?.phase == .resolved && host.outcome == row.expected
                && host.presentation == nil)
        try await host.acknowledgeResult(#require(host.resolution))
        #expect(host.pendingOperation == nil)
        host.invalidate()
    }
}

@Test @MainActor func avatarReviewHostJournalFenceAloneImmediatelyHidesPixelsAndStopsDecisions() async throws
{
    let f = try ReviewHostFixture()
    let shown = try await f.show()
    try f.journal.fenceForAccountDeletion(binding: f.scope.binding, accountID: reviewModeratorA)
    #expect(!f.host.isConnected && f.host.presentation == nil && f.host.image(for: shown) == nil)
    await #expect(throws: GatewayAvatarReviewHostFailure.displayRequired) {
        try await f.host.decide(.approved, presentation: shown)
    }
    #expect(await f.api.decisions.isEmpty)
    f.host.invalidate()
}

@Test @MainActor func avatarReviewHostReplacingSharedJournalLeaseRevokesOldDisplayWithoutAwait() async throws
{
    let f = try ReviewHostFixture()
    let shown = try await f.show()
    _ = try await f.journal.open(scope: f.scope)
    #expect(!f.host.isConnected && f.host.image(for: shown) == nil && !f.host.canDecide)
    f.host.invalidate()
}

@Test @MainActor func avatarReviewHostAmbiguousAcknowledgementForcesReopenWithoutNewDecision() async throws {
    for afterWrite in [false, true] {
        let f = try ReviewHostFixture()
        let shown = try await f.show()
        try await f.host.decide(.approved, presentation: shown)
        let result = try #require(f.host.resolution)
        f.storage.failAt = f.storage.writes + 1
        f.storage.afterWrite = afterWrite
        await #expect(throws: GatewayAvatarReviewJournalFailure.unavailable) {
            try await f.host.acknowledgeResult(result)
        }
        #expect(!f.host.isConnected && f.host.outcome == nil)
        f.storage.failAt = nil
        try await f.connect()
        #expect((f.host.pendingOperation == nil) == afterWrite)
        #expect(f.host.outcome == nil && f.host.resolution == nil)
        #expect(await f.api.decisions.count == 1)
    }
}

@MainActor private func waitForReviewStorage(_ storage: ReviewMemoryStorage) async throws {
    for _ in 0..<5000 {
        if storage.gate.hasEntered() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayAvatarReviewFailure.unavailable
}
@Test @MainActor func avatarReviewHostStorageRunsOffMainThreadAndNativeScopeStillFencesDuringWrite()
    async throws
{
    let f = try ReviewHostFixture()
    let shown = try await f.show()
    f.storage.gate.arm()
    let task = Task { try await f.host.decide(.approved, presentation: shown) }
    defer {
        f.storage.gate.release()
        task.cancel()
    }
    try await waitForReviewStorage(f.storage)
    #expect(f.host.isBusy && f.host.presentation == nil)
    f.authorization.cloudName = "other-cloud"
    #expect(!f.host.isConnected)
    f.storage.gate.release()
    await #expect(throws: GatewayAvatarReviewHostFailure.superseded) { try await task.value }
    #expect(await f.api.decisions.isEmpty)
    #expect(!f.storage.mainThreadIO)
    f.host.invalidate()
}
@Test @MainActor func avatarReviewHostPausedStorageCannotRestoreAfterDeletionAndOldQueuedWrite() async throws
{
    let f = try ReviewHostFixture()
    let shown = try await f.show()
    f.storage.gate.arm()
    let task = Task { try await f.host.decide(.approved, presentation: shown) }
    defer {
        f.storage.gate.release()
        task.cancel()
    }
    try await waitForReviewStorage(f.storage)
    f.host.invalidate()
    try f.journal.fenceForAccountDeletion(binding: f.scope.binding, accountID: reviewModeratorA)
    let erase = Task { try await f.journal.erase(owner: f.scope.owner) }
    f.storage.gate.release()
    do {
        try await task.value
        Issue.record("Old write must not dispatch")
    } catch {
        #expect(
            error is GatewayAvatarReviewJournalFailure || error is GatewayAvatarReviewHostFailure
                || error as? GatewayFailure == .cancelled)
    }
    try await erase.value
    #expect(f.storage.records.isEmpty && !f.storage.mainThreadIO)
    #expect(await f.api.decisions.isEmpty)
    await #expect(throws: GatewayAvatarReviewJournalFailure.inactive) { try await f.connect() }
}

@Test @MainActor
func avatarReviewHostExplicitCancellationDuringStoragePreservesUnknownIntentAndRequiresReopen() async throws {
    let f = try ReviewHostFixture()
    let shown = try await f.show()
    f.storage.gate.arm()
    let task = Task { try await f.host.decide(.approved, presentation: shown) }
    defer {
        f.storage.gate.release()
        task.cancel()
    }
    try await waitForReviewStorage(f.storage)
    task.cancel()
    f.storage.gate.release()
    await #expect(throws: GatewayFailure.cancelled) { try await task.value }
    #expect(!f.host.isConnected && f.host.outcome == nil && !f.storage.mainThreadIO)
    #expect(await f.api.decisions.isEmpty)
    try await f.connect()
    #expect(f.host.pendingOperation?.phase == .prepared)
    try await f.host.recover()
    #expect(f.host.outcome == .notApplied)
}
