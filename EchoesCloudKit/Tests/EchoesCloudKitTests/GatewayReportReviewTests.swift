import Foundation
import Testing

@testable import EchoesCloudKit

let reportOrigin = URL(string: "https://report-review.example.invalid")!
struct ReportWireFixture: Sendable {
    let now: Int, item: GatewayReportReviewItem, decisionID: String
    let cases: [String: GatewayReportReviewHTTPResponse]
    let recovery: GatewayReportReviewRecoveryIntent
    init() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "responses", withExtension: "json", subdirectory: "Fixtures/report-review"))
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(root["schemaVersion"] as? Int == 1)
        now = try #require(root["nowMilliseconds"] as? Int)
        let rows = try #require(root["cases"] as? [[String: Any]])
        var replies: [String: GatewayReportReviewHTTPResponse] = [:]
        for row in rows {
            replies[try #require(row["label"] as? String)] = .init(
                status: try #require(row["status"] as? Int),
                headers: try #require(row["headers"] as? [String: String]),
                body: try JSONSerialization.data(withJSONObject: row["body"]!))
        }
        cases = replies
        let inspection = try #require(
            JSONSerialization.jsonObject(with: replies["inspect-message"]!.body) as? [String: Any])
        item = try .init(
            reportID: #require(inspection["reportID"] as? String),
            createdAtMilliseconds: #require(inspection["createdAt"] as? Int),
            expiresAtMilliseconds: #require(inspection["expiresAt"] as? Int))
        let input = try #require(
            rows.first { $0["label"] as? String == "recover-confirmed" }?["input"] as? [String: Any])
        decisionID = try #require(input["decisionID"] as? String)
        recovery = try .init(
            reportID: item.reportID, decisionID: decisionID, verdict: .hideMessage,
            contentHash: #require(input["contentHash"] as? String))
    }
    var queue: GatewayReportReviewHTTPResponse { cases["queue-open"]! }
    var inspection: GatewayReportReviewHTTPResponse { cases["inspect-message"]! }
    var decision: GatewayReportReviewHTTPResponse { cases["decide-hidden"]! }
}
func reportJSON(_ fields: [String: Any], status: Int = 200) throws -> GatewayReportReviewHTTPResponse {
    .init(
        status: status, headers: reviewJSONHeaders, body: try JSONSerialization.data(withJSONObject: fields))
}
func reportBody(_ response: GatewayReportReviewHTTPResponse, _ changes: [String: Any]) throws
    -> GatewayReportReviewHTTPResponse
{
    var fields = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    fields.merge(changes) { _, n in n }
    return try reportJSON(fields, status: response.status)
}
actor ReportHTTPStub: GatewayReportReviewTransport {
    let response: GatewayReportReviewHTTPResponse
    let effect: (@Sendable () async -> Void)?
    var requests: [URLRequest] = []
    init(_ response: GatewayReportReviewHTTPResponse, effect: (@Sendable () async -> Void)? = nil) {
        self.response = response
        self.effect = effect
    }
    func send(_ request: URLRequest, operation: GatewayReportReviewOperation) async throws
        -> GatewayReportReviewHTTPResponse
    {
        requests.append(request)
        await effect?()
        return response
    }
}
func reportClient(
    _ transport: any GatewayReportReviewTransport, clock: ReviewClock, origin: URL = reportOrigin
) throws -> GatewayReportReviewHTTPClient {
    try .init(
        configuration: .init(origin: origin), transport: transport, isEnabled: { clock.enabled() },
        date: { clock.date() }, uptime: { clock.up() })
}
func reportInspection(_ f: ReportWireFixture, clock: ReviewClock? = nil) async throws
    -> GatewayReportReviewInspection
{
    try await reportClient(ReportHTTPStub(f.inspection), clock: clock ?? ReviewClock(f.now)).inspect(
        f.item, token: reviewBearer)
}
func reportIntent(_ f: ReportWireFixture, clock: ReviewClock? = nil) async throws
    -> GatewayReportReviewDecisionIntent
{
    try await .init(
        receipt: reportInspection(f, clock: clock).receipt, decisionID: f.decisionID, verdict: .hideMessage)
}

@Test func reportReviewNativeDecodesConcreteRuntimeQueueInspectionDecisionReplayAndClosedQueue() async throws
{
    let f = try ReportWireFixture()
    let clock = ReviewClock(f.now)
    let page = try await reportClient(ReportHTTPStub(f.queue), clock: clock).queue(
        after: nil, token: reviewBearer)
    #expect(page.items == [f.item] && page.next == nil)
    let inspection = try await reportInspection(f, clock: clock)
    #expect(inspection.message?.text == "PRIVATE-SYNTHETIC-MESSAGE" && inspection.receipt.item == f.item)
    let intent = try GatewayReportReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .hideMessage)
    let first = try await reportClient(ReportHTTPStub(f.decision), clock: clock).decide(
        intent, token: reviewBearer)
    #expect(
        try await reportClient(ReportHTTPStub(f.cases["decide-replay"]!), clock: clock).decide(
            intent, token: reviewBearer) == first)
    #expect(
        try await reportClient(ReportHTTPStub(f.cases["queue-closed"]!), clock: clock).queue(
            after: nil, token: reviewBearer
        ).items.isEmpty)
}
@Test func reportReviewNativeDecodesConcreteRuntimeAllReadOnlyRecoveryOutcomesAfterExpiryAndSessionChange()
    async throws
{
    let f = try ReportWireFixture()
    let clock = ReviewClock(f.now)
    clock.move(wall: 120_000, monotonic: 120)
    let newToken = try GatewaySecret(
        "6a000000-0000-4000-8000-000000000098." + String(repeating: "b", count: 43))
    for (label, expected) in [
        ("recover-not-applied", "not-applied"), ("recover-confirmed", "confirmed"),
        ("recover-superseded", "superseded"), ("recover-retired", "retired"),
    ] {
        let response = f.cases[label]!
        let body = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let intent = try GatewayReportReviewRecoveryIntent(
            reportID: f.item.reportID, decisionID: #require(body["decisionID"] as? String),
            verdict: .hideMessage, contentHash: f.recovery.contentHash)
        let value = try await reportClient(ReportHTTPStub(response), clock: clock).recover(
            intent, token: newToken)
        switch value.outcome {
        case .confirmed(let revision): #expect(expected == "confirmed" && gatewayUUID(revision))
        case .notApplied: #expect(expected == "not-applied")
        case .superseded: #expect(expected == "superseded")
        case .retired: #expect(expected == "retired")
        }
    }
}
@Test func reportReviewNativeClosedWireNeverSendsReasonTextLocationOrRole() async throws {
    let f = try ReportWireFixture()
    let clock = ReviewClock(f.now)
    let intent = try await reportIntent(f)
    for (operation, response) in [
        (GatewayReportReviewOperation.queue(after: nil), f.queue), (.inspect(f.item), f.inspection),
        (.decide(intent), f.decision), (.recover(f.recovery), f.cases["recover-confirmed"]!),
    ] {
        let stub = ReportHTTPStub(response)
        let client = try reportClient(stub, clock: clock)
        switch operation {
        case .queue: _ = try await client.queue(after: nil, token: reviewBearer)
        case .inspect: _ = try await client.inspect(f.item, token: reviewBearer)
        case .decide: _ = try await client.decide(intent, token: reviewBearer)
        case .recover: _ = try await client.recover(f.recovery, token: reviewBearer)
        case .retire: _ = try await client.retire(f.recovery, token: reviewBearer)
        }
        let request = try #require(await stub.requests.first)
        #expect(
            request.url?.absoluteString == reportOrigin.absoluteString + "/v1/moderation/reports/"
                + operation.action)
        #expect(try request.httpBody == operation.wire())
        #expect(request.httpMethod == "POST" && request.httpBody!.count <= 512)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + reviewBearer.value)
        #expect(request.value(forHTTPHeaderField: "Content-Length") == String(request.httpBody!.count))
        #expect(
            request.value(forHTTPHeaderField: "Cookie") == nil
                && request.value(forHTTPHeaderField: "Origin") == nil)
    }
}
@Test func reportReviewNativeDefaultDisabledAndMalformedTokenDoNotTouchTransport() async throws {
    let f = try ReportWireFixture()
    let stub = ReportHTTPStub(f.queue)
    let clock = ReviewClock(f.now)
    let disabled = try GatewayReportReviewHTTPClient(
        configuration: .init(origin: reportOrigin), transport: stub)
    await #expect(throws: GatewayReportReviewFailure.unavailable) {
        try await disabled.queue(after: nil, token: reviewBearer)
    }
    for raw in ["bad", String(repeating: "a", count: 80), String(reviewBearer.value.dropLast()) + "!"] {
        await #expect(throws: GatewayReportReviewFailure.invalidInput) {
            try await reportClient(stub, clock: clock).queue(after: nil, token: GatewaySecret(raw))
        }
    }
    #expect(await stub.requests.isEmpty)
}
@Test func reportReviewNativeQueueEnforcesExactFieldsBooleansDatesOrderingAndProgress() async throws {
    let f = try ReportWireFixture()
    let clock = ReviewClock(f.now)
    let row: [String: Any] = [
        "reportID": f.item.reportID, "createdAt": f.item.createdAtMilliseconds,
        "expiresAt": f.item.expiresAtMilliseconds,
    ]
    for changes: [String: Any] in [
        ["protocolVersion": true], ["schemaVersion": 2], ["reporterID": UUID().uuidString],
        ["items": [row, row]], ["items": Array(repeating: row, count: 21)],
        ["items": [row.merging(["latitude": 1]) { _, n in n }]],
        ["items": [row.merging(["createdAt": true]) { _, n in n }]],
        ["items": [row.merging(["expiresAt": f.item.expiresAtMilliseconds + 1]) { _, n in n }]],
        ["after": "bad"],
    ] {
        let response = try reportBody(f.queue, changes)
        await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
            try await reportClient(ReportHTTPStub(response), clock: clock).queue(
                after: nil, token: reviewBearer)
        }
    }
    let cursor = try GatewayReportReviewCursor(f.item.reportID)
    await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
        try await reportClient(ReportHTTPStub(f.queue), clock: clock).queue(
            after: cursor, token: reviewBearer)
    }
    let emptyProgress = try reportBody(f.queue, ["items": [], "after": f.item.reportID])
    #expect(
        try await reportClient(ReportHTTPStub(emptyProgress), clock: clock).queue(
            after: nil, token: reviewBearer
        ).next == cursor)
    await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
        try await reportClient(ReportHTTPStub(emptyProgress), clock: clock).queue(
            after: cursor, token: reviewBearer)
    }
}
@Test func reportReviewNativeInspectionBindsExactMetadataAndRejectsExtraPrivateFields() async throws {
    let f = try ReportWireFixture()
    let clock = ReviewClock(f.now)
    let body = try #require(JSONSerialization.jsonObject(with: f.inspection.body) as? [String: Any])
    let message = try #require(body["message"] as? [String: Any])
    for changes: [String: Any] in [
        ["reportID": "community-v1-report-" + String(repeating: "f", count: 64)],
        ["createdAt": f.item.createdAtMilliseconds - 1], ["reporterID": UUID().uuidString],
        ["messageID": "bad"], ["contentHash": String(repeating: "G", count: 64)],
        ["inspectionExpiresAt": f.now], ["inspectionExpiresAt": f.now + 90_001],
        ["message": message.merging(["latitude": 1]) { _, n in n }],
        ["message": message.merging(["expiresAt": f.now + 7_200_001]) { _, n in n }],
        ["message": message.merging(["authorID": "bad"]) { _, n in n }],
    ] {
        let response = try reportBody(f.inspection, changes)
        await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
            try await reportClient(ReportHTTPStub(response), clock: clock).inspect(
                f.item, token: reviewBearer)
        }
    }
}
@Test func reportReviewNativeTextUsesUTF16NFCTrimAndControlRules() async throws {
    let f = try ReportWireFixture()
    let clock = ReviewClock(f.now)
    for text in [
        "", " leading", "trailing\u{FEFF}", "e\u{301}", "a\u{202e}b", "a\u{7}b",
        String(repeating: "😀", count: 251),
    ] {
        let response = try reportBody(f.inspection, ["reason": text])
        await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
            try await reportClient(ReportHTTPStub(response), clock: clock).inspect(
                f.item, token: reviewBearer)
        }
    }
    for text in ["é\nline\ttext", String(repeating: "😀", count: 250)] {
        let response = try reportBody(f.inspection, ["reason": text])
        #expect(
            try await reportClient(ReportHTTPStub(response), clock: clock).inspect(
                f.item, token: reviewBearer
            ).reason == text)
    }
}
@Test func reportReviewNativeMissingMessageAllowsDismissAndCannotAuthorizeHide() async throws {
    let f = try ReportWireFixture()
    let response = try reportBody(f.inspection, ["message": NSNull()])
    let inspection = try await reportClient(ReportHTTPStub(response), clock: ReviewClock(f.now)).inspect(
        f.item, token: reviewBearer)
    #expect(inspection.message == nil)
    #expect(throws: GatewayReportReviewFailure.invalidInput) {
        try GatewayReportReviewDecisionIntent(
            receipt: inspection.receipt, decisionID: f.decisionID, verdict: .hideMessage)
    }
    #expect(
        try GatewayReportReviewDecisionIntent(
            receipt: inspection.receipt, decisionID: f.decisionID, verdict: .dismiss
        ).verdict == .dismiss)
}
@Test func reportReviewNativeReceiptPinsOriginSessionAndBothClocksBeforeAnyDecisionIO() async throws {
    let f = try ReportWireFixture()
    let intent = try await reportIntent(f)
    for (wall, monotonic) in [(90_000, 0.0), (0, 90), (-1, 0), (0, -1)] {
        let clock = ReviewClock(f.now)
        let stub = ReportHTTPStub(f.decision)
        clock.move(wall: wall, monotonic: monotonic)
        await #expect(throws: GatewayReportReviewFailure.stale) {
            try await reportClient(stub, clock: clock).decide(intent, token: reviewBearer)
        }
        #expect(await stub.requests.isEmpty)
    }
    let stub = ReportHTTPStub(f.decision)
    let clock = ReviewClock(f.now)
    await #expect(throws: GatewayReportReviewFailure.invalidInput) {
        try await reportClient(stub, clock: clock, origin: URL(string: "https://other.example.invalid")!)
            .decide(intent, token: reviewBearer)
    }
    let other = try GatewaySecret("6a000000-0000-4000-8000-000000000098." + String(repeating: "b", count: 43))
    await #expect(throws: GatewayReportReviewFailure.invalidInput) {
        try await reportClient(stub, clock: clock).decide(intent, token: other)
    }
    #expect(await stub.requests.isEmpty)
}
@Test func reportReviewNativeWithholdsLateCancelledDisabledAndClockRollbackResponses() async throws {
    let f = try ReportWireFixture()
    for (wall, monotonic) in [(15_000, 0.0), (0, 15), (-1, 0), (0, -1)] {
        let clock = ReviewClock(f.now)
        let stub = ReportHTTPStub(f.inspection, effect: { clock.move(wall: wall, monotonic: monotonic) })
        await #expect(throws: GatewayReportReviewFailure.stale) {
            try await reportClient(stub, clock: clock).inspect(f.item, token: reviewBearer)
        }
    }
    let clock = ReviewClock(f.now)
    let stub = ReportHTTPStub(f.inspection, effect: { clock.disable() })
    await #expect(throws: GatewayReportReviewFailure.unavailable) {
        try await reportClient(stub, clock: clock).inspect(f.item, token: reviewBearer)
    }
    let task = Task { () throws -> GatewayReportReviewPage in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await reportClient(ReportHTTPStub(f.queue), clock: ReviewClock(f.now)).queue(
            after: nil, token: reviewBearer)
    }
    await #expect(throws: GatewayFailure.cancelled) { try await task.value }
}
@Test func reportReviewNativeDecisionAndRecoveryMustMatchEverySavedIdentity() async throws {
    let f = try ReportWireFixture()
    let intent = try await reportIntent(f)
    let clock = ReviewClock(f.now)
    for changes: [String: Any] in [
        ["decisionID": UUID().uuidString.lowercased()], ["inspectionID": UUID().uuidString.lowercased()],
        ["reportID": "community-v1-report-" + String(repeating: "f", count: 64)], ["verdict": "dismiss"],
        ["contentHash": String(repeating: "f", count: 64)], ["revision": "bad"], ["extra": true],
    ] {
        let response = try reportBody(f.decision, changes)
        await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
            try await reportClient(ReportHTTPStub(response), clock: clock).decide(intent, token: reviewBearer)
        }
    }
    for changes: [String: Any] in [
        ["decisionID": UUID().uuidString.lowercased()], ["verdict": "dismiss"],
        ["contentHash": String(repeating: "f", count: 64)], ["revision": NSNull()], ["outcome": "unknown"],
        ["outcome": "not-applied"], ["outcome": "superseded"],
    ] {
        let response = try reportBody(f.cases["recover-confirmed"]!, changes)
        await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
            try await reportClient(ReportHTTPStub(response), clock: clock).recover(
                f.recovery, token: reviewBearer)
        }
    }
}
@Test func reportReviewNativeServerErrorsAreRedactedAndStatusBoundWithoutClearingSession() async throws {
    let f = try ReportWireFixture()
    let clock = ReviewClock(f.now)
    for (label, expected) in [
        ("queue-ordinary-denied", GatewayReportReviewFailure.denied), ("queue-disabled", .unavailable),
    ] {
        await #expect(throws: expected) {
            try await reportClient(ReportHTTPStub(f.cases[label]!), clock: clock).queue(
                after: nil, token: reviewBearer)
        }
    }
    var limited = try reportJSON(["protocolVersion": 1, "error": "REPORT_REVIEW_CAPACITY"], status: 429)
    limited = .init(
        status: 429, headers: limited.headers.merging(["Retry-After": "60"]) { _, n in n }, body: limited.body
    )
    let response = limited
    await #expect(throws: GatewayReportReviewFailure.limited(retryAfterSeconds: 60)) {
        try await reportClient(ReportHTTPStub(response), clock: clock).queue(after: nil, token: reviewBearer)
    }
    for (status, error) in [(403, "PRIVATE-ERROR"), (400, "REPORT_REVIEW_SCOPE")] {
        let response = try reportJSON(["protocolVersion": 1, "error": error], status: status)
        await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
            try await reportClient(ReportHTTPStub(response), clock: clock).queue(
                after: nil, token: reviewBearer)
        }
    }
}
@Test func reportReviewNativeBoundaryRejectsMIMECacheCompressionRangeLengthAndInvalidUTF8() async throws {
    let f = try ReportWireFixture()
    let clock = ReviewClock(f.now)
    for change in [
        ["Content-Type": "text/html"], ["Cache-Control": "public"], ["Content-Encoding": "gzip"],
        ["Content-Range": "bytes 0-1/2"], ["X-Content-Type-Options": ""], ["Content-Length": "8193"],
        ["Content-Length": "0001"],
    ] {
        var headers = f.queue.headers
        for (name, value) in change {
            headers = headers.filter { $0.key.lowercased() != name.lowercased() }
            headers[name] = value
        }
        let response = GatewayReportReviewHTTPResponse(status: 200, headers: headers, body: f.queue.body)
        await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
            try await reportClient(ReportHTTPStub(response), clock: clock).queue(
                after: nil, token: reviewBearer)
        }
    }
    let response = GatewayReportReviewHTTPResponse(
        status: 200, headers: reviewJSONHeaders, body: Data([0xff]))
    await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
        try await reportClient(ReportHTTPStub(response), clock: clock).queue(after: nil, token: reviewBearer)
    }
}
@Test func reportReviewNativePublicModelsRejectMalformedMetadataAndRedactReflection() async throws {
    let f = try ReportWireFixture()
    let inspection = try await reportInspection(f)
    let intent = try await reportIntent(f)
    #expect(throws: GatewayReportReviewFailure.invalidInput) {
        try GatewayReportReviewItem(
            reportID: f.item.reportID, createdAtMilliseconds: Int.min, expiresAtMilliseconds: Int.max)
    }
    #expect(throws: GatewayReportReviewFailure.invalidInput) { try GatewayReportReviewCursor("bad") }
    #expect(throws: GatewayReportReviewFailure.invalidInput) {
        try GatewayReportReviewRecoveryIntent(
            reportID: f.item.reportID, decisionID: "bad", verdict: .dismiss,
            contentHash: f.recovery.contentHash)
    }
    for value: any CustomStringConvertible & CustomReflectable in [
        f.item, inspection, inspection.receipt, intent, f.recovery, f.inspection,
        GatewayReportReviewOperation.decide(intent),
    ] {
        #expect(value.description.contains("redacted") && value.customMirror.children.isEmpty)
        #expect(!String(reflecting: value).contains("PRIVATE-SYNTHETIC"))
    }
}
@Test func reportReviewNativeQueueAcceptsTwentyDistinctRowsAndRejectsTwentyOneOrReverseOrder() async throws {
    let f = try ReportWireFixture()
    let clock = ReviewClock(f.now)
    let rows: [[String: Any]] = (0..<21).map { index in
        [
            "reportID": "community-v1-report-" + String(format: "%064x", index),
            "createdAt": f.item.createdAtMilliseconds, "expiresAt": f.item.expiresAtMilliseconds,
        ]
    }
    let valid = try reportBody(f.queue, ["items": Array(rows.prefix(20)), "after": rows[19]["reportID"]!])
    #expect(
        try await reportClient(ReportHTTPStub(valid), clock: clock).queue(after: nil, token: reviewBearer)
            .items.count == 20)
    for invalid in [rows, Array(rows.prefix(20).reversed())] {
        let response = try reportBody(f.queue, ["items": invalid])
        await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
            try await reportClient(ReportHTTPStub(response), clock: clock).queue(
                after: nil, token: reviewBearer)
        }
    }
}
@Test func reportReviewNativeReceiptDeadlineCannotBeExtendedBySlowInspectionOrOutliveMessage() async throws {
    let f = try ReportWireFixture()
    let clock = ReviewClock(f.now)
    let response = try reportBody(f.inspection, ["inspectionExpiresAt": f.now + 100_000])
    let slow = ReportHTTPStub(response, effect: { clock.move(wall: 10_000, monotonic: 10) })
    let inspection = try await reportClient(slow, clock: clock).inspect(f.item, token: reviewBearer)
    #expect(inspection.receipt.expiresAtMilliseconds == f.now + 90_000)
    let root = try #require(JSONSerialization.jsonObject(with: f.inspection.body) as? [String: Any])
    var message = try #require(root["message"] as? [String: Any])
    message["createdAt"] = f.now - 7_199_000
    message["expiresAt"] = f.now + 1000
    let short = try reportBody(f.inspection, ["message": message])
    let shortClock = ReviewClock(f.now)
    let value = try await reportClient(ReportHTTPStub(short), clock: shortClock).inspect(
        f.item, token: reviewBearer)
    #expect(value.receipt.expiresAtMilliseconds == f.now + 1000)
    let intent = try GatewayReportReviewDecisionIntent(
        receipt: value.receipt, decisionID: f.decisionID, verdict: .hideMessage)
    shortClock.move(wall: 1000, monotonic: 1)
    let stub = ReportHTTPStub(f.decision)
    await #expect(throws: GatewayReportReviewFailure.stale) {
        try await reportClient(stub, clock: shortClock).decide(intent, token: reviewBearer)
    }
    #expect(await stub.requests.isEmpty)
}
@Test func reportReviewNativeDecisionACKAfterReceiptExpiryRequiresRecoveryInsteadOfClaimingSuccess()
    async throws
{
    let f = try ReportWireFixture()
    let clock = ReviewClock(f.now)
    clock.move(wall: 89_000, monotonic: 89)
    let intent = try await reportIntent(f)
    let slow = ReportHTTPStub(f.decision, effect: { clock.move(wall: 1000, monotonic: 1) })
    await #expect(throws: GatewayReportReviewFailure.stale) {
        try await reportClient(slow, clock: clock).decide(intent, token: reviewBearer)
    }
    #expect(await slow.requests.count == 1)
    let recovery = GatewayReportReviewRecoveryIntent(decision: intent)
    #expect(
        try await reportClient(ReportHTTPStub(f.cases["recover-confirmed"]!), clock: clock).recover(
            recovery, token: reviewBearer
        ).outcome
            == .confirmed(
                revision: String(
                    try #require(
                        (JSONSerialization.jsonObject(with: f.decision.body) as? [String: Any])?["revision"]
                            as? String))))
}
