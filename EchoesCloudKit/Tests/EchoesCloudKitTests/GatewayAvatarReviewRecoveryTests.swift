import Foundation
import Testing

@testable import EchoesCloudKit

struct ReviewRecoveryWireFixture: Sendable {
    struct Row: Sendable {
        let label: String
        let intent: GatewayAvatarReviewRecoveryIntent
        let response: GatewayAvatarHTTPResponse
        let expected: GatewayAvatarReviewOutcome
    }
    let rows: [Row]
    init() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "responses", withExtension: "json",
                subdirectory: "Fixtures/avatar-review-recovery"))
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(raw["cases"] as? [[String: Any]])
        rows = try cases.map { row in
            let input = try #require(row["input"] as? [String: Any])
            let item = try GatewayAvatarReviewItem(
                accountID: #require(input["accountID"] as? String),
                requestID: #require(input["requestID"] as? String),
                versionID: #require(input["versionID"] as? String),
                generation: #require(input["generation"] as? Int),
                reviewRevision: #require(input["reviewRevision"] as? String))
            let rawVerdict = try #require(input["verdict"] as? String)
            let verdict = try #require(GatewayAvatarReviewVerdict(rawValue: rawVerdict))
            let intent = try GatewayAvatarReviewRecoveryIntent(
                item: item, decisionID: #require(input["decisionID"] as? String),
                verdict: verdict)
            let body = try #require(row["body"] as? [String: Any])
            let expected: GatewayAvatarReviewOutcome
            switch body["outcome"] as? String {
            case "confirmed": expected = .confirmed(revision: try #require(body["revision"] as? String))
            case "not-applied": expected = .notApplied
            case "superseded": expected = .superseded
            default: throw GatewayAvatarReviewFailure.invalidResponse
            }
            return Row(
                label: try #require(row["label"] as? String), intent: intent,
                response: .init(
                    status: try #require(row["status"] as? Int),
                    headers: try #require(row["headers"] as? [String: String]),
                    body: try JSONSerialization.data(withJSONObject: body)), expected: expected)
        }
    }
}

@Test func avatarReviewRecoveryDecodesAllFiveActualServerOutcomesWithoutInspection() async throws {
    let f = try ReviewRecoveryWireFixture()
    #expect(f.rows.count == 5)
    for row in f.rows {
        let stub = ReviewHTTPStub(row.response)
        let result = try await reviewClient(stub, clock: ReviewClock(1_800_000_000_000)).recover(
            row.intent, token: reviewBearer)
        #expect(result.intent == row.intent && result.outcome == row.expected)
        #expect(await stub.requests.count == 1)
    }
}

@Test func avatarReviewRecoverySendsOnlyExactMetadataAndAcceptsRenewedBearer() async throws {
    let f = try ReviewRecoveryWireFixture()
    let row = try #require(f.rows.first { $0.label == "confirmed-after-expiry" })
    let token = try GatewaySecret(String(reviewBearer.value.prefix(37)) + String(repeating: "b", count: 43))
    let stub = ReviewHTTPStub(row.response)
    let result = try await reviewClient(stub, clock: ReviewClock(1_800_000_000_000)).recover(
        row.intent, token: token)
    #expect(result.outcome == row.expected)
    let request = try #require(await stub.requests.first)
    let body = try #require(request.httpBody)
    let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(
        Set(fields.keys)
            == Set([
                "accountID", "requestID", "versionID", "generation", "reviewRevision", "decisionID",
                "verdict",
            ]))
    #expect(body.count <= 512 && request.url?.path == "/v1/moderation/avatar/recover")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token.value)
    #expect(request.value(forHTTPHeaderField: "Content-Length") == String(body.count))
    #expect(
        request.value(forHTTPHeaderField: "Origin") == nil
            && request.value(forHTTPHeaderField: "Cookie") == nil)
}

@Test func avatarReviewRecoveryCannotAuthorizeMutationAfterReceiptExpiry() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    let inspection = try await reviewInspection(f, clock: clock)
    let decision = try GatewayAvatarReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .approved)
    let recovery = GatewayAvatarReviewRecoveryIntent(decision: decision)
    #expect(recovery.item == f.item && recovery.decisionID == f.decisionID && recovery.verdict == .approved)
    clock.move(wall: 91_000, monotonic: 91)
    let stub = ReviewHTTPStub(f.decision)
    await #expect(throws: GatewayAvatarReviewFailure.stale) {
        try await reviewClient(stub, clock: clock).decide(decision, token: reviewBearer)
    }
    #expect(await stub.requests.isEmpty)
}

@Test func avatarReviewRecoveryRejectsEveryMismatchedIdentityVersionGenerationAndVerdict() async throws {
    let f = try ReviewRecoveryWireFixture()
    let row = try #require(f.rows.first)
    for changes: [String: Any] in [
        ["protocolVersion": 2], ["protocolVersion": true], ["schemaVersion": 2], ["schemaVersion": true],
        ["accountID": UUID().uuidString.lowercased()], ["requestID": UUID().uuidString.lowercased()],
        ["versionID": UUID().uuidString.lowercased()], ["generation": row.intent.item.generation + 1],
        ["generation": true], ["reviewRevision": UUID().uuidString.lowercased()],
        ["decisionID": UUID().uuidString.lowercased()], ["verdict": "rejected"],
    ] {
        let stub = ReviewHTTPStub(try reviewBody(row.response, changes: changes))
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await reviewClient(stub, clock: ReviewClock(1_800_000_000_000)).recover(
                row.intent, token: reviewBearer)
        }
    }
}

@Test func avatarReviewRecoveryRejectsUnknownOutcomeExtraFieldsMissingNullAndForgedRevision() async throws {
    let f = try ReviewRecoveryWireFixture()
    let row = try #require(f.rows.first)
    for changes: [String: Any] in [
        ["outcome": "unknown"], ["outcome": true], ["outcome": "confirmed"],
        ["outcome": "confirmed", "revision": row.intent.item.reviewRevision],
        ["outcome": "confirmed", "revision": "bad"], ["revision": UUID().uuidString.lowercased()],
        ["private": "PRIVATE-SENTINEL"],
    ] {
        let stub = ReviewHTTPStub(try reviewBody(row.response, changes: changes))
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await reviewClient(stub, clock: ReviewClock(1_800_000_000_000)).recover(
                row.intent, token: reviewBearer)
        }
    }
    var missing = try #require(JSONSerialization.jsonObject(with: row.response.body) as? [String: Any])
    missing.removeValue(forKey: "revision")
    await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
        try await reviewClient(ReviewHTTPStub(reviewJSON(missing)), clock: ReviewClock(1_800_000_000_000))
            .recover(row.intent, token: reviewBearer)
    }
}

@Test func avatarReviewRecoveryActivationCancellationAndErrorsKeepResultsClosed() async throws {
    let f = try ReviewRecoveryWireFixture()
    let row = try #require(f.rows.first)
    let clock = ReviewClock(1_800_000_000_000)
    let stub = ReviewHTTPStub(row.response)
    clock.disable()
    await #expect(throws: GatewayAvatarReviewFailure.unavailable) {
        try await reviewClient(stub, clock: clock).recover(row.intent, token: reviewBearer)
    }
    #expect(await stub.requests.isEmpty)
    let cancel = ReviewHTTPStub(row.response) { withUnsafeCurrentTask { $0?.cancel() } }
    let task = Task {
        try await reviewClient(cancel, clock: ReviewClock(1_800_000_000_000)).recover(
            row.intent, token: reviewBearer)
    }
    await #expect(throws: GatewayFailure.cancelled) { try await task.value }
    let denied = try reviewJSON(["protocolVersion": 1, "error": "AVATAR_REVIEW_SCOPE"], status: 403)
    await #expect(throws: GatewayAvatarReviewFailure.denied) {
        try await reviewClient(ReviewHTTPStub(denied), clock: ReviewClock(1_800_000_000_000)).recover(
            row.intent, token: reviewBearer)
    }
}

@Test func avatarReviewRecoveryRejectsInvalidIDAndRedactsOutcomeMetadata() async throws {
    let f = try ReviewRecoveryWireFixture()
    let row = try #require(f.rows.first { $0.label == "confirmed-after-expiry" })
    #expect(throws: GatewayAvatarReviewFailure.invalidInput) {
        try GatewayAvatarReviewRecoveryIntent(item: row.intent.item, decisionID: "bad", verdict: .approved)
    }
    let value = try await reviewClient(ReviewHTTPStub(row.response), clock: ReviewClock(1_800_000_000_000))
        .recover(row.intent, token: reviewBearer)
    for value: any CustomStringConvertible & CustomReflectable in [
        row.intent, value, value.outcome, GatewayAvatarReviewOperation.recover(row.intent),
    ] {
        #expect(value.description.contains("<redacted>") && value.customMirror.children.isEmpty)
        #expect(!String(reflecting: value).contains(row.intent.item.accountID))
    }
}
