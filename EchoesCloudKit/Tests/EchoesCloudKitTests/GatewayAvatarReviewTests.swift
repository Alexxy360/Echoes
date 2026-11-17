import CryptoKit
import Foundation
import Testing

@testable import EchoesCloudKit

let reviewBearer = try! GatewaySecret(
    "6a000000-0000-4000-8000-000000000099." + String(repeating: "a", count: 43))
let reviewOrigin = URL(string: "https://avatar-review.example.invalid")!
let reviewJSONHeaders = [
    "Content-Type": "application/json", "Cache-Control": "no-store", "Pragma": "no-cache",
    "X-Content-Type-Options": "nosniff",
]

struct ReviewWireFixture: Sendable {
    let now: Int, item: GatewayAvatarReviewItem, decisionID: String
    let cases: [String: GatewayAvatarHTTPResponse]
    init() throws {
        let directory = "Fixtures/avatar-review"
        let url = try #require(
            Bundle.module.url(forResource: "responses", withExtension: "json", subdirectory: directory))
        let imageURL = try #require(
            Bundle.module.url(forResource: "image", withExtension: "jpg", subdirectory: directory))
        let image = try Data(contentsOf: imageURL)
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(raw["schemaVersion"] as? Int == 1)
        #expect(raw["imageSHA256"] as? String == reviewDigest(image))
        now = try #require(raw["nowMilliseconds"] as? Int)
        let selection = try #require(raw["selection"] as? [String: Any])
        item = try .init(
            accountID: #require(selection["accountID"] as? String),
            requestID: #require(selection["requestID"] as? String),
            versionID: #require(selection["versionID"] as? String),
            generation: #require(selection["generation"] as? Int),
            reviewRevision: #require(selection["reviewRevision"] as? String))
        let rows = try #require(raw["cases"] as? [[String: Any]])
        var replies: [String: GatewayAvatarHTTPResponse] = [:]
        for row in rows {
            let label = try #require(row["label"] as? String)
            replies[label] = .init(
                status: try #require(row["status"] as? Int),
                headers: try #require(row["headers"] as? [String: String]),
                body: row["image"] != nil ? image : try JSONSerialization.data(withJSONObject: row["body"]!))
        }
        cases = replies
        let decision = try #require(rows.first { ($0["label"] as? String) == "decide-approved" })
        decisionID = try #require((decision["input"] as? [String: Any])?["decisionID"] as? String)
    }
    var image: GatewayAvatarHTTPResponse { cases["inspect-pending"]! }
    var queue: GatewayAvatarHTTPResponse { cases["queue-pending"]! }
    var decision: GatewayAvatarHTTPResponse { cases["decide-approved"]! }
    func freshImage() throws -> GatewayAvatarHTTPResponse {
        try reviewHeader(
            image, "x-echoes-avatar-review", ["expiresAt": Int(Date().timeIntervalSince1970 * 1000) + 90_000])
    }
}
func reviewDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func reviewHeader(_ response: GatewayAvatarHTTPResponse, _ name: String, _ changes: [String: Any]) throws
    -> GatewayAvatarHTTPResponse
{
    var headers = response.headers
    let key = try #require(headers.keys.first { $0.lowercased() == name.lowercased() })
    var value = try #require(JSONSerialization.jsonObject(with: Data(headers[key]!.utf8)) as? [String: Any])
    value.merge(changes) { _, n in n }
    headers[key] = String(
        data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
    return .init(status: response.status, headers: headers, body: response.body)
}
func reviewJSON(_ fields: [String: Any], status: Int = 200) throws -> GatewayAvatarHTTPResponse {
    .init(
        status: status, headers: reviewJSONHeaders, body: try JSONSerialization.data(withJSONObject: fields))
}
func reviewBody(_ response: GatewayAvatarHTTPResponse, changes: [String: Any]) throws
    -> GatewayAvatarHTTPResponse
{
    var fields = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    fields.merge(changes) { _, n in n }
    return try reviewJSON(fields, status: response.status)
}
actor ReviewHTTPStub: GatewayAvatarReviewTransport {
    let response: GatewayAvatarHTTPResponse
    let effect: (@Sendable () async -> Void)?
    var requests: [URLRequest] = []
    init(_ response: GatewayAvatarHTTPResponse, effect: (@Sendable () async -> Void)? = nil) {
        self.response = response
        self.effect = effect
    }
    func send(_ request: URLRequest, operation: GatewayAvatarReviewOperation) async throws
        -> GatewayAvatarHTTPResponse
    {
        requests.append(request)
        await effect?()
        return response
    }
}
final class ReviewClock: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: Int, uptime: TimeInterval = 100
    private var active = true
    init(_ milliseconds: Int) { self.milliseconds = milliseconds }
    func date() -> Date { lock.withLock { Date(timeIntervalSince1970: Double(milliseconds) / 1000) } }
    func up() -> TimeInterval { lock.withLock { uptime } }
    func enabled() -> Bool { lock.withLock { active } }
    func disable() { lock.withLock { active = false } }
    func move(wall: Int = 0, monotonic: TimeInterval = 0) {
        lock.withLock {
            milliseconds += wall
            uptime += monotonic
        }
    }
}
func reviewClient(
    _ transport: any GatewayAvatarReviewTransport, clock: ReviewClock, origin: URL = reviewOrigin,
    decoder: any GatewayAvatarDecoding = NativeGatewayAvatarDecoder()
) throws -> GatewayAvatarReviewHTTPClient {
    try .init(
        configuration: .init(origin: origin), transport: transport, decoder: decoder,
        isEnabled: { clock.enabled() }, date: { clock.date() }, uptime: { clock.up() })
}
func reviewInspection(_ f: ReviewWireFixture, clock: ReviewClock? = nil) async throws
    -> GatewayAvatarReviewInspection
{
    try await reviewClient(ReviewHTTPStub(f.image), clock: clock ?? ReviewClock(f.now)).inspect(
        f.item, token: reviewBearer)
}

@Test func avatarReviewNativeActualServerQueueInspectionDecisionAndReplayDecode() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    #expect(
        try await reviewClient(ReviewHTTPStub(f.queue), clock: clock).queue(token: reviewBearer) == [f.item])
    let inspection = try await reviewInspection(f, clock: clock)
    #expect(inspection.avatar.image.width == inspection.avatar.manifest.width)
    #expect(inspection.avatar.manifest.reference.versionID == f.item.versionID)
    #expect(inspection.receipt.item == f.item)
    let intent = try GatewayAvatarReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .approved)
    let result = try await reviewClient(ReviewHTTPStub(f.decision), clock: clock).decide(
        intent, token: reviewBearer)
    let replay = try await reviewClient(ReviewHTTPStub(f.cases["decide-exact-replay"]!), clock: clock).decide(
        intent, token: reviewBearer)
    #expect(result == replay && result.intent == intent)
    #expect(
        try await reviewClient(ReviewHTTPStub(f.cases["queue-reviewed"]!), clock: clock).queue(
            token: reviewBearer
        ).isEmpty)
    await #expect(throws: GatewayAvatarReviewFailure.denied) {
        try await reviewClient(ReviewHTTPStub(f.cases["queue-ordinary-denied"]!), clock: clock).queue(
            token: reviewBearer)
    }
    await #expect(throws: GatewayAvatarReviewFailure.unavailable) {
        try await reviewClient(ReviewHTTPStub(f.cases["queue-disabled"]!), clock: clock).queue(
            token: reviewBearer)
    }
}

@Test func avatarReviewNativeOnlySendsClosedRequestsWithoutGPSRoleOrProviderURLs() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    let inspection = try await reviewInspection(f, clock: clock)
    let intent = try GatewayAvatarReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .approved)
    for (action, response) in [
        (GatewayAvatarReviewOperation.queue, f.queue), (.inspect(f.item), f.image),
        (.decide(intent), f.decision),
    ] {
        let stub = ReviewHTTPStub(response)
        let client = try reviewClient(stub, clock: clock)
        switch action {
        case .queue: _ = try await client.queue(token: reviewBearer)
        case .inspect: _ = try await client.inspect(f.item, token: reviewBearer)
        case .decide: _ = try await client.decide(intent, token: reviewBearer)
        case .recover(let recovery): _ = try await client.recover(recovery, token: reviewBearer)
        }
        let request = try #require(await stub.requests.first)
        #expect(
            request.url?.absoluteString == reviewOrigin.absoluteString + "/v1/moderation/avatar/"
                + action.action)
        let expectedBody = try action.wire()
        #expect(request.httpMethod == "POST" && request.httpBody == expectedBody)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + reviewBearer.value)
        #expect(request.value(forHTTPHeaderField: "Content-Length") == String(request.httpBody!.count))
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(
            request.value(forHTTPHeaderField: "Cookie") == nil
                && request.value(forHTTPHeaderField: "Origin") == nil)
        #expect(
            request.cachePolicy == .reloadIgnoringLocalCacheData
                && request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    }
}

@Test func avatarReviewNativeInactiveAndMalformedBearerStopBeforeTransport() async throws {
    let f = try ReviewWireFixture()
    let stub = ReviewHTTPStub(f.queue)
    let clock = ReviewClock(f.now)
    let inactive = try GatewayAvatarReviewHTTPClient(
        configuration: .init(origin: reviewOrigin), transport: stub)
    await #expect(throws: GatewayAvatarReviewFailure.unavailable) {
        try await inactive.queue(token: reviewBearer)
    }
    let client = try reviewClient(stub, clock: clock)
    for raw in ["bad", String(repeating: "a", count: 80), String(reviewBearer.value.prefix(79)) + "!"] {
        await #expect(throws: GatewayAvatarReviewFailure.invalidInput) {
            try await client.queue(token: GatewaySecret(raw))
        }
    }
    #expect(await stub.requests.isEmpty)
}

@Test func avatarReviewNativeRejectsInvalidQueueVersionsFieldsTypesCountsAndDuplicateOwners() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    let fields = try #require(JSONSerialization.jsonObject(with: f.queue.body) as? [String: Any])
    let row = try #require((fields["items"] as? [[String: Any]])?.first)
    var cases: [[String: Any]] = [
        ["protocolVersion": 2], ["protocolVersion": true], ["schemaVersion": 2], ["schemaVersion": true],
        ["operator": true], ["items": NSNull()], ["items": [row, row]],
        ["items": Array(repeating: row, count: 21)],
    ]
    for changes: [String: Any] in [
        ["accountID": "bad"], ["requestID": "bad"], ["versionID": "bad"], ["reviewRevision": "bad"],
        ["generation": 0], ["generation": -1], ["generation": true], ["generation": 1.5],
        ["generation": 9_007_199_254_740_991], ["url": "https://private.invalid"],
    ] { cases.append(["items": [row.merging(changes) { _, n in n }]]) }
    for changes in cases {
        let stub = ReviewHTTPStub(try reviewBody(f.queue, changes: changes))
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await reviewClient(stub, clock: clock).queue(token: reviewBearer)
        }
    }
    var missing = fields
    missing.removeValue(forKey: "schemaVersion")
    await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
        try await reviewClient(ReviewHTTPStub(reviewJSON(missing)), clock: clock).queue(token: reviewBearer)
    }
}

@Test func avatarReviewNativeAllowsTwentyDistinctSafeQueueItemsAndRejectsInvalidSelections() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    let rows = (0..<20).map { n in
        [
            "accountID": UUID().uuidString.lowercased(), "requestID": f.item.requestID,
            "versionID": f.item.versionID, "generation": n + 1, "reviewRevision": f.item.reviewRevision,
        ] as [String: Any]
    }
    let stub = ReviewHTTPStub(try reviewJSON(["protocolVersion": 1, "schemaVersion": 1, "items": rows]))
    #expect(try await reviewClient(stub, clock: clock).queue(token: reviewBearer).count == 20)
    for generation in [0, -1, 9_007_199_254_740_991, Int.max] {
        #expect(throws: GatewayAvatarReviewFailure.invalidInput) {
            try GatewayAvatarReviewItem(
                accountID: f.item.accountID, requestID: f.item.requestID, versionID: f.item.versionID,
                generation: generation, reviewRevision: f.item.reviewRevision)
        }
    }
}

@Test func avatarReviewNativeInspectionCorrelatesEntireSelectionAndProof() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    for changes: [String: Any] in [
        ["schemaVersion": 2], ["schemaVersion": true], ["inspectionID": "bad"],
        ["requestID": UUID().uuidString.lowercased()], ["generation": f.item.generation + 1],
        ["generation": true], ["reviewRevision": UUID().uuidString.lowercased()],
        ["expiresAt": f.now], ["expiresAt": f.now + 90_001], ["expiresAt": true], ["operator": true],
    ] {
        let response = try reviewHeader(f.image, "x-echoes-avatar-review", changes)
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await reviewClient(ReviewHTTPStub(response), clock: clock).inspect(
                f.item, token: reviewBearer)
        }
    }
    for changes in [
        ["ownerID": UUID().uuidString.lowercased()], ["versionID": UUID().uuidString.lowercased()],
        ["variant": "thumbnail"],
    ] {
        let response = try reviewHeader(f.image, "x-echoes-avatar-manifest", changes)
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await reviewClient(ReviewHTTPStub(response), clock: clock).inspect(
                f.item, token: reviewBearer)
        }
    }
}

@Test func avatarReviewNativeRejectsCorruptDigestTruncatedAndUndecodableJPEG() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    for data in [Data(f.image.body.dropLast()), Data(repeating: 42, count: f.image.body.count)] {
        let response = GatewayAvatarHTTPResponse(status: 200, headers: f.image.headers, body: data)
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await reviewClient(ReviewHTTPStub(response), clock: clock).inspect(
                f.item, token: reviewBearer)
        }
    }
    let bad = Data([0xff, 0xd8, 0xff, 0xd9])
    let metadata = try reviewHeader(
        f.image, "x-echoes-avatar-manifest", ["byteCount": bad.count, "sha256": reviewDigest(bad)])
    var headers = metadata.headers
    headers["content-length"] = String(bad.count)
    await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
        try await reviewClient(ReviewHTTPStub(.init(status: 200, headers: headers, body: bad)), clock: clock)
            .inspect(f.item, token: reviewBearer)
    }
}

@Test func avatarReviewNativeRejectsUnsafeHeadersDuplicateCasePartialAndWrongBodies() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    for (key, value) in [
        ("content-type", "text/html"), ("content-encoding", "gzip"), ("content-range", "bytes 0-1/2"),
        ("cache-control", "public, max-age=60"), ("x-content-type-options", "none"),
        ("content-length", "256001"), ("x-echoes-avatar-review", String(repeating: " ", count: 1025)),
        ("x-echoes-avatar-manifest", String(repeating: " ", count: 2049)),
    ] {
        var headers = f.image.headers
        headers[key] = value
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await reviewClient(
                ReviewHTTPStub(.init(status: 200, headers: headers, body: f.image.body)), clock: clock
            ).inspect(f.item, token: reviewBearer)
        }
    }
    var duplicate = f.image.headers
    duplicate["Content-Type"] = "image/jpeg"
    for response in [
        GatewayAvatarHTTPResponse(status: 204, headers: f.image.headers, body: Data()),
        .init(status: 200, headers: duplicate, body: f.image.body),
        .init(status: 200, headers: reviewJSONHeaders, body: f.queue.body),
    ] {
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await reviewClient(ReviewHTTPStub(response), clock: clock).inspect(
                f.item, token: reviewBearer)
        }
    }
}

@Test func avatarReviewNativeDecisionRejectsChangedACKFieldsAndUnknownVerdicts() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    let inspection = try await reviewInspection(f)
    let intent = try GatewayAvatarReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .approved)
    for changes: [String: Any] in [
        ["protocolVersion": 2], ["schemaVersion": 2], ["inspectionID": UUID().uuidString.lowercased()],
        ["accountID": UUID().uuidString.lowercased()], ["requestID": UUID().uuidString.lowercased()],
        ["decisionID": UUID().uuidString.lowercased()], ["revision": "bad"],
        ["revision": f.item.reviewRevision], ["verdict": "rejected"],
        ["verdict": "published"], ["private": "PRIVATE-SENTINEL"],
    ] {
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await reviewClient(ReviewHTTPStub(reviewBody(f.decision, changes: changes)), clock: clock)
                .decide(intent, token: reviewBearer)
        }
    }
    #expect(throws: GatewayAvatarReviewFailure.invalidInput) {
        try GatewayAvatarReviewDecisionIntent(
            receipt: inspection.receipt, decisionID: "bad", verdict: .approved)
    }
}

@Test func avatarReviewNativeReceiptCannotChangeSessionOriginOrOutliveEitherClock() async throws {
    let f = try ReviewWireFixture()
    let inspection = try await reviewInspection(f)
    let intent = try GatewayAvatarReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .approved)
    let otherToken = try GatewaySecret(
        String(reviewBearer.value.prefix(37)) + String(repeating: "b", count: 43))
    for (token, origin) in [
        (otherToken, reviewOrigin), (reviewBearer, URL(string: "https://other.example.invalid")!),
    ] {
        let stub = ReviewHTTPStub(f.decision)
        await #expect(throws: GatewayAvatarReviewFailure.invalidInput) {
            try await reviewClient(stub, clock: ReviewClock(f.now), origin: origin).decide(
                intent, token: token)
        }
        #expect(await stub.requests.isEmpty)
    }
    for (wall, monotonic) in [(90_000, 0.0), (0, 90.0), (-1, 0.0), (0, -1.0)] {
        let clock = ReviewClock(f.now)
        let stub = ReviewHTTPStub(f.decision)
        clock.move(wall: wall, monotonic: monotonic)
        await #expect(throws: GatewayAvatarReviewFailure.stale) {
            try await reviewClient(stub, clock: clock).decide(intent, token: reviewBearer)
        }
        #expect(await stub.requests.isEmpty)
    }
}

@Test func avatarReviewNativeExpiryOrActivationLossDuringDecodeFencesPixels() async throws {
    struct Decoder: GatewayAvatarDecoding {
        let clock: ReviewClock, disable: Bool
        func decode(_ bytes: Data, manifest: AvatarManifest) async throws -> ValidatedAvatar {
            let value = try AvatarPayloadValidator.decode(bytes, manifest: manifest)
            if disable { clock.disable() } else { clock.move(monotonic: 91) }
            return value
        }
    }
    let f = try ReviewWireFixture()
    for disable in [true, false] {
        let clock = ReviewClock(f.now)
        let client = try reviewClient(
            ReviewHTTPStub(f.image), clock: clock, decoder: Decoder(clock: clock, disable: disable))
        await #expect(throws: disable ? GatewayAvatarReviewFailure.unavailable : .stale) {
            try await client.inspect(f.item, token: reviewBearer)
        }
    }
}

@Test func avatarReviewNativeActivationCancelAndRollbackAfterNetworkNeverReturnSuccess() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    let disabled = ReviewHTTPStub(f.queue) { clock.disable() }
    await #expect(throws: GatewayAvatarReviewFailure.unavailable) {
        try await reviewClient(disabled, clock: clock).queue(token: reviewBearer)
    }
    let rollback = ReviewClock(f.now)
    let stub = ReviewHTTPStub(f.queue) { rollback.move(wall: -1000) }
    await #expect(throws: GatewayAvatarReviewFailure.stale) {
        try await reviewClient(stub, clock: rollback).queue(token: reviewBearer)
    }
    let cancel = ReviewHTTPStub(f.queue) { withUnsafeCurrentTask { $0?.cancel() } }
    let task = Task { try await reviewClient(cancel, clock: ReviewClock(f.now)).queue(token: reviewBearer) }
    await #expect(throws: GatewayFailure.cancelled) { try await task.value }
}

@Test func avatarReviewNativeErrorsRequireExactCodeStatusAndRoleDenialDoesNotSignOut() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    for (code, status) in avatarReviewErrorStatus {
        let response = try reviewJSON(["protocolVersion": 1, "error": code], status: status)
        do {
            _ = try await reviewClient(ReviewHTTPStub(response), clock: clock).queue(token: reviewBearer)
            Issue.record("Error must throw")
        } catch let failure as GatewayFailure {
            #expect(["INVALID_SESSION", "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS"].contains(code))
            #expect(failure == .signInRequired)
        } catch let failure as GatewayAvatarReviewFailure {
            #expect(failure != .invalidResponse)
            if code == "AVATAR_REVIEW_SCOPE" { #expect(failure == .denied) }
        }
        let wrong = try reviewJSON(["protocolVersion": 1, "error": code], status: status == 400 ? 503 : 400)
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await reviewClient(ReviewHTTPStub(wrong), clock: clock).queue(token: reviewBearer)
        }
    }
    for fields: [String: Any] in [
        ["protocolVersion": 1, "error": "PRIVATE-SENTINEL"],
        ["protocolVersion": 1, "error": "UNAVAILABLE", "detail": "PRIVATE-SENTINEL"],
        ["protocolVersion": true, "error": "UNAVAILABLE"],
    ] {
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await reviewClient(ReviewHTTPStub(reviewJSON(fields, status: 503)), clock: clock).queue(
                token: reviewBearer)
        }
    }
}

@Test func avatarReviewNativeBoundsJSONLengthAndRetryAfterAndRedactsAllSensitiveModels() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    for (status, count) in [(200, 8193), (503, 2049)] {
        let response = GatewayAvatarHTTPResponse(
            status: status, headers: reviewJSONHeaders, body: Data(repeating: 32, count: count))
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await reviewClient(ReviewHTTPStub(response), clock: clock).queue(token: reviewBearer)
        }
    }
    for raw in ["0", "12", "86400", "86401", "1e2", "-1", "PRIVATE-SENTINEL"] {
        var headers = reviewJSONHeaders
        headers["Retry-After"] = raw
        let response = GatewayAvatarHTTPResponse(
            status: 429, headers: headers,
            body: try reviewJSON(["protocolVersion": 1, "error": "AVATAR_REVIEW_RATE"]).body)
        let seconds = ["0": 0, "12": 12, "86400": 86400][raw]
        await #expect(throws: GatewayAvatarReviewFailure.limited(retryAfterSeconds: seconds)) {
            try await reviewClient(ReviewHTTPStub(response), clock: clock).queue(token: reviewBearer)
        }
    }
    let inspection = try await reviewInspection(f)
    let intent = try GatewayAvatarReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .approved)
    let result = try await reviewClient(ReviewHTTPStub(f.decision), clock: clock).decide(
        intent, token: reviewBearer)
    for value: any CustomStringConvertible & CustomReflectable in [
        f.item, inspection, inspection.receipt, intent, result, GatewayAvatarReviewOperation.decide(intent),
    ] {
        #expect(value.description.contains("<redacted>") && value.customMirror.children.isEmpty)
        #expect(!String(reflecting: value).contains(f.item.accountID))
    }
}

@Test func avatarReviewNativeNetworkTimeConsumesReceiptLifetimeEvenWithFrozenWallClock() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    let stub = ReviewHTTPStub(f.image) { clock.move(monotonic: 70) }
    let inspection = try await reviewClient(stub, clock: clock).inspect(f.item, token: reviewBearer)
    let intent = try GatewayAvatarReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .approved)
    clock.move(monotonic: 20)
    let decision = ReviewHTTPStub(f.decision)
    await #expect(throws: GatewayAvatarReviewFailure.stale) {
        try await reviewClient(decision, clock: clock).decide(intent, token: reviewBearer)
    }
    #expect(await decision.requests.isEmpty)
}

@Test func avatarReviewNativeExpiryDuringDecisionACKNeverConfirmsOrStartsAnotherRequest() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    let inspection = try await reviewInspection(f, clock: clock)
    let intent = try GatewayAvatarReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .approved)
    let stub = ReviewHTTPStub(f.decision) { clock.move(wall: 90_000, monotonic: 90) }
    await #expect(throws: GatewayAvatarReviewFailure.stale) {
        try await reviewClient(stub, clock: clock).decide(intent, token: reviewBearer)
    }
    #expect(await stub.requests.count == 1)
}

@Test func avatarReviewNativeLostACKDoesNotRetryAndExplicitRetryKeepsExactDecisionBytes() async throws {
    actor LostACK: GatewayAvatarReviewTransport {
        var requests: [URLRequest] = []
        func send(_ request: URLRequest, operation: GatewayAvatarReviewOperation) async throws
            -> GatewayAvatarHTTPResponse
        {
            requests.append(request)
            throw URLError(.networkConnectionLost)
        }
    }
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    let inspection = try await reviewInspection(f, clock: clock)
    let intent = try GatewayAvatarReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .approved)
    let lost = LostACK()
    await #expect(throws: GatewayAvatarReviewFailure.unavailable) {
        try await reviewClient(lost, clock: clock).decide(intent, token: reviewBearer)
    }
    #expect(await lost.requests.count == 1)
    let retry = ReviewHTTPStub(f.decision)
    #expect(try await reviewClient(retry, clock: clock).decide(intent, token: reviewBearer).intent == intent)
    #expect(await lost.requests.first?.httpBody == retry.requests.first?.httpBody)
}

@Test func avatarReviewNativeRejectedDecisionIsCorrelatedWithoutPublishing() async throws {
    let f = try ReviewWireFixture()
    let clock = ReviewClock(f.now)
    let inspection = try await reviewInspection(f, clock: clock)
    let intent = try GatewayAvatarReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .rejected)
    let reply = try reviewBody(f.decision, changes: ["verdict": "rejected"])
    let result = try await reviewClient(ReviewHTTPStub(reply), clock: clock).decide(
        intent, token: reviewBearer)
    #expect(result.intent.verdict == .rejected)
    let fields = try #require(
        JSONSerialization.jsonObject(with: GatewayAvatarReviewOperation.decide(intent).wire())
            as? [String: String])
    #expect(Set(fields.keys) == Set(["inspectionID", "decisionID", "verdict"]))
}
