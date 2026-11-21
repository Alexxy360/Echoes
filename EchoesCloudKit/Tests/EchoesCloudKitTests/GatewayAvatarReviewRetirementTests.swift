import Foundation
import Testing

@testable import EchoesCloudKit

@Test @MainActor
func avatarReviewRetirementJournalKeepsNotAppliedPendingAcrossRestartAndRequiresTerminalFence() async throws {
    let storage = ReviewMemoryStorage()
    let scope = try reviewStoreScope()
    let journal = GatewayAvatarReviewJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let intent = try reviewStoreIntent()
    let initial = try await journal.prepare(intent, lease: lease)
    let observed = try await journal.resolve(
        initial, result: .init(intent: intent, outcome: .notApplied), lease: lease)
    #expect(observed.phase == .dispatched)
    await #expect(throws: GatewayAvatarReviewJournalFailure.invalidTransition) {
        try await journal.acknowledge(observed, lease: lease)
    }
    let retiring = try await journal.retiring(observed, lease: lease)
    #expect(retiring.phase == .retiring && retiring.intent == intent)
    #expect(try await journal.retiring(retiring, lease: lease) == retiring)
    let anotherRead = try await journal.resolve(
        retiring, result: .init(intent: intent, outcome: .notApplied), lease: lease)
    #expect(anotherRead.phase == .retiring)
    let reopened = GatewayAvatarReviewJournal(storage: storage)
    let replacement = try await reopened.open(scope: scope)
    let saved = try #require(await reopened.pending(lease: replacement))
    #expect(saved == anotherRead)
    await #expect(throws: GatewayAvatarReviewJournalFailure.pendingExists) {
        try await reopened.prepare(intent, lease: replacement)
    }
    let sealed = try await reopened.resolve(
        saved, result: .init(intent: intent, outcome: .retired), lease: replacement)
    for weakening in [GatewayAvatarReviewOutcome.notApplied, .superseded] {
        await #expect(throws: GatewayAvatarReviewJournalFailure.invalidTransition) {
            try await reopened.resolve(
                sealed, result: .init(intent: intent, outcome: weakening), lease: replacement)
        }
    }
    try await reopened.acknowledge(sealed, lease: replacement)
    #expect(try await reopened.pending(lease: replacement) == nil)
}

@Test @MainActor
func avatarReviewRetirementMigratesLegacyResolvedNotAppliedWithoutDroppingNonceOrRewritingRead() async throws
{
    let storage = ReviewMemoryStorage()
    let scope = try reviewStoreScope()
    let journal = GatewayAvatarReviewJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let intent = try reviewStoreIntent()
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
    await #expect(throws: GatewayAvatarReviewJournalFailure.invalidTransition) {
        try await journal.acknowledge(restored, lease: lease)
    }
    let retiring = try await journal.retiring(restored, lease: lease)
    #expect(retiring.phase == .retiring && retiring.intent == intent)
}

@Test @MainActor func avatarReviewRetirementAmbiguousStorageFailurePreservesIntentAndNeverClaimsServerFence()
    async throws
{
    for after in [false, true] {
        let storage = ReviewMemoryStorage()
        let scope = try reviewStoreScope()
        let journal = GatewayAvatarReviewJournal(storage: storage)
        let lease = try await journal.open(scope: scope)
        let intent = try reviewStoreIntent()
        let entry = try await journal.prepare(intent, lease: lease)
        storage.failAt = storage.writes + 1
        storage.afterWrite = after
        await #expect(throws: GatewayAvatarReviewJournalFailure.unavailable) {
            try await journal.retiring(entry, lease: lease)
        }
        storage.failAt = nil
        let second = GatewayAvatarReviewJournal(storage: storage)
        let next = try await second.open(scope: scope)
        let pending = try #require(await second.pending(lease: next))
        #expect(
            pending.intent == intent && pending.phase == (after ? .retiring : .prepared)
                && pending.outcome == nil)
    }
}

@MainActor private func uncertainUploadReview(_ f: ReviewHostFixture) async throws
    -> GatewayAvatarReviewRecoveryIntent
{
    let shown = try await f.show()
    await f.api.setMode(.beforeAccept)
    await #expect(throws: GatewayAvatarReviewFailure.unavailable) {
        try await f.host.decide(.rejected, presentation: shown)
    }
    return try #require(f.host.pendingOperation?.intent)
}

@Test @MainActor
func avatarReviewRetirementHostPersistsBeforeNetworkKeepsExactNonceAndOnlyThenAllowsAcknowledgement()
    async throws
{
    let f = try ReviewHostFixture()
    let intent = try await uncertainUploadReview(f)
    try await f.host.recover()
    #expect(f.host.outcome == .notApplied && f.host.resolution == nil)
    await f.api.setMode(.normal)
    await f.api.pause("retire")
    let running = Task { try await f.host.retirePending(intent) }
    try await f.api.gate.wait()
    let stored = try #require(await f.journal.peek(scope: f.scope))
    #expect(stored.phase == .retiring && stored.intent == intent && f.host.isBusy)
    await #expect(throws: GatewayAvatarReviewJournalFailure.invalidTransition) {
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
    await #expect(throws: GatewayAvatarReviewJournalFailure.invalidTransition) {
        try await f.host.acknowledgeResult(result)
    }
    try await f.host.acknowledgeResult(#require(f.host.resolution))
    #expect(f.host.pendingOperation == nil)
}

@Test @MainActor
func avatarReviewRetirementLostACKRestartsInRetiringAndReadOnlyRecoveryNeverResendsEitherOperation()
    async throws
{
    let f = try ReviewHostFixture()
    let intent = try await uncertainUploadReview(f)
    await f.api.setMode(.lostRetirementACK)
    await #expect(throws: GatewayAvatarReviewFailure.unavailable) { try await f.host.retirePending(intent) }
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

@Test @MainActor func avatarReviewRetirementRejectsNonterminalReplyAndWrongCapturedIntent() async throws {
    let f = try ReviewHostFixture()
    let intent = try await uncertainUploadReview(f)
    let foreign = try GatewayAvatarReviewRecoveryIntent(
        item: intent.item, decisionID: UUID().uuidString.lowercased(), verdict: intent.verdict)
    await #expect(throws: GatewayAvatarReviewJournalFailure.invalidTransition) {
        try await f.host.retirePending(foreign)
    }
    #expect(await f.api.retirements.isEmpty)
    await f.api.setMode(.unsafeRetirement)
    await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
        try await f.host.retirePending(intent)
    }
    #expect(f.host.pendingOperation?.phase == .retiring && f.host.resolution == nil && f.host.outcome == nil)
}

@Test @MainActor func avatarReviewRetirementNeverSendsBeforeDurableStorageAndDoesNotCrossNativeTokenSwitch()
    async throws
{
    for storageFailure in [true, false] {
        let f = try ReviewHostFixture()
        let intent = try await uncertainUploadReview(f)
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
                    ? error as? GatewayAvatarReviewJournalFailure == .unavailable
                    : error as? GatewayAvatarReviewHostFailure == .superseded)
        }
        #expect(await f.api.retirements.isEmpty)
    }
}

@Test @MainActor func avatarReviewRetirementLateACKCannotRestoreAcrossSceneAccountParentOrDeletion()
    async throws
{
    for kind in ["scene", "account", "parent", "deletion", "activation"] {
        let f = try ReviewHostFixture()
        let intent = try await uncertainUploadReview(f)
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
            #expect(error as? GatewayAvatarReviewHostFailure == .superseded)
        }
        #expect(f.host.resolution == nil && f.host.outcome == nil)
        #expect(await f.api.retirements == [intent])
        #expect(await f.api.decisions.count == 1)
        f.host.invalidate()
    }
}

@Test func avatarReviewRetirementHTTPUsesConcreteServerTerminalRepliesAndRejectsUnsealedAbsence() async throws
{
    let fixture = try ReviewRecoveryWireFixture()
    for row in fixture.rows where row.action == "retire" {
        let stub = ReviewHTTPStub(row.response)
        let client = try reviewClient(stub, clock: ReviewClock(1_800_000_000_000))
        let result = try await client.retire(row.intent, token: reviewBearer)
        #expect(result.outcome == row.expected && result.outcome.isTerminal)
        let request = try #require(await stub.requests.first)
        let body = try #require(request.httpBody)
        #expect(request.url?.path == "/v1/moderation/avatar/retire")
        #expect(try body == GatewayAvatarReviewOperation.retire(row.intent).wire())
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(
            Set(fields.keys) == [
                "accountID", "requestID", "versionID", "generation", "reviewRevision", "decisionID",
                "verdict",
            ])
    }
    let absent = try #require(fixture.rows.first { $0.label == "not-applied" })
    await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
        try await reviewClient(ReviewHTTPStub(absent.response), clock: ReviewClock(1_800_000_000_000)).retire(
            absent.intent, token: reviewBearer)
    }
}
@MainActor private final class UploadRetirementPublicationEvents {
    var values: [GatewayAvatarReviewPublicationEvent] = []
}
@Test @MainActor func avatarReviewRetirementNeverEmitsResolvedForUnsealedAbsenceAcrossRestart() async throws {
    let events = UploadRetirementPublicationEvents()
    let f = try ReviewHostFixture(publicationChanged: { events.values.append($0) })
    let intent = try await uncertainUploadReview(f)
    try await f.host.recover()
    f.host.invalidate()
    try await f.connect()
    #expect(f.host.outcome == .notApplied && f.host.resolution == nil)
    #expect(events.values.allSatisfy { if case .pending = $0 { true } else { false } })
    await f.api.setMode(.lostRetirementACK)
    await #expect(throws: GatewayAvatarReviewFailure.unavailable) { try await f.host.retirePending(intent) }
    #expect(events.values.allSatisfy { if case .pending = $0 { true } else { false } })
    try await f.host.recover()
    guard case .resolved(let result) = events.values.last else {
        Issue.record("Terminal fence must follow durable recovery")
        return
    }
    #expect(result.intent == intent && result.outcome == .retired)
}
