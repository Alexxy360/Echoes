import Foundation
import Testing

@testable import EchoesCloudKit

@Test @MainActor
func reportReviewRetirementJournalKeepsNotAppliedPendingAcrossRestartAndRequiresTerminalFence() async throws {
    let storage = ReportJournalMemoryStorage()
    let scope = try reportStoreScope()
    let journal = GatewayReportReviewJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let intent = try reportStoreIntent()
    let initial = try await journal.prepare(intent, lease: lease)
    let observed = try await journal.resolve(
        initial, result: .init(intent: intent, outcome: .notApplied), lease: lease)
    #expect(observed.phase == .dispatched)
    await #expect(throws: GatewayReportReviewJournalFailure.invalidTransition) {
        try await journal.acknowledge(observed, lease: lease)
    }
    let retiring = try await journal.retiring(observed, lease: lease)
    #expect(retiring.phase == .retiring && retiring.intent == intent)
    #expect(try await journal.retiring(retiring, lease: lease) == retiring)
    let anotherRead = try await journal.resolve(
        retiring, result: .init(intent: intent, outcome: .notApplied), lease: lease)
    #expect(anotherRead.phase == .retiring)
    let reopened = GatewayReportReviewJournal(storage: storage)
    let replacement = try await reopened.open(scope: scope)
    let saved = try #require(await reopened.pending(lease: replacement))
    #expect(saved == anotherRead)
    await #expect(throws: GatewayReportReviewJournalFailure.pendingExists) {
        try await reopened.prepare(intent, lease: replacement)
    }
    let sealed = try await reopened.resolve(
        saved, result: .init(intent: intent, outcome: .retired), lease: replacement)
    for weakening in [GatewayReportReviewOutcome.notApplied, .superseded] {
        await #expect(throws: GatewayReportReviewJournalFailure.invalidTransition) {
            try await reopened.resolve(
                sealed, result: .init(intent: intent, outcome: weakening), lease: replacement)
        }
    }
    try await reopened.acknowledge(sealed, lease: replacement)
    #expect(try await reopened.pending(lease: replacement) == nil)
}

@Test @MainActor
func reportReviewRetirementMigratesLegacyResolvedNotAppliedWithoutDroppingNonceOrRewritingRead() async throws
{
    let storage = ReportJournalMemoryStorage()
    let scope = try reportStoreScope()
    let journal = GatewayReportReviewJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let intent = try reportStoreIntent()
    let prepared = try await journal.prepare(intent, lease: lease)
    var root = try #require(
        JSONSerialization.jsonObject(with: storage.records[scope.digest]!) as? [String: Any])
    var entry = try #require(root["entry"] as? [String: Any])
    entry["phase"] = "resolved"
    entry["outcome"] = "not-applied"
    root["entry"] = entry
    let legacy = try JSONSerialization.data(withJSONObject: root)
    storage.records[scope.digest] = legacy
    let writes = storage.writes
    let restored = try #require(await journal.peek(scope: scope))
    #expect(
        restored.intent == intent && restored.phase == .dispatched && restored.revision == prepared.revision)
    #expect(storage.writes == writes && storage.records[scope.digest] == legacy)
    await #expect(throws: GatewayReportReviewJournalFailure.invalidTransition) {
        try await journal.acknowledge(restored, lease: lease)
    }
    let retiring = try await journal.retiring(restored, lease: lease)
    #expect(retiring.phase == .retiring && retiring.intent == intent)
}

@Test @MainActor func reportReviewRetirementAmbiguousStorageFailurePreservesIntentAndNeverClaimsServerFence()
    async throws
{
    for after in [false, true] {
        let storage = ReportJournalMemoryStorage()
        let scope = try reportStoreScope()
        let journal = GatewayReportReviewJournal(storage: storage)
        let lease = try await journal.open(scope: scope)
        let intent = try reportStoreIntent()
        let entry = try await journal.prepare(intent, lease: lease)
        storage.failAt = storage.writes + 1
        storage.afterWrite = after
        await #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
            try await journal.retiring(entry, lease: lease)
        }
        storage.failAt = nil
        let second = GatewayReportReviewJournal(storage: storage)
        let next = try await second.open(scope: scope)
        let pending = try #require(await second.pending(lease: next))
        #expect(
            pending.intent == intent && pending.phase == (after ? .retiring : .prepared)
                && pending.outcome == nil)
    }
}

@MainActor private func uncertainReport(_ f: ReportHostFixture) async throws
    -> GatewayReportReviewRecoveryIntent
{
    let shown = try await f.show()
    await f.api.setMode(.beforeAccept)
    await #expect(throws: GatewayReportReviewFailure.unavailable) {
        try await f.host.decide(.hideMessage, presentation: shown)
    }
    return try #require(f.host.pendingOperation?.intent)
}

@Test @MainActor
func reportReviewRetirementHostPersistsBeforeNetworkKeepsExactNonceAndOnlyThenAllowsAcknowledgement()
    async throws
{
    let f = try ReportHostFixture()
    let intent = try await uncertainReport(f)
    try await f.host.recover()
    #expect(f.host.outcome == .notApplied && f.host.resolution == nil)
    await f.api.setMode(.normal)
    await f.api.pause("retire")
    let running = Task { try await f.host.retirePending(intent) }
    try await f.api.gate.wait()
    let stored = try #require(await f.journal.peek(scope: f.scope))
    #expect(stored.phase == .retiring && stored.intent == intent && f.host.isBusy)
    await #expect(throws: GatewayReportReviewJournalFailure.invalidTransition) {
        try await f.host.retirePending(intent)
    }
    await f.api.gate.release()
    try await running.value
    #expect(f.host.outcome == .retired && f.host.pendingOperation?.phase == .resolved)
    #expect(await f.api.retirements == [intent])
    #expect(await f.api.decisions.count == 1)
    let result = try #require(f.host.resolution)
    f.host.invalidate()
    try await f.connect()
    #expect(f.host.outcome == .retired && f.host.resolution != nil)
    await #expect(throws: GatewayReportReviewJournalFailure.invalidTransition) {
        try await f.host.acknowledgeResult(result)
    }
    try await f.host.acknowledgeResult(#require(f.host.resolution))
    #expect(f.host.pendingOperation == nil)
}

@Test @MainActor
func reportReviewRetirementLostACKRestartsInRetiringAndReadOnlyRecoveryNeverResendsEitherOperation()
    async throws
{
    let f = try ReportHostFixture()
    let intent = try await uncertainReport(f)
    await f.api.setMode(.lostRetirementACK)
    await #expect(throws: GatewayReportReviewFailure.unavailable) { try await f.host.retirePending(intent) }
    #expect(f.host.pendingOperation?.phase == .retiring && f.host.resolution == nil)
    f.host.invalidate()
    try await f.connect()
    #expect(f.host.pendingOperation?.intent == intent && f.host.pendingOperation?.phase == .retiring)
    try await f.host.recover()
    #expect(f.host.outcome == .retired)
    #expect(await f.api.retirements == [intent])
    #expect(await f.api.recoveries == [intent])
    #expect(await f.api.decisions.count == 1)
}

@Test @MainActor func reportReviewRetirementRejectsNonterminalReplyAndWrongCapturedIntent() async throws {
    let f = try ReportHostFixture()
    let intent = try await uncertainReport(f)
    let foreign = try GatewayReportReviewRecoveryIntent(
        reportID: intent.reportID, decisionID: UUID().uuidString.lowercased(), verdict: intent.verdict,
        contentHash: intent.contentHash)
    await #expect(throws: GatewayReportReviewJournalFailure.invalidTransition) {
        try await f.host.retirePending(foreign)
    }
    #expect(await f.api.retirements.isEmpty)
    await f.api.setMode(.unsafeRetirement)
    await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
        try await f.host.retirePending(intent)
    }
    #expect(f.host.pendingOperation?.phase == .retiring && f.host.resolution == nil && f.host.outcome == nil)
}

@Test @MainActor func reportReviewRetirementNeverSendsBeforeDurableStorageAndDoesNotCrossNativeTokenSwitch()
    async throws
{
    for storageFailure in [true, false] {
        let f = try ReportHostFixture()
        let intent = try await uncertainReport(f)
        if storageFailure {
            f.storage.failAt = f.storage.writes + 1
        } else {
            await f.authorization.gate.arm()
        }
        let running = Task { try await f.host.retirePending(intent) }
        if !storageFailure {
            try await f.authorization.gate.wait()
            try f.authorization.select(reviewModeratorB)
            await f.authorization.gate.release()
        }
        do {
            try await running.value
            Issue.record("Expected fenced retirement")
        } catch {
            #expect(
                storageFailure
                    ? error as? GatewayReportReviewJournalFailure == .unavailable
                    : error as? GatewayReportReviewHostFailure == .superseded)
        }
        #expect(await f.api.retirements.isEmpty)
    }
}

@Test @MainActor func reportReviewRetirementLateACKCannotRestoreAcrossSceneAccountParentOrDeletion()
    async throws
{
    for kind in ["scene", "account", "parent", "deletion", "activation"] {
        let f = try ReportHostFixture()
        let intent = try await uncertainReport(f)
        await f.api.setMode(.normal)
        await f.api.pause("retire")
        let running = Task { try await f.host.retirePending(intent) }
        try await f.api.gate.wait()
        switch kind {
        case "scene": f.host.setForeground(false)
        case "account": try f.authorization.select(reviewModeratorB)
        case "parent": f.flags.parent = false
        case "deletion":
            try f.journal.fenceForAccountDeletion(
                binding: f.scope.binding, accountID: f.scope.owner.accountID)
        default: f.flags.enabled = false
        }
        #expect(f.host.isBusy && f.host.resolution == nil && f.host.outcome == nil)
        await f.api.gate.release()
        do {
            try await running.value
            Issue.record("Expected late ACK rejection")
        } catch {
            #expect(error as? GatewayReportReviewHostFailure == .superseded)
        }
        #expect(f.host.resolution == nil && f.host.outcome == nil)
        #expect(await f.api.retirements == [intent])
        #expect(await f.api.decisions.count == 1)
        f.host.invalidate()
    }
}

@Test func reportReviewRetirementHTTPUsesConcreteRuntimeTerminalRepliesAndRejectsReadOnlyAbsence()
    async throws
{
    let f = try ReportWireFixture()
    let clock = ReviewClock(f.now)
    for label in ["retire-pending", "retire-already-confirmed"] {
        let response = try #require(f.cases[label])
        let body = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let intent = try GatewayReportReviewRecoveryIntent(
            reportID: #require(body["reportID"] as? String),
            decisionID: #require(body["decisionID"] as? String), verdict: .hideMessage,
            contentHash: #require(body["contentHash"] as? String))
        let stub = ReportHTTPStub(response)
        let client = try reportClient(stub, clock: clock)
        let result = try await client.retire(intent, token: reviewBearer)
        #expect(result.outcome.isTerminal)
        #expect(
            result.outcome
                == (label == "retire-pending" ? .retired : .confirmed(revision: body["revision"] as! String)))
        let request = try #require(await stub.requests.first)
        let wire = try GatewayReportReviewOperation.retire(intent).wire()
        #expect(request.url?.path == "/v1/moderation/reports/retire" && request.httpBody == wire)
    }
    let client = try reportClient(ReportHTTPStub(f.cases["recover-not-applied"]!), clock: clock)
    await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
        try await client.retire(f.recovery, token: reviewBearer)
    }
    let invalid = try reportBody(f.cases["retire-pending"]!, ["revision": UUID().uuidString.lowercased()])
    let intent = try GatewayReportReviewRecoveryIntent(
        reportID: f.item.reportID,
        decisionID: #require(
            (JSONSerialization.jsonObject(with: invalid.body) as? [String: Any])?["decisionID"] as? String),
        verdict: .hideMessage, contentHash: f.recovery.contentHash)
    await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
        try await reportClient(ReportHTTPStub(invalid), clock: clock).retire(intent, token: reviewBearer)
    }
}
