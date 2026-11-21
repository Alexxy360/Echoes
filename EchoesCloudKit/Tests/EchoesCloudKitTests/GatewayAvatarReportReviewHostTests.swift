import Foundation
import Observation
import Testing

@testable import EchoesCloudKit

actor ReportedPhotoReviewHostAPI: GatewayAvatarReportReviewAPI {
    nonisolated let origin = "https://review-host.example.invalid"
    enum Mode: Sendable {
        case normal, denied, signIn, unknown, lostACK, beforeAccept, superseded, lostRetirementACK,
            unsafeRetirement
    }
    var mode: Mode = .normal
    var calls: [String] = []
    var decisions: [GatewayAvatarReportReviewDecisionIntent] = []
    var recoveries: [GatewayAvatarReportReviewRecoveryIntent] = []
    var applied: [String: String] = [:]
    var retired: [String: GatewayAvatarReportReviewRecoveryIntent] = [:]
    var retirements: [GatewayAvatarReportReviewRecoveryIntent] = []
    var pages: [GatewayAvatarReportReviewPage] = []
    var cursors: [GatewayAvatarReportReviewCursor?] = []
    var inspectionOverride: GatewayAvatarReportReviewInspection?
    let fixture: ReportedPhotoWireFixture
    let clock: ReviewClock
    let gate = PhotoGate()
    private var pauseAction = ""
    var beforeDecision: (@Sendable (GatewayAvatarReportReviewDecisionIntent) async throws -> Void)?
    init(fixture: ReportedPhotoWireFixture, clock: ReviewClock) {
        self.fixture = fixture
        self.clock = clock
    }
    func setMode(_ value: Mode) { mode = value }
    func setPages(_ values: [GatewayAvatarReportReviewPage]) { pages = values }
    func setInspection(_ value: GatewayAvatarReportReviewInspection) { inspectionOverride = value }
    func pause(_ action: String) async {
        pauseAction = action
        await gate.arm()
    }
    func before(
        _ callback: @escaping @Sendable (GatewayAvatarReportReviewDecisionIntent) async throws -> Void
    ) {
        beforeDecision = callback
    }
    private func begin(_ action: String) throws {
        calls.append(action)
        switch mode {
        case .denied: throw GatewayAvatarReportReviewFailure.denied
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
    func queue(after: GatewayAvatarReportReviewCursor?, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewPage
    {
        try begin("queue")
        cursors.append(after)
        let value: GatewayAvatarReportReviewPage
        if !pages.isEmpty {
            value = pages.removeFirst()
        } else {
            value = try await reportedPhotoClient(
                ReportedPhotoHTTPStub(fixture.queue), clock: clock, origin: URL(string: origin)!
            ).queue(after: after, token: token)
        }
        await hold("queue")
        return value
    }
    func inspect(_ item: GatewayAvatarReportReviewItem, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewInspection
    {
        try begin("inspect")
        let value: GatewayAvatarReportReviewInspection
        if let inspectionOverride {
            value = inspectionOverride
        } else {
            value = try await reportedPhotoClient(
                ReportedPhotoHTTPStub(fixture.inspection), clock: clock, origin: URL(string: origin)!
            ).inspect(item, token: token)
        }
        await hold("inspect")
        return value
    }
    func decide(_ intent: GatewayAvatarReportReviewDecisionIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewDecisionResult
    {
        try begin("decide")
        decisions.append(intent)
        let callback = beforeDecision
        beforeDecision = nil
        try await callback?(intent)
        if retired[intent.decisionID] != nil { throw GatewayAvatarReportReviewFailure.stale }
        if mode == .beforeAccept { throw GatewayAvatarReportReviewFailure.unavailable }
        let revision = UUID().uuidString.lowercased()
        applied[intent.decisionID] = revision
        await hold("decide")
        if mode == .lostACK { throw GatewayAvatarReportReviewFailure.unavailable }
        return .init(intent: intent, revision: revision)
    }
    func recover(_ intent: GatewayAvatarReportReviewRecoveryIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewRecoveryResult
    {
        try begin("recover")
        recoveries.append(intent)
        let outcome: GatewayAvatarReportReviewOutcome =
            mode == .superseded
            ? .superseded
            : retired[intent.decisionID] == intent
                ? .retired : applied[intent.decisionID].map { .confirmed(revision: $0) } ?? .notApplied
        await hold("recover")
        return .init(intent: intent, outcome: outcome)
    }
    func retire(_ intent: GatewayAvatarReportReviewRecoveryIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewRecoveryResult
    {
        try begin("retire")
        retirements.append(intent)
        if mode == .unsafeRetirement { return .init(intent: intent, outcome: .notApplied) }
        let outcome: GatewayAvatarReportReviewOutcome
        if let revision = applied[intent.decisionID] {
            outcome = .confirmed(revision: revision)
        } else if mode == .superseded {
            outcome = .superseded
        } else {
            retired[intent.decisionID] = intent
            outcome = .retired
        }
        await hold("retire")
        if mode == .lostRetirementACK { throw GatewayAvatarReportReviewFailure.unavailable }
        return .init(intent: intent, outcome: outcome)
    }
}
@MainActor final class ReportedPhotoReviewHostFlags {
    var enabled = true
    var parent = true
    var events: [GatewayAvatarReportReviewPublicationEvent] = []
    var onEvent: (@MainActor (GatewayAvatarReportReviewPublicationEvent) -> Void)?
}
@MainActor struct ReportedPhotoReviewHostFixture {
    let wire: ReportedPhotoWireFixture
    let clock: ReviewClock
    let flags = ReportedPhotoReviewHostFlags()
    let authorization: PhotoAuthorization
    let storage: ReportedPhotoJournalMemoryStorage
    let journal: GatewayAvatarReportReviewJournal
    let scope: GatewayAvatarReportReviewScope
    let api: ReportedPhotoReviewHostAPI
    let host: GatewayAvatarReportReviewHost
    init(
        storage: ReportedPhotoJournalMemoryStorage? = nil, api: ReportedPhotoReviewHostAPI? = nil
    ) throws {
        wire = try .init()
        clock = ReviewClock(wire.now)
        authorization = try .init()
        try authorization.select(
            reviewModeratorA, apple: "synthetic-review-apple", cloud: "synthetic-review-cloud")
        self.storage = storage ?? ReportedPhotoJournalMemoryStorage()
        journal = .init(storage: self.storage)
        scope = try reportedPhotoStoreScope()
        self.api = api ?? ReportedPhotoReviewHostAPI(fixture: wire, clock: clock)
        host = try GatewayAvatarReportReviewHost(
            api: self.api,
            configuration: .init(origin: URL(string: self.api.origin)!), cloudKit: scope.owner.configuration,
            authorization: authorization, journal: journal, isEnabled: { [flags] in flags.enabled },
            date: { [clock] in clock.date() }, uptime: { [clock] in clock.up() },
            publicationChanged: { [flags] event in
                flags.events.append(event)
                flags.onEvent?(event)
            })
        host.setForeground(true)
    }
    func connect() async throws { try await host.connect { flags.parent } }
    func show(acknowledge: Bool = true) async throws -> GatewayAvatarReportReviewPresentation {
        if !host.isConnected { try await connect() }
        try await host.refreshQueue()
        try await host.inspect(wire.item)
        let shown = try #require(host.presentation)
        #expect(host.material(for: shown) != nil)
        if acknowledge { try host.acknowledgeDisplay(shown) }
        return shown
    }
}

@Test @MainActor func avatarReportReviewHostRequiresActualCurrentDisplayAndPersistsDispatchedIntentBeforeAPI()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let shown = try await f.show(acknowledge: false)
    #expect(!f.host.canDecide)
    await #expect(throws: GatewayAvatarReportReviewHostFailure.displayRequired) {
        try await f.host.decide(.hidePhoto, presentation: shown)
    }
    #expect(await f.api.decisions.isEmpty)
    try f.host.acknowledgeDisplay(shown)
    await f.api.before { intent in
        await MainActor.run {
            #expect(f.host.pendingOperation?.phase == .dispatched)
            #expect(
                f.host.pendingOperation?.intent.recovery
                    == GatewayAvatarReportReviewRecoveryIntent(decision: intent))
            #expect(f.host.presentation == nil && f.host.material(for: shown) == nil)
        }
    }
    try await f.host.decide(.hidePhoto, presentation: shown)
    #expect(f.host.pendingOperation?.phase == .resolved && f.host.outcome != nil)
    #expect(await f.api.calls == ["queue", "inspect", "decide"])
    let result = try #require(f.host.resolution)
    try await f.host.acknowledgeResult(result)
    #expect(f.host.pendingOperation == nil && f.host.outcome == nil && f.host.queue.isEmpty)
    await #expect(throws: GatewayAvatarReportReviewHostFailure.displayRequired) {
        try await f.host.decide(.dismiss, presentation: shown)
    }
}

@Test @MainActor func avatarReportReviewHostLostACKSurvivesRestartAndOnlyReadsExactSavedDecision()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let shown = try await f.show()
    await f.api.setMode(.lostACK)
    await #expect(throws: GatewayAvatarReportReviewFailure.unavailable) {
        try await f.host.decide(.hidePhoto, presentation: shown)
    }
    let saved = try #require(f.host.pendingOperation)
    #expect(saved.phase == .dispatched && f.host.outcome == nil && f.host.presentation == nil)
    f.host.invalidate()
    f.clock.move(wall: 91_000, monotonic: 91)
    try await f.connect()
    #expect(f.host.pendingOperation == saved && f.host.outcome == nil && f.host.resolution == nil)
    await f.api.setMode(.normal)
    try await f.host.recover()
    #expect(await f.api.recoveries == [saved.intent.recovery])
    #expect(await f.api.decisions.count == 1)
    guard case .confirmed = f.host.outcome else {
        Issue.record("Expected exact recovered decision")
        return
    }
    try await f.host.acknowledgeResult(#require(f.host.resolution))
    #expect(f.host.pendingOperation == nil)
}

@Test @MainActor func avatarReportReviewHostPendingResultBlocksNewInspectionQueueAndReplacementVerdict()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let shown = try await f.show()
    await f.api.setMode(.lostACK)
    await #expect(throws: GatewayAvatarReportReviewFailure.unavailable) {
        try await f.host.decide(.hidePhoto, presentation: shown)
    }
    let saved = f.host.pendingOperation
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.pendingExists) {
        try await f.host.refreshQueue()
    }
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.pendingExists) {
        try await f.host.inspect(f.wire.item)
    }
    await #expect(throws: GatewayAvatarReportReviewHostFailure.displayRequired) {
        try await f.host.decide(.dismiss, presentation: shown)
    }
    #expect(f.host.pendingOperation == saved && f.host.isConnected)
    #expect(await f.api.decisions.count == 1)
}

@Test @MainActor func avatarReportReviewHostOnlyTerminalOutcomeCanBeAcknowledged() async throws {
    for mode in [ReportedPhotoReviewHostAPI.Mode.beforeAccept, .superseded] {
        let f = try ReportedPhotoReviewHostFixture()
        let shown = try await f.show()
        await f.api.setMode(.beforeAccept)
        await #expect(throws: GatewayAvatarReportReviewFailure.unavailable) {
            try await f.host.decide(.dismiss, presentation: shown)
        }
        await f.api.setMode(mode)
        try await f.host.recover()
        #expect(f.host.outcome == (mode == .superseded ? .superseded : .notApplied))
        #expect(f.host.pendingOperation != nil && !f.host.canDecide && f.host.presentation == nil)
        if mode == .superseded {
            try await f.host.acknowledgeResult(#require(f.host.resolution))
            #expect(f.host.pendingOperation == nil)
        } else {
            #expect(f.host.resolution == nil && f.host.canRetirePending)
            #expect(f.host.pendingOperation?.phase == .dispatched)
            #expect(await f.api.retirements.isEmpty)
        }
    }
}

@Test @MainActor func avatarReportReviewHostOldPresentationCannotAuthorizeFreshInspectionOrExpiredText()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let old = try await f.show()
    try await f.host.inspect(f.wire.item)
    let fresh = try #require(f.host.presentation)
    #expect(old != fresh && f.host.material(for: old) == nil && !f.host.canDecide)
    #expect(throws: GatewayAvatarReportReviewHostFailure.displayRequired) {
        try f.host.acknowledgeDisplay(old)
    }
    #expect(f.host.material(for: fresh) != nil)
    try f.host.acknowledgeDisplay(fresh)
    #expect(f.host.canDecide)
    f.clock.move(monotonic: 90)
    #expect(f.host.material(for: fresh) == nil && f.host.presentation == nil && !f.host.canDecide)
    f.host.expirePresentation()
    await #expect(throws: GatewayAvatarReportReviewHostFailure.displayRequired) {
        try await f.host.decide(.hidePhoto, presentation: fresh)
    }
    #expect(await f.api.decisions.isEmpty)
}

@Test @MainActor func avatarReportReviewHostBackgroundParentAndNativeIdentityFenceEveryGetter() async throws {
    for mode in ["background", "parent", "account", "icloud", "apple", "activation"] {
        let f = try ReportedPhotoReviewHostFixture()
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
                && f.host.material(for: shown) == nil && !f.host.canDecide)
        await #expect(throws: GatewayAvatarReportReviewHostFailure.displayRequired) {
            try await f.host.decide(.hidePhoto, presentation: shown)
        }
        #expect(await f.api.decisions.isEmpty)
        f.host.invalidate()
    }
}

@Test @MainActor func avatarReportReviewHostLateInspectionKeepsUnsettledSlotAndCannotRestoreAfterBackground()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    try await f.connect()
    try await f.host.refreshQueue()
    await f.api.pause("inspect")
    let task = Task { try await f.host.inspect(f.wire.item) }
    try await f.api.gate.wait()
    f.host.setForeground(false)
    f.host.setForeground(true)
    #expect(f.host.isBusy && f.host.presentation == nil)
    await #expect(throws: GatewayAvatarReportReviewFailure.busy) { try await f.connect() }
    await f.api.gate.release()
    await #expect(throws: GatewayAvatarReportReviewHostFailure.superseded) { try await task.value }
    #expect(!f.host.isBusy && f.host.presentation == nil && !f.host.isConnected)
    try await f.connect()
    #expect(f.host.presentation == nil)
}

@Test @MainActor
func avatarReportReviewHostAccountSwapDuringNativeTokenStopsBeforeInspectAndPreservesNewAccount()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    try await f.connect()
    try await f.host.refreshQueue()
    await f.authorization.gate.arm()
    let task = Task { try await f.host.inspect(f.wire.item) }
    try await f.authorization.gate.wait()
    try f.authorization.select(reviewModeratorB)
    await f.authorization.gate.release()
    await #expect(throws: GatewayAvatarReportReviewHostFailure.superseded) { try await task.value }
    #expect(await f.api.calls == ["queue"])
    #expect(
        f.authorization.communityAuthorization?.identity.accountID == reviewModeratorB
            && f.authorization.rejected == 0)
    f.host.invalidate()
}

@Test @MainActor func avatarReportReviewHostLateDecisionRemainsDurableButCannotCrossAccountOrScene()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let shown = try await f.show()
    await f.api.pause("decide")
    let task = Task { try await f.host.decide(.hidePhoto, presentation: shown) }
    try await f.api.gate.wait()
    f.host.setForeground(false)
    #expect(f.host.isBusy && f.host.outcome == nil && f.host.pendingOperation == nil)
    await f.api.gate.release()
    await #expect(throws: GatewayAvatarReportReviewHostFailure.superseded) { try await task.value }
    f.host.setForeground(true)
    try await f.connect()
    #expect(f.host.pendingOperation?.phase == .dispatched && f.host.outcome == nil)
    try await f.host.recover()
    guard case .confirmed = f.host.outcome else {
        Issue.record("Expected preserved decision")
        return
    }
}

@Test @MainActor func avatarReportReviewHostRoleDenialDoesNotSignOutButInvalidSessionDoes() async throws {
    for mode in [ReportedPhotoReviewHostAPI.Mode.denied, .signIn, .unknown] {
        let f = try ReportedPhotoReviewHostFixture()
        try await f.connect()
        await f.api.setMode(mode)
        do {
            try await f.host.refreshQueue()
            Issue.record("Expected failure")
        } catch {
            #expect(!error.localizedDescription.contains("PRIVATE"))
            if mode == .denied {
                #expect(error as? GatewayAvatarReportReviewFailure == .denied && f.host.isRoleDenied)
            } else if mode == .signIn {
                #expect(error as? GatewayFailure == .signInRequired && !f.host.isConnected)
            } else {
                #expect(error as? GatewayAvatarReportReviewFailure == .unavailable)
            }
        }
        #expect(f.authorization.rejected == (mode == .signIn ? 1 : 0))
        f.host.invalidate()
    }
}

@Test @MainActor
func avatarReportReviewHostStorageFailureBeforeDispatchNeverSendsAndAmbiguousIntentCanBeRecovered()
    async throws
{
    for phase in ["prepare", "dispatch", "resolve"] {
        let f = try ReportedPhotoReviewHostFixture()
        let shown = try await f.show()
        f.storage.failAt = f.storage.writes + (phase == "prepare" ? 1 : phase == "dispatch" ? 2 : 3)
        f.storage.afterWrite = true
        await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
            try await f.host.decide(.hidePhoto, presentation: shown)
        }
        #expect(!f.host.isConnected && f.host.presentation == nil)
        #expect(await f.api.decisions.count == (phase == "resolve" ? 1 : 0))
        f.storage.failAt = nil
        try await f.connect()
        #expect(f.host.pendingOperation != nil && (f.host.outcome != nil) == (phase == "resolve"))
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

@Test @MainActor func avatarReportReviewHostDeletionFencesLateWorkAndNeverRestoresErasedJournal() async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let shown = try await f.show()
    await f.api.pause("decide")
    let task = Task { try await f.host.decide(.hidePhoto, presentation: shown) }
    try await f.api.gate.wait()
    f.host.invalidate()
    try f.journal.fenceForAccountDeletion(binding: f.scope.binding, accountID: reviewModeratorA)
    try await f.journal.erase(owner: f.scope.owner)
    await f.api.gate.release()
    await #expect(throws: GatewayAvatarReportReviewHostFailure.superseded) { try await task.value }
    #expect(f.storage.records.isEmpty && f.host.outcome == nil)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) { try await f.connect() }
}

@Test @MainActor
func avatarReportReviewHostRestoredTerminalRecordCreatesFreshHandleAndRejectsOldAcknowledgement()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let shown = try await f.show()
    try await f.host.decide(.hidePhoto, presentation: shown)
    let old = try #require(f.host.resolution)
    f.host.invalidate()
    try await f.connect()
    #expect(f.host.pendingOperation?.phase == .resolved && f.host.resolution != nil && f.host.outcome != nil)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.invalidTransition) {
        try await f.host.acknowledgeResult(old)
    }
    try await f.host.recover()
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.invalidTransition) {
        try await f.host.acknowledgeResult(old)
    }
    try await f.host.acknowledgeResult(#require(f.host.resolution))
}

@Test @MainActor func avatarReportReviewHostReadsConcreteServerRecoveryIntoRealJournalWithoutAnyDecision()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let wire = try ReportedPhotoWireFixture()
    for label in ["recover-not-applied", "recover-confirmed"] {
        let journal = GatewayAvatarReportReviewJournal(storage: ReportedPhotoJournalMemoryStorage())
        let lease = try await journal.open(scope: f.scope)
        _ = try await journal.prepare(reportedPhotoStoreIntent(), lease: lease)
        let client = try reportedPhotoClient(
            ReportedPhotoHTTPStub(wire.cases[label]!), clock: f.clock, origin: URL(string: f.api.origin)!)
        let host = try GatewayAvatarReportReviewHost(
            api: client, configuration: .init(origin: URL(string: f.api.origin)!),
            cloudKit: f.scope.owner.configuration,
            authorization: f.authorization, journal: journal, isEnabled: { true }, date: { f.clock.date() },
            uptime: { f.clock.up() })
        host.setForeground(true)
        try await host.connect()
        try await host.recover()
        #expect(host.outcome != nil && host.presentation == nil)
        if label == "recover-not-applied" {
            #expect(
                host.pendingOperation?.phase == .dispatched && host.resolution == nil && host.canRetirePending
            )
        } else {
            #expect(host.pendingOperation?.phase == .resolved)
            try await host.acknowledgeResult(#require(host.resolution))
            #expect(host.pendingOperation == nil)
        }
        host.invalidate()
    }
}

@Test @MainActor func avatarReportReviewHostJournalFenceAloneImmediatelyHidesTextAndStopsDecisions()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let shown = try await f.show()
    try f.journal.fenceForAccountDeletion(binding: f.scope.binding, accountID: reviewModeratorA)
    #expect(!f.host.isConnected && f.host.presentation == nil && f.host.material(for: shown) == nil)
    await #expect(throws: GatewayAvatarReportReviewHostFailure.displayRequired) {
        try await f.host.decide(.hidePhoto, presentation: shown)
    }
    #expect(await f.api.decisions.isEmpty)
    f.host.invalidate()
}

@Test @MainActor func avatarReportReviewHostReplacingSharedJournalLeaseRevokesOldDisplayWithoutAwait()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let shown = try await f.show()
    _ = try await f.journal.open(scope: f.scope)
    #expect(!f.host.isConnected && f.host.material(for: shown) == nil && !f.host.canDecide)
    f.host.invalidate()
}

@Test @MainActor func avatarReportReviewHostAmbiguousAcknowledgementForcesReopenWithoutNewDecision()
    async throws
{
    for afterWrite in [false, true] {
        let f = try ReportedPhotoReviewHostFixture()
        let shown = try await f.show()
        try await f.host.decide(.hidePhoto, presentation: shown)
        let result = try #require(f.host.resolution)
        f.storage.failAt = f.storage.writes + 1
        f.storage.afterWrite = afterWrite
        await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
            try await f.host.acknowledgeResult(result)
        }
        #expect(!f.host.isConnected && f.host.outcome == nil)
        f.storage.failAt = nil
        try await f.connect()
        #expect((f.host.pendingOperation == nil) == afterWrite)
        #expect((f.host.outcome == nil) == afterWrite && (f.host.resolution == nil) == afterWrite)
        #expect(await f.api.decisions.count == 1)
    }
}

@MainActor private func waitForReportedPhotoReviewStorage(_ storage: ReportedPhotoJournalMemoryStorage)
    async throws
{
    for _ in 0..<5000 {
        if storage.gate.hasEntered() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayAvatarReportReviewFailure.unavailable
}
@Test @MainActor func avatarReportReviewHostStorageRunsOffMainThreadAndNativeScopeStillFencesDuringWrite()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let shown = try await f.show()
    f.storage.gate.arm()
    let task = Task { try await f.host.decide(.hidePhoto, presentation: shown) }
    defer {
        f.storage.gate.release()
        task.cancel()
    }
    try await waitForReportedPhotoReviewStorage(f.storage)
    #expect(f.host.isBusy && f.host.presentation == nil)
    f.authorization.cloudName = "other-cloud"
    #expect(!f.host.isConnected)
    f.storage.gate.release()
    await #expect(throws: GatewayAvatarReportReviewHostFailure.superseded) { try await task.value }
    #expect(await f.api.decisions.isEmpty)
    #expect(!f.storage.mainThreadIO)
    f.host.invalidate()
}
@Test @MainActor func avatarReportReviewHostPausedStorageCannotRestoreAfterDeletionAndOldQueuedWrite()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let shown = try await f.show()
    f.storage.gate.arm()
    let task = Task { try await f.host.decide(.hidePhoto, presentation: shown) }
    defer {
        f.storage.gate.release()
        task.cancel()
    }
    try await waitForReportedPhotoReviewStorage(f.storage)
    f.host.invalidate()
    try f.journal.fenceForAccountDeletion(binding: f.scope.binding, accountID: reviewModeratorA)
    let erase = Task { try await f.journal.erase(owner: f.scope.owner) }
    f.storage.gate.release()
    do {
        try await task.value
        Issue.record("Old write must not dispatch")
    } catch {
        #expect(
            error is GatewayAvatarReportReviewJournalFailure || error is GatewayAvatarReportReviewHostFailure
                || error as? GatewayFailure == .cancelled)
    }
    try await erase.value
    #expect(f.storage.records.isEmpty && !f.storage.mainThreadIO)
    #expect(await f.api.decisions.isEmpty)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) { try await f.connect() }
}

@Test @MainActor
func avatarReportReviewHostExplicitCancellationDuringStoragePreservesUnknownIntentAndRequiresReopen()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let shown = try await f.show()
    f.storage.gate.arm()
    let task = Task { try await f.host.decide(.hidePhoto, presentation: shown) }
    defer {
        f.storage.gate.release()
        task.cancel()
    }
    try await waitForReportedPhotoReviewStorage(f.storage)
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

@Test @MainActor func avatarReportReviewHostRequiresMaterialGetterBeforeDisplayACK() async throws {
    let f = try ReportedPhotoReviewHostFixture()
    try await f.connect()
    try await f.host.refreshQueue()
    try await f.host.inspect(f.wire.item)
    let handle = try #require(f.host.presentation)
    #expect(throws: GatewayAvatarReportReviewHostFailure.displayRequired) {
        try f.host.acknowledgeDisplay(handle)
    }
    #expect(!f.host.canDecide && !f.host.canHidePhoto)
    let material = try #require(f.host.material(for: handle))
    let image = try #require(material.image)
    #expect(material.reason == "PRIVATE_SYNTHETIC_PHOTO_REASON" && image.width == 256 && image.height == 128)
    try f.host.acknowledgeDisplay(handle)
    #expect(f.host.canDecide && f.host.canHidePhoto)
    f.host.invalidate()
    #expect(f.host.material(for: handle) == nil)
}
@Test @MainActor func avatarReportReviewHostClockRollbackNeverResurrectsObservedContext() async throws {
    for (wall, monotonic) in [(-50, 0.0), (0, -0.05)] {
        let f = try ReportedPhotoReviewHostFixture()
        let handle = try await f.show()
        f.clock.move(wall: 100, monotonic: 0.1)
        #expect(f.host.material(for: handle) != nil)
        f.clock.move(wall: wall, monotonic: monotonic)
        #expect(f.host.material(for: handle) == nil && !f.host.isConnected)
        f.clock.move(wall: -wall, monotonic: -monotonic)
        #expect(f.host.material(for: handle) == nil && !f.host.isConnected && f.host.presentation == nil)
        try await f.connect()
        let fresh = try await f.show()
        #expect(fresh != handle && f.host.canDecide)
        f.host.invalidate()
    }
}
@Test @MainActor func avatarReportReviewHostPublicationEventsFollowDurableExactIntentAndTerminalOutcome()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let handle = try await f.show()
    f.flags.onEvent = { [weak host = f.host] event in
        let entry = host?.pendingOperation
        switch event {
        case .pending(let intent):
            #expect(entry?.phase == .prepared && entry?.intent == intent && intent.photoTarget != nil)
        case .resolved(let intent, let outcome):
            #expect(entry?.phase == .resolved && entry?.intent == intent && outcome.isTerminal)
        }
    }
    await f.api.before { intent in
        await MainActor.run {
            #expect(f.flags.events.count == 1 && f.host.pendingOperation?.phase == .dispatched)
            #expect(f.host.pendingOperation?.intent.photoTarget == intent.receipt.photoTarget)
        }
    }
    try await f.host.decide(.hidePhoto, presentation: handle)
    #expect(f.flags.events.count == 2)
    try await f.host.acknowledgeResult(#require(f.host.resolution))
    #expect(f.flags.events.count == 2 && f.host.pendingOperation == nil)
}
@Test @MainActor
func avatarReportReviewHostNotAppliedAndLostRetirementACKPreserveTargetUntilExplicitRecovery() async throws {
    let f = try ReportedPhotoReviewHostFixture()
    let handle = try await f.show()
    await f.api.setMode(.beforeAccept)
    await #expect(throws: GatewayAvatarReportReviewFailure.unavailable) {
        try await f.host.decide(.hidePhoto, presentation: handle)
    }
    let saved = try #require(f.host.pendingOperation)
    await f.api.setMode(.normal)
    try await f.host.recover()
    #expect(f.host.outcome == .notApplied && f.host.resolution == nil && f.flags.events.count == 1)
    await f.api.setMode(.lostRetirementACK)
    await #expect(throws: GatewayAvatarReportReviewFailure.unavailable) {
        try await f.host.retirePending(saved.intent)
    }
    #expect(
        f.host.pendingOperation?.phase == .retiring && f.host.pendingOperation?.intent == saved.intent
            && f.host.resolution == nil)
    f.host.invalidate()
    f.clock.move(wall: 91_000, monotonic: 91)
    try await f.connect()
    #expect(
        f.host.pendingOperation?.phase == .retiring
            && f.host.pendingOperation?.intent.photoTarget == saved.intent.photoTarget
            && f.host.resolution == nil)
    await f.api.setMode(.normal)
    try await f.host.recover()
    #expect(f.host.outcome == .retired && f.flags.events.count == 3)
    #expect(await f.api.decisions.count == 1)
    #expect(await f.api.retirements == [saved.intent.recovery])
    #expect(await f.api.applied.isEmpty)
    try await f.host.acknowledgeResult(#require(f.host.resolution))
}
@Test @MainActor func avatarReportReviewHostNonterminalRetireReplyCannotReleaseFenceOrBecomeAcknowledged()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let handle = try await f.show()
    await f.api.setMode(.beforeAccept)
    await #expect(throws: GatewayAvatarReportReviewFailure.unavailable) {
        try await f.host.decide(.hidePhoto, presentation: handle)
    }
    let saved = try #require(f.host.pendingOperation)
    await f.api.setMode(.unsafeRetirement)
    await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
        try await f.host.retirePending(saved.intent)
    }
    #expect(f.host.pendingOperation?.phase == .retiring && f.host.pendingOperation?.intent == saved.intent)
    #expect(f.host.resolution == nil && f.flags.events.count == 1)
    #expect(await f.api.decisions.count == 1)
}
@Test @MainActor func avatarReportReviewHostSynchronousPublicationCallbackInvalidationStopsBeforeDecision()
    async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let handle = try await f.show()
    f.flags.onEvent = { event in if case .pending = event { f.flags.parent = false } }
    await #expect(throws: GatewayAvatarReportReviewHostFailure.superseded) {
        try await f.host.decide(.hidePhoto, presentation: handle)
    }
    #expect(await f.api.decisions.isEmpty)
    #expect(f.host.presentation == nil && !f.host.isConnected)
    f.flags.onEvent = nil
    f.flags.parent = true
    try await f.connect()
    #expect(f.host.pendingOperation?.phase == .prepared && f.host.pendingOperation?.intent.photoTarget != nil)
}

private final class ReportedPhotoLastReadStorage: GatewayAvatarReportReviewJournalStorage, @unchecked Sendable
{
    let base = ReportedPhotoJournalMemoryStorage(), gate = ReviewStorageGate()
    private let lock = NSLock()
    private var armed = false, sawDispatchedReadback = false
    func arm() {
        lock.withLock {
            armed = true
            sawDispatchedReadback = false
        }
        gate.arm()
    }
    func read(scope: GatewayAvatarReportReviewScope) throws -> Data? {
        let data = try base.read(scope: scope)
        let dispatched =
            data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["entry"] as? [String: Any] }?["phase"] as? String == "dispatched"
        let stop = lock.withLock {
            guard armed && dispatched else { return false }
            if sawDispatchedReadback {
                armed = false
                return true
            }
            sawDispatchedReadback = true
            return false
        }
        if stop { gate.blockIfArmed() }
        return data
    }
    func write(_ data: Data, scope: GatewayAvatarReportReviewScope) throws {
        try base.write(data, scope: scope)
    }
    func erase(owner: PrivateAccountScope) throws { try base.erase(owner: owner) }
}
@Test @MainActor func avatarReportReviewHostScopeChangeDuringLastJournalReadStopsBeforeAPI() async throws {
    for accountChange in [false, true] {
        let f = try ReportedPhotoReviewHostFixture()
        let storage = ReportedPhotoLastReadStorage()
        let journal = GatewayAvatarReportReviewJournal(storage: storage)
        let host = try GatewayAvatarReportReviewHost(
            api: f.api, configuration: .init(origin: URL(string: f.api.origin)!),
            cloudKit: f.scope.owner.configuration, authorization: f.authorization, journal: journal,
            isEnabled: { f.flags.enabled }, date: { f.clock.date() }, uptime: { f.clock.up() })
        host.setForeground(true)
        try await host.connect { f.flags.parent }
        try await host.refreshQueue()
        try await host.inspect(f.wire.item)
        let shown = try #require(host.presentation)
        #expect(host.material(for: shown)?.image != nil)
        try host.acknowledgeDisplay(shown)
        storage.arm()
        let running = Task { try await host.decide(.hidePhoto, presentation: shown) }
        defer {
            storage.gate.release()
            running.cancel()
            host.invalidate()
        }
        for _ in 0..<5000 {
            if storage.gate.hasEntered() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(storage.gate.hasEntered())
        if accountChange { try f.authorization.select(reviewModeratorB) } else { f.flags.parent = false }
        storage.gate.release()
        await #expect(throws: GatewayAvatarReportReviewHostFailure.superseded) { try await running.value }
        #expect(await f.api.decisions.isEmpty)
        let saved = try #require(await journal.peek(scope: f.scope))
        #expect(saved.phase == .dispatched && saved.intent.photoTarget != nil)
        #expect(host.presentation == nil && !host.isConnected)
    }
}
@Test @MainActor func avatarReportReviewHostMissingPhotoAllowsOnlyDismissAfterReasonDisplay() async throws {
    let f = try ReportedPhotoReviewHostFixture()
    let response = try #require(f.wire.cases["inspect-missing"])
    let (root, _) = try reportedPhotoParts(response)
    let item = try reportedPhotoItem(root)
    let token = try await f.authorization.communityAccessToken(
        for: #require(f.authorization.communityAuthorization))
    let inspection = try await reportedPhotoClient(
        ReportedPhotoHTTPStub(response), clock: f.clock, origin: URL(string: f.api.origin)!
    ).inspect(item, token: token)
    await f.api.setPages([.init(items: [item], next: nil)])
    await f.api.setInspection(inspection)
    try await f.connect()
    try await f.host.refreshQueue()
    try await f.host.inspect(item)
    let shown = try #require(f.host.presentation)
    let material = try #require(f.host.material(for: shown))
    #expect(material.image == nil && !material.reason.isEmpty)
    try f.host.acknowledgeDisplay(shown)
    #expect(f.host.canDecide && !f.host.canHidePhoto)
    await #expect(throws: GatewayAvatarReportReviewFailure.invalidInput) {
        try await f.host.decide(.hidePhoto, presentation: shown)
    }
    #expect(await f.api.decisions.isEmpty)
    try await f.host.decide(.dismiss, presentation: shown)
    #expect(
        f.host.pendingOperation?.intent.photoTarget == nil
            && f.host.pendingOperation?.intent.recovery.verdict == .dismiss)
    try await f.host.acknowledgeResult(#require(f.host.resolution))
}
@Test @MainActor func avatarReportReviewHostRejectsTypedAdapterImageWhoseTargetWasRebound() async throws {
    let f = try ReportedPhotoReviewHostFixture()
    let token = try await f.authorization.communityAccessToken(
        for: #require(f.authorization.communityAuthorization))
    let value = try await reportedPhotoClient(
        ReportedPhotoHTTPStub(f.wire.inspection), clock: f.clock, origin: URL(string: f.api.origin)!
    ).inspect(f.wire.item, token: token)
    let old = value.receipt
    let target = try #require(old.photoTarget)
    let receipt = GatewayAvatarReportReviewReceipt(
        item: old.item, inspectionID: old.inspectionID, contentHash: old.contentHash,
        expiresAtMilliseconds: old.expiresAtMilliseconds, origin: old.origin,
        sessionFingerprint: old.sessionFingerprint, observed: old.observed,
        photoTarget: try .init(
            ownerID: target.ownerID, versionID: UUID().uuidString.lowercased(),
            publicationGeneration: target.publicationGeneration))
    await f.api.setInspection(.init(receipt: receipt, reason: value.reason, avatar: value.avatar))
    try await f.connect()
    try await f.host.refreshQueue()
    await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
        try await f.host.inspect(f.wire.item)
    }
    #expect(f.host.presentation == nil && !f.host.canDecide)
    #expect(await f.api.decisions.isEmpty)
}
@Test @MainActor func avatarReportReviewHostObservedParentActivationAndNativeChangesDoNotResurrectOldHandle()
    async throws
{
    for mode in ["parent", "activation", "icloud", "apple", "account"] {
        let f = try ReportedPhotoReviewHostFixture()
        let shown = try await f.show()
        switch mode {
        case "parent": f.flags.parent = false
        case "activation": f.flags.enabled = false
        case "icloud": f.authorization.cloudName = "other-cloud"
        case "apple":
            try f.authorization.select(
                reviewModeratorA, apple: "other-apple", cloud: "synthetic-review-cloud")
        default: try f.authorization.select(reviewModeratorB)
        }
        #expect(!f.host.isConnected && f.host.material(for: shown) == nil)
        f.flags.parent = true
        f.flags.enabled = true
        try f.authorization.select(
            reviewModeratorA, apple: "synthetic-review-apple", cloud: "synthetic-review-cloud")
        #expect(!f.host.isConnected && f.host.material(for: shown) == nil)
        await #expect(throws: GatewayAvatarReportReviewHostFailure.displayRequired) {
            try await f.host.decide(.hidePhoto, presentation: shown)
        }
        #expect(await f.api.decisions.isEmpty)
        try await f.connect()
        let fresh = try await f.show()
        #expect(fresh != shown && f.host.material(for: fresh)?.image != nil)
        f.host.invalidate()
    }
}
@Test @MainActor func avatarReportReviewHostPageReplacementAndEmptyProgressRemainBounded() async throws {
    for empty in [false, true] {
        let f = try ReportedPhotoReviewHostFixture()
        let first = try GatewayAvatarReportReviewItem(
            reportID: "community-v1-avatarreport-" + String(repeating: "1", count: 64),
            createdAtMilliseconds: f.wire.now, expiresAtMilliseconds: f.wire.now + 2_592_000_000)
        let second = try GatewayAvatarReportReviewItem(
            reportID: "community-v1-avatarreport-" + String(repeating: "2", count: 64),
            createdAtMilliseconds: f.wire.now, expiresAtMilliseconds: f.wire.now + 2_592_000_000)
        let cursor = try GatewayAvatarReportReviewCursor(first.reportID)
        await f.api.setPages([
            .init(items: empty ? [] : [first], next: cursor), .init(items: [second], next: nil),
        ])
        try await f.connect()
        try await f.host.refreshQueue()
        let oldPage = try #require(f.host.page)
        #expect(f.host.queue == (empty ? [] : [first]) && f.host.hasNextPage)
        try await f.host.nextPage(oldPage)
        #expect(f.host.queue == [second] && !f.host.hasNextPage)
        await #expect(throws: GatewayAvatarReportReviewFailure.stale) { try await f.host.nextPage(oldPage) }
        #expect(await f.api.cursors == [nil, cursor])
        f.host.invalidate()
    }
}

private final class ReportedPhotoExpiryNotification: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false
    func mark() { lock.withLock { observed = true } }
    func read() -> Bool { lock.withLock { observed } }
}
@Test @MainActor func avatarReportReviewHostExpiryNotifiesAndDropsReasonAndImageWithoutPolling() async throws
{
    let f = try ReportedPhotoReviewHostFixture()
    let timer = PhotoGate()
    await timer.arm()
    let (fields, image) = try reportedPhotoParts(f.wire.inspection)
    let response = try reportedPhotoFrame(
        fields.merging(["inspectionExpiresAt": f.wire.now + 1000]) { _, n in n }, image: image)
    let token = try await f.authorization.communityAccessToken(
        for: #require(f.authorization.communityAuthorization))
    let inspection = try await reportedPhotoClient(
        ReportedPhotoHTTPStub(response), clock: f.clock, origin: URL(string: f.api.origin)!
    ).inspect(f.wire.item, token: token)
    await f.api.setInspection(inspection)
    f.host.inspectionDeadlineWait = { milliseconds in
        #expect(milliseconds == 1000)
        await timer.enter()
    }
    let shown = try await f.show()
    let notification = ReportedPhotoExpiryNotification()
    withObservationTracking {
        _ = f.host.presentationRevision
    } onChange: {
        notification.mark()
    }
    try await timer.wait()
    f.clock.move(wall: 1000, monotonic: 1)
    await timer.release()
    for _ in 0..<5000 {
        if notification.read() { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(
        notification.read() && f.host.presentation == nil && f.host.material(for: shown) == nil
            && !f.host.canDecide)
    #expect(await f.api.calls == ["queue", "inspect"])
    f.host.invalidate()
}
