import Foundation
import Testing

@testable import EchoesCloudKit

actor ReportHostAPI: GatewayReportReviewAPI {
    nonisolated let origin = "https://review-host.example.invalid"
    enum Mode: Sendable {
        case normal, denied, signIn, unknown, lostACK, beforeAccept, superseded, lostRetirementACK,
            unsafeRetirement
    }
    var mode: Mode = .normal
    var calls: [String] = []
    var decisions: [GatewayReportReviewDecisionIntent] = []
    var recoveries: [GatewayReportReviewRecoveryIntent] = []
    var applied: [String: String] = [:]
    var retired: [String: GatewayReportReviewRecoveryIntent] = [:]
    var retirements: [GatewayReportReviewRecoveryIntent] = []
    var pages: [GatewayReportReviewPage] = []
    var cursors: [GatewayReportReviewCursor?] = []
    var inspectionOverride: GatewayReportReviewInspection?
    let fixture: ReportWireFixture
    let clock: ReviewClock
    let gate = PhotoGate()
    private var pauseAction = ""
    var beforeDecision: (@Sendable (GatewayReportReviewDecisionIntent) async throws -> Void)?
    init(fixture: ReportWireFixture, clock: ReviewClock) {
        self.fixture = fixture
        self.clock = clock
    }
    func setMode(_ value: Mode) { mode = value }
    func setPages(_ values: [GatewayReportReviewPage]) { pages = values }
    func setInspection(_ value: GatewayReportReviewInspection) { inspectionOverride = value }
    func pause(_ action: String) async {
        pauseAction = action
        await gate.arm()
    }
    func before(_ callback: @escaping @Sendable (GatewayReportReviewDecisionIntent) async throws -> Void) {
        beforeDecision = callback
    }
    private func begin(_ action: String) throws {
        calls.append(action)
        switch mode {
        case .denied: throw GatewayReportReviewFailure.denied
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
    func queue(after: GatewayReportReviewCursor?, token: GatewaySecret) async throws
        -> GatewayReportReviewPage
    {
        try begin("queue")
        cursors.append(after)
        let value: GatewayReportReviewPage
        if !pages.isEmpty {
            value = pages.removeFirst()
        } else {
            value = try await reportClient(
                ReportHTTPStub(fixture.queue), clock: clock, origin: URL(string: origin)!
            ).queue(after: after, token: token)
        }
        await hold("queue")
        return value
    }
    func inspect(_ item: GatewayReportReviewItem, token: GatewaySecret) async throws
        -> GatewayReportReviewInspection
    {
        try begin("inspect")
        let value: GatewayReportReviewInspection
        if let inspectionOverride {
            value = inspectionOverride
        } else {
            value = try await reportClient(
                ReportHTTPStub(fixture.inspection), clock: clock, origin: URL(string: origin)!
            ).inspect(item, token: token)
        }
        await hold("inspect")
        return value
    }
    func decide(_ intent: GatewayReportReviewDecisionIntent, token: GatewaySecret) async throws
        -> GatewayReportReviewDecisionResult
    {
        try begin("decide")
        decisions.append(intent)
        let callback = beforeDecision
        beforeDecision = nil
        try await callback?(intent)
        if retired[intent.decisionID] != nil { throw GatewayReportReviewFailure.stale }
        if mode == .beforeAccept { throw GatewayReportReviewFailure.unavailable }
        let revision = UUID().uuidString.lowercased()
        applied[intent.decisionID] = revision
        await hold("decide")
        if mode == .lostACK { throw GatewayReportReviewFailure.unavailable }
        return .init(intent: intent, revision: revision)
    }
    func recover(_ intent: GatewayReportReviewRecoveryIntent, token: GatewaySecret) async throws
        -> GatewayReportReviewRecoveryResult
    {
        try begin("recover")
        recoveries.append(intent)
        let outcome: GatewayReportReviewOutcome =
            mode == .superseded
            ? .superseded
            : retired[intent.decisionID] == intent
                ? .retired : applied[intent.decisionID].map { .confirmed(revision: $0) } ?? .notApplied
        await hold("recover")
        return .init(intent: intent, outcome: outcome)
    }
    func retire(_ intent: GatewayReportReviewRecoveryIntent, token: GatewaySecret) async throws
        -> GatewayReportReviewRecoveryResult
    {
        try begin("retire")
        retirements.append(intent)
        if mode == .unsafeRetirement { return .init(intent: intent, outcome: .notApplied) }
        let outcome: GatewayReportReviewOutcome
        if let revision = applied[intent.decisionID] {
            outcome = .confirmed(revision: revision)
        } else if mode == .superseded {
            outcome = .superseded
        } else {
            retired[intent.decisionID] = intent
            outcome = .retired
        }
        await hold("retire")
        if mode == .lostRetirementACK { throw GatewayReportReviewFailure.unavailable }
        return .init(intent: intent, outcome: outcome)
    }
}
@MainActor final class ReportHostFlags {
    var enabled = true
    var parent = true
}
@MainActor struct ReportHostFixture {
    let wire: ReportWireFixture
    let clock: ReviewClock
    let flags = ReportHostFlags()
    let authorization: PhotoAuthorization
    let storage: ReportJournalMemoryStorage
    let journal: GatewayReportReviewJournal
    let scope: GatewayReportReviewScope
    let api: ReportHostAPI
    let host: GatewayReportReviewHost
    init(
        storage: ReportJournalMemoryStorage? = nil, api: ReportHostAPI? = nil
    ) throws {
        wire = try .init()
        clock = ReviewClock(wire.now)
        authorization = try .init()
        try authorization.select(
            reviewModeratorA, apple: "synthetic-review-apple", cloud: "synthetic-review-cloud")
        self.storage = storage ?? ReportJournalMemoryStorage()
        journal = .init(storage: self.storage)
        scope = try reportStoreScope()
        self.api = api ?? ReportHostAPI(fixture: wire, clock: clock)
        host = try GatewayReportReviewHost(
            api: self.api,
            configuration: .init(origin: URL(string: self.api.origin)!), cloudKit: scope.owner.configuration,
            authorization: authorization, journal: journal, isEnabled: { [flags] in flags.enabled },
            date: { [clock] in clock.date() }, uptime: { [clock] in clock.up() })
        host.setForeground(true)
    }
    func connect() async throws { try await host.connect { flags.parent } }
    func show(acknowledge: Bool = true) async throws -> GatewayReportReviewPresentation {
        if !host.isConnected { try await connect() }
        try await host.refreshQueue()
        try await host.inspect(wire.item)
        let shown = try #require(host.presentation)
        #expect(host.material(for: shown) != nil)
        if acknowledge { try host.acknowledgeDisplay(shown) }
        return shown
    }
}

@Test @MainActor func reportReviewHostRequiresActualCurrentDisplayAndPersistsDispatchedIntentBeforeAPI()
    async throws
{
    let f = try ReportHostFixture()
    let shown = try await f.show(acknowledge: false)
    #expect(!f.host.canDecide)
    await #expect(throws: GatewayReportReviewHostFailure.displayRequired) {
        try await f.host.decide(.hideMessage, presentation: shown)
    }
    #expect(await f.api.decisions.isEmpty)
    try f.host.acknowledgeDisplay(shown)
    await f.api.before { intent in
        await MainActor.run {
            #expect(f.host.pendingOperation?.phase == .dispatched)
            #expect(f.host.pendingOperation?.intent == GatewayReportReviewRecoveryIntent(decision: intent))
            #expect(f.host.presentation == nil && f.host.material(for: shown) == nil)
        }
    }
    try await f.host.decide(.hideMessage, presentation: shown)
    #expect(f.host.pendingOperation?.phase == .resolved && f.host.outcome != nil)
    #expect(await f.api.calls == ["queue", "inspect", "decide"])
    let result = try #require(f.host.resolution)
    try await f.host.acknowledgeResult(result)
    #expect(f.host.pendingOperation == nil && f.host.outcome == nil && f.host.queue.isEmpty)
    await #expect(throws: GatewayReportReviewHostFailure.displayRequired) {
        try await f.host.decide(.dismiss, presentation: shown)
    }
}

@Test @MainActor func reportReviewHostLostACKSurvivesRestartAndOnlyReadsExactSavedDecision() async throws {
    let f = try ReportHostFixture()
    let shown = try await f.show()
    await f.api.setMode(.lostACK)
    await #expect(throws: GatewayReportReviewFailure.unavailable) {
        try await f.host.decide(.hideMessage, presentation: shown)
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

@Test @MainActor func reportReviewHostPendingResultBlocksNewInspectionQueueAndReplacementVerdict()
    async throws
{
    let f = try ReportHostFixture()
    let shown = try await f.show()
    await f.api.setMode(.lostACK)
    await #expect(throws: GatewayReportReviewFailure.unavailable) {
        try await f.host.decide(.hideMessage, presentation: shown)
    }
    let saved = f.host.pendingOperation
    await #expect(throws: GatewayReportReviewJournalFailure.pendingExists) { try await f.host.refreshQueue() }
    await #expect(throws: GatewayReportReviewJournalFailure.pendingExists) {
        try await f.host.inspect(f.wire.item)
    }
    await #expect(throws: GatewayReportReviewHostFailure.displayRequired) {
        try await f.host.decide(.dismiss, presentation: shown)
    }
    #expect(f.host.pendingOperation == saved && f.host.isConnected)
    #expect(await f.api.decisions.count == 1)
}

@Test @MainActor func reportReviewHostOnlyTerminalOutcomeCanBeAcknowledged() async throws {
    for mode in [ReportHostAPI.Mode.beforeAccept, .superseded] {
        let f = try ReportHostFixture()
        let shown = try await f.show()
        await f.api.setMode(.beforeAccept)
        await #expect(throws: GatewayReportReviewFailure.unavailable) {
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

@Test @MainActor func reportReviewHostOldPresentationCannotAuthorizeFreshInspectionOrExpiredText()
    async throws
{
    let f = try ReportHostFixture()
    let old = try await f.show()
    try await f.host.inspect(f.wire.item)
    let fresh = try #require(f.host.presentation)
    #expect(old != fresh && f.host.material(for: old) == nil && !f.host.canDecide)
    #expect(throws: GatewayReportReviewHostFailure.displayRequired) { try f.host.acknowledgeDisplay(old) }
    try f.host.acknowledgeDisplay(fresh)
    #expect(f.host.canDecide)
    f.clock.move(monotonic: 90)
    #expect(f.host.material(for: fresh) == nil && f.host.presentation == nil && !f.host.canDecide)
    f.host.expirePresentation()
    await #expect(throws: GatewayReportReviewHostFailure.displayRequired) {
        try await f.host.decide(.hideMessage, presentation: fresh)
    }
    #expect(await f.api.decisions.isEmpty)
}

@Test @MainActor func reportReviewHostBackgroundParentAndNativeIdentityFenceEveryGetter() async throws {
    for mode in ["background", "parent", "account", "icloud", "apple", "activation"] {
        let f = try ReportHostFixture()
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
        await #expect(throws: GatewayReportReviewHostFailure.displayRequired) {
            try await f.host.decide(.hideMessage, presentation: shown)
        }
        #expect(await f.api.decisions.isEmpty)
        f.host.invalidate()
    }
}

@Test @MainActor func reportReviewHostLateInspectionKeepsUnsettledSlotAndCannotRestoreAfterBackground()
    async throws
{
    let f = try ReportHostFixture()
    try await f.connect()
    try await f.host.refreshQueue()
    await f.api.pause("inspect")
    let task = Task { try await f.host.inspect(f.wire.item) }
    try await f.api.gate.wait()
    f.host.setForeground(false)
    f.host.setForeground(true)
    #expect(f.host.isBusy && f.host.presentation == nil)
    await #expect(throws: GatewayReportReviewFailure.busy) { try await f.connect() }
    await f.api.gate.release()
    await #expect(throws: GatewayReportReviewHostFailure.superseded) { try await task.value }
    #expect(!f.host.isBusy && f.host.presentation == nil && !f.host.isConnected)
    try await f.connect()
    #expect(f.host.presentation == nil)
}

@Test @MainActor func reportReviewHostAccountSwapDuringNativeTokenStopsBeforeInspectAndPreservesNewAccount()
    async throws
{
    let f = try ReportHostFixture()
    try await f.connect()
    try await f.host.refreshQueue()
    await f.authorization.gate.arm()
    let task = Task { try await f.host.inspect(f.wire.item) }
    try await f.authorization.gate.wait()
    try f.authorization.select(reviewModeratorB)
    await f.authorization.gate.release()
    await #expect(throws: GatewayReportReviewHostFailure.superseded) { try await task.value }
    #expect(await f.api.calls == ["queue"])
    #expect(
        f.authorization.communityAuthorization?.identity.accountID == reviewModeratorB
            && f.authorization.rejected == 0)
    f.host.invalidate()
}

@Test @MainActor func reportReviewHostLateDecisionRemainsDurableButCannotCrossAccountOrScene() async throws {
    let f = try ReportHostFixture()
    let shown = try await f.show()
    await f.api.pause("decide")
    let task = Task { try await f.host.decide(.hideMessage, presentation: shown) }
    try await f.api.gate.wait()
    f.host.setForeground(false)
    #expect(f.host.isBusy && f.host.outcome == nil && f.host.pendingOperation == nil)
    await f.api.gate.release()
    await #expect(throws: GatewayReportReviewHostFailure.superseded) { try await task.value }
    f.host.setForeground(true)
    try await f.connect()
    #expect(f.host.pendingOperation?.phase == .dispatched && f.host.outcome == nil)
    try await f.host.recover()
    guard case .confirmed = f.host.outcome else {
        Issue.record("Expected preserved decision")
        return
    }
}

@Test @MainActor func reportReviewHostRoleDenialDoesNotSignOutButInvalidSessionDoes() async throws {
    for mode in [ReportHostAPI.Mode.denied, .signIn, .unknown] {
        let f = try ReportHostFixture()
        try await f.connect()
        await f.api.setMode(mode)
        do {
            try await f.host.refreshQueue()
            Issue.record("Expected failure")
        } catch {
            #expect(!error.localizedDescription.contains("PRIVATE"))
            if mode == .denied {
                #expect(error as? GatewayReportReviewFailure == .denied && f.host.isRoleDenied)
            } else if mode == .signIn {
                #expect(error as? GatewayFailure == .signInRequired && !f.host.isConnected)
            } else {
                #expect(error as? GatewayReportReviewFailure == .unavailable)
            }
        }
        #expect(f.authorization.rejected == (mode == .signIn ? 1 : 0))
        f.host.invalidate()
    }
}

@Test @MainActor func reportReviewHostStorageFailureBeforeDispatchNeverSendsAndAmbiguousIntentCanBeRecovered()
    async throws
{
    for phase in ["prepare", "dispatch", "resolve"] {
        let f = try ReportHostFixture()
        let shown = try await f.show()
        f.storage.failAt = f.storage.writes + (phase == "prepare" ? 1 : phase == "dispatch" ? 2 : 3)
        f.storage.afterWrite = true
        await #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
            try await f.host.decide(.hideMessage, presentation: shown)
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

@Test @MainActor func reportReviewHostDeletionFencesLateWorkAndNeverRestoresErasedJournal() async throws {
    let f = try ReportHostFixture()
    let shown = try await f.show()
    await f.api.pause("decide")
    let task = Task { try await f.host.decide(.hideMessage, presentation: shown) }
    try await f.api.gate.wait()
    f.host.invalidate()
    try f.journal.fenceForAccountDeletion(binding: f.scope.binding, accountID: reviewModeratorA)
    try await f.journal.erase(owner: f.scope.owner)
    await f.api.gate.release()
    await #expect(throws: GatewayReportReviewHostFailure.superseded) { try await task.value }
    #expect(f.storage.records.isEmpty && f.host.outcome == nil)
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) { try await f.connect() }
}

@Test @MainActor func reportReviewHostRestoredTerminalRecordCreatesFreshHandleAndRejectsOldAcknowledgement()
    async throws
{
    let f = try ReportHostFixture()
    let shown = try await f.show()
    try await f.host.decide(.hideMessage, presentation: shown)
    let old = try #require(f.host.resolution)
    f.host.invalidate()
    try await f.connect()
    #expect(f.host.pendingOperation?.phase == .resolved && f.host.resolution != nil && f.host.outcome != nil)
    await #expect(throws: GatewayReportReviewJournalFailure.invalidTransition) {
        try await f.host.acknowledgeResult(old)
    }
    try await f.host.recover()
    await #expect(throws: GatewayReportReviewJournalFailure.invalidTransition) {
        try await f.host.acknowledgeResult(old)
    }
    try await f.host.acknowledgeResult(#require(f.host.resolution))
}

@Test @MainActor func reportReviewHostReadsConcreteServerRecoveryIntoRealJournalWithoutAnyDecision()
    async throws
{
    let f = try ReportHostFixture()
    let wire = try ReportWireFixture()
    for label in ["recover-not-applied", "recover-confirmed"] {
        let journal = GatewayReportReviewJournal(storage: ReportJournalMemoryStorage())
        let lease = try await journal.open(scope: f.scope)
        _ = try await journal.prepare(wire.recovery, lease: lease)
        let client = try reportClient(
            ReportHTTPStub(wire.cases[label]!), clock: f.clock, origin: URL(string: f.api.origin)!)
        let host = try GatewayReportReviewHost(
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

@Test @MainActor func reportReviewHostJournalFenceAloneImmediatelyHidesTextAndStopsDecisions() async throws {
    let f = try ReportHostFixture()
    let shown = try await f.show()
    try f.journal.fenceForAccountDeletion(binding: f.scope.binding, accountID: reviewModeratorA)
    #expect(!f.host.isConnected && f.host.presentation == nil && f.host.material(for: shown) == nil)
    await #expect(throws: GatewayReportReviewHostFailure.displayRequired) {
        try await f.host.decide(.hideMessage, presentation: shown)
    }
    #expect(await f.api.decisions.isEmpty)
    f.host.invalidate()
}

@Test @MainActor func reportReviewHostReplacingSharedJournalLeaseRevokesOldDisplayWithoutAwait() async throws
{
    let f = try ReportHostFixture()
    let shown = try await f.show()
    _ = try await f.journal.open(scope: f.scope)
    #expect(!f.host.isConnected && f.host.material(for: shown) == nil && !f.host.canDecide)
    f.host.invalidate()
}

@Test @MainActor func reportReviewHostAmbiguousAcknowledgementForcesReopenWithoutNewDecision() async throws {
    for afterWrite in [false, true] {
        let f = try ReportHostFixture()
        let shown = try await f.show()
        try await f.host.decide(.hideMessage, presentation: shown)
        let result = try #require(f.host.resolution)
        f.storage.failAt = f.storage.writes + 1
        f.storage.afterWrite = afterWrite
        await #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
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

@MainActor private func waitForReportStorage(_ storage: ReportJournalMemoryStorage) async throws {
    for _ in 0..<5000 {
        if storage.gate.hasEntered() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayReportReviewFailure.unavailable
}
@Test @MainActor func reportReviewHostStorageRunsOffMainThreadAndNativeScopeStillFencesDuringWrite()
    async throws
{
    let f = try ReportHostFixture()
    let shown = try await f.show()
    f.storage.gate.arm()
    let task = Task { try await f.host.decide(.hideMessage, presentation: shown) }
    defer {
        f.storage.gate.release()
        task.cancel()
    }
    try await waitForReportStorage(f.storage)
    #expect(f.host.isBusy && f.host.presentation == nil)
    f.authorization.cloudName = "other-cloud"
    #expect(!f.host.isConnected)
    f.storage.gate.release()
    await #expect(throws: GatewayReportReviewHostFailure.superseded) { try await task.value }
    #expect(await f.api.decisions.isEmpty)
    #expect(!f.storage.mainThreadIO)
    f.host.invalidate()
}
@Test @MainActor func reportReviewHostPausedStorageCannotRestoreAfterDeletionAndOldQueuedWrite() async throws
{
    let f = try ReportHostFixture()
    let shown = try await f.show()
    f.storage.gate.arm()
    let task = Task { try await f.host.decide(.hideMessage, presentation: shown) }
    defer {
        f.storage.gate.release()
        task.cancel()
    }
    try await waitForReportStorage(f.storage)
    f.host.invalidate()
    try f.journal.fenceForAccountDeletion(binding: f.scope.binding, accountID: reviewModeratorA)
    let erase = Task { try await f.journal.erase(owner: f.scope.owner) }
    f.storage.gate.release()
    do {
        try await task.value
        Issue.record("Old write must not dispatch")
    } catch {
        #expect(
            error is GatewayReportReviewJournalFailure || error is GatewayReportReviewHostFailure
                || error as? GatewayFailure == .cancelled)
    }
    try await erase.value
    #expect(f.storage.records.isEmpty && !f.storage.mainThreadIO)
    #expect(await f.api.decisions.isEmpty)
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) { try await f.connect() }
}

@Test @MainActor
func reportReviewHostExplicitCancellationDuringStoragePreservesUnknownIntentAndRequiresReopen() async throws {
    let f = try ReportHostFixture()
    let shown = try await f.show()
    f.storage.gate.arm()
    let task = Task { try await f.host.decide(.hideMessage, presentation: shown) }
    defer {
        f.storage.gate.release()
        task.cancel()
    }
    try await waitForReportStorage(f.storage)
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
