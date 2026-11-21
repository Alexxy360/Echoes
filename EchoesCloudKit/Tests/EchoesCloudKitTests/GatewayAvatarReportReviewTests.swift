import CryptoKit
import Foundation
import Testing

@testable import EchoesCloudKit

let reportedPhotoOrigin = URL(string: "https://photo-report-review.example.invalid")!
struct ReportedPhotoWireFixture: Sendable {
    let now: Int, item: GatewayAvatarReportReviewItem, decisionID: String
    let cases: [String: GatewayAvatarReportReviewHTTPResponse]
    let recovery: GatewayAvatarReportReviewRecoveryIntent
    init() throws {
        let directory = "Fixtures/avatar-report-review"
        let url = try #require(
            Bundle.module.url(forResource: "responses", withExtension: "json", subdirectory: directory))
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        now = try #require(root["nowMilliseconds"] as? Int)
        var replies: [String: GatewayAvatarReportReviewHTTPResponse] = [:]
        let rows = try #require(root["cases"] as? [[String: Any]])
        for row in rows {
            let label = try #require(row["label"] as? String)
            let body: Data
            if let file = row["frame"] as? String {
                let u = try #require(
                    Bundle.module.url(forResource: file, withExtension: nil, subdirectory: directory))
                body = try Data(contentsOf: u)
            } else {
                body = try JSONSerialization.data(withJSONObject: row["body"]!)
            }
            replies[label] = .init(
                status: try #require(row["status"] as? Int),
                headers: try #require(row["headers"] as? [String: String]), body: body)
        }
        cases = replies
        let (metadata, _) = try reportedPhotoParts(replies["inspect-photo"]!)
        item = try reportedPhotoItem(metadata)
        let row = try #require(rows.first { $0["label"] as? String == "recover-confirmed" })
        let input = try #require(row["input"] as? [String: Any])
        decisionID = try #require(input["decisionID"] as? String)
        recovery = try .init(
            reportID: item.reportID, decisionID: decisionID, verdict: .hidePhoto,
            contentHash: #require(input["contentHash"] as? String))
    }
    var queue: GatewayAvatarReportReviewHTTPResponse { cases["queue-open"]! }
    var inspection: GatewayAvatarReportReviewHTTPResponse { cases["inspect-photo"]! }
    var decision: GatewayAvatarReportReviewHTTPResponse { cases["decide-hidden"]! }
}
func reportedPhotoItem(_ fields: [String: Any]) throws -> GatewayAvatarReportReviewItem {
    try .init(
        reportID: #require(fields["reportID"] as? String),
        createdAtMilliseconds: #require(fields["createdAt"] as? Int),
        expiresAtMilliseconds: #require(fields["expiresAt"] as? Int))
}
func reportedPhotoParts(_ response: GatewayAvatarReportReviewHTTPResponse) throws -> ([String: Any], Data) {
    let data = response.body
    let n = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    let root = try #require(
        JSONSerialization.jsonObject(with: Data(data.dropFirst(4).prefix(n))) as? [String: Any])
    return (root, Data(data.dropFirst(4 + n)))
}
func reportedPhotoFrame(_ root: [String: Any], image: Data, headers: [String: String]? = nil) throws
    -> GatewayAvatarReportReviewHTTPResponse
{
    try reportedPhotoRawFrame(
        JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), image: image, headers: headers)
}
func reportedPhotoRawFrame(_ metadata: Data, image: Data, headers: [String: String]? = nil) throws
    -> GatewayAvatarReportReviewHTTPResponse
{
    let n = metadata.count
    var data = Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
    data.append(metadata)
    data.append(image)
    var fields =
        headers ?? [
            "Content-Type": avatarReportReviewInspectionType, "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff",
        ]
    for k in Array(fields.keys) where k.lowercased() == "content-length" { fields.removeValue(forKey: k) }
    fields["Content-Length"] = String(data.count)
    return .init(status: 200, headers: fields, body: data)
}
func reportedPhotoJSON(_ fields: [String: Any], status: Int = 200) throws
    -> GatewayAvatarReportReviewHTTPResponse
{
    .init(
        status: status, headers: reviewJSONHeaders, body: try JSONSerialization.data(withJSONObject: fields))
}
func reportedPhotoBody(_ response: GatewayAvatarReportReviewHTTPResponse, _ changes: [String: Any]) throws
    -> GatewayAvatarReportReviewHTTPResponse
{
    var fields = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    fields.merge(changes) { _, n in n }
    return try reportedPhotoJSON(fields, status: response.status)
}
actor ReportedPhotoHTTPStub: GatewayAvatarReportReviewTransport {
    let response: GatewayAvatarReportReviewHTTPResponse
    let effect: (@Sendable () async -> Void)?
    private(set) var requests: [URLRequest] = []
    init(_ response: GatewayAvatarReportReviewHTTPResponse, effect: (@Sendable () async -> Void)? = nil) {
        self.response = response
        self.effect = effect
    }
    func send(_ request: URLRequest, operation: GatewayAvatarReportReviewOperation) async throws
        -> GatewayAvatarReportReviewHTTPResponse
    {
        requests.append(request)
        await effect?()
        return response
    }
}
actor ReportedPhotoDecoder: GatewayAvatarDecoding {
    private(set) var calls = 0
    let effect: (@Sendable () async -> Void)?
    init(effect: (@Sendable () async -> Void)? = nil) { self.effect = effect }
    func decode(_ bytes: Data, manifest: AvatarManifest) async throws -> ValidatedAvatar {
        calls += 1
        await effect?()
        return try await NativeGatewayAvatarDecoder().decode(bytes, manifest: manifest)
    }
}
func reportedPhotoClient(
    _ transport: any GatewayAvatarReportReviewTransport, clock: ReviewClock,
    origin: URL = reportedPhotoOrigin,
    decoder: any GatewayAvatarDecoding = NativeGatewayAvatarDecoder()
) throws -> GatewayAvatarReportReviewHTTPClient {
    try .init(
        configuration: .init(origin: origin), transport: transport, decoder: decoder,
        isEnabled: { clock.enabled() }, date: { clock.date() }, uptime: { clock.up() })
}
func reportedPhotoInspection(_ f: ReportedPhotoWireFixture, clock: ReviewClock? = nil) async throws
    -> GatewayAvatarReportReviewInspection
{
    try await reportedPhotoClient(ReportedPhotoHTTPStub(f.inspection), clock: clock ?? ReviewClock(f.now))
        .inspect(f.item, token: reviewBearer)
}
@Test func avatarReportReviewNativeConcreteQueueFrameDecisionReplayAndTerminalOutcomes() async throws {
    let f = try ReportedPhotoWireFixture()
    let clock = ReviewClock(f.now)
    let page = try await reportedPhotoClient(ReportedPhotoHTTPStub(f.queue), clock: clock).queue(
        after: nil, token: reviewBearer)
    #expect(page.items == [f.item] && page.next == nil)
    let inspection = try await reportedPhotoInspection(f, clock: clock)
    let avatar = try #require(inspection.avatar)
    let target = try #require(inspection.receipt.photoTarget)
    #expect(inspection.reason == "PRIVATE_SYNTHETIC_PHOTO_REASON")
    #expect(avatar.image.width == 256 && avatar.image.height == 128)
    #expect(
        avatar.manifest.reference.ownerID == target.ownerID
            && avatar.manifest.reference.versionID == target.versionID && target.publicationGeneration == 1)
    let intent = try GatewayAvatarReportReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .hidePhoto)
    let decision = try await reportedPhotoClient(ReportedPhotoHTTPStub(f.decision), clock: clock).decide(
        intent, token: reviewBearer)
    #expect(
        try await reportedPhotoClient(ReportedPhotoHTTPStub(f.cases["decide-replay"]!), clock: clock).decide(
            intent, token: reviewBearer) == decision)
    for name in [
        "recover-not-applied", "recover-confirmed", "recover-superseded", "recover-retired", "retire-pending",
        "retire-already-confirmed",
    ] {
        let response = f.cases[name]!
        let body = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let recovery = try GatewayAvatarReportReviewRecoveryIntent(
            reportID: f.item.reportID, decisionID: #require(body["decisionID"] as? String),
            verdict: .hidePhoto, contentHash: f.recovery.contentHash)
        clock.move(wall: 120_000, monotonic: 120)
        let client = try reportedPhotoClient(ReportedPhotoHTTPStub(response), clock: clock)
        let result =
            try await
            (name.hasPrefix("retire")
            ? client.retire(recovery, token: reviewBearer) : client.recover(recovery, token: reviewBearer))
        #expect(result.intent == recovery)
        #expect(result.outcome.isTerminal == (name != "recover-not-applied"))
    }
}
@Test func avatarReportReviewNativeMissingOriginalNeverSubstitutesImageOrAllowsHide() async throws {
    let f = try ReportedPhotoWireFixture()
    let response = try #require(f.cases["inspect-missing"])
    let (root, _) = try reportedPhotoParts(response)
    let item = try reportedPhotoItem(root)
    let decoder = ReportedPhotoDecoder()
    let clock = ReviewClock(f.now)
    let result = try await reportedPhotoClient(
        ReportedPhotoHTTPStub(response), clock: clock, decoder: decoder
    )
    .inspect(item, token: reviewBearer)
    #expect(result.avatar == nil && result.receipt.photoTarget == nil)
    #expect(await decoder.calls == 0)
    #expect(throws: GatewayAvatarReportReviewFailure.invalidInput) {
        try GatewayAvatarReportReviewDecisionIntent(
            receipt: result.receipt, decisionID: f.decisionID, verdict: .hidePhoto)
    }
    #expect(
        try GatewayAvatarReportReviewDecisionIntent(
            receipt: result.receipt, decisionID: f.decisionID, verdict: .dismiss
        ).verdict == .dismiss)
    let smuggled = try reportedPhotoFrame(root, image: Data([1]))
    await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
        try await reportedPhotoClient(ReportedPhotoHTTPStub(smuggled), clock: clock, decoder: decoder)
            .inspect(
                item, token: reviewBearer)
    }
    #expect(await decoder.calls == 0)
}
@Test func avatarReportReviewNativeRejectsEntireMalformedFrameBeforeDecoder() async throws {
    let f = try ReportedPhotoWireFixture()
    let (original, image) = try reportedPhotoParts(f.inspection)
    var invalid: [GatewayAvatarReportReviewHTTPResponse] = []
    for change: [String: Any] in [
        ["protocolVersion": 2], ["schemaVersion": true], ["extra": "private"],
        ["reportID": "community-v1-avatarreport-" + String(repeating: "a", count: 64)],
        ["inspectionID": "bad"], ["inspectionExpiresAt": f.now], ["inspectionExpiresAt": f.now + 90_001],
        ["createdAt": f.now + 1], ["expiresAt": f.now + 1],
        ["contentHash": String(repeating: "A", count: 64)],
        ["reason": " leading"], ["reason": "e\u{301}"], ["reason": String(repeating: "😀", count: 251)],
        ["reason": "bad\u{202e}direction"], ["photo": NSNull()],
    ] {
        invalid.append(try reportedPhotoFrame(original.merging(change) { _, n in n }, image: image))
    }
    invalid.append(try reportedPhotoRawFrame(Data([255]), image: image))
    invalid.append(try reportedPhotoRawFrame(Data("{\"reason\":\"\\uD800\"}".utf8), image: image))
    var extra = image
    extra.append(0)
    invalid.append(try reportedPhotoFrame(original, image: extra))
    var damaged = image
    damaged[damaged.count / 2] ^= 1
    invalid.append(try reportedPhotoFrame(original, image: damaged))
    for response in invalid {
        let decoder = ReportedPhotoDecoder()
        await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
            try await reportedPhotoClient(
                ReportedPhotoHTTPStub(response), clock: ReviewClock(f.now), decoder: decoder
            ).inspect(f.item, token: reviewBearer)
        }
        #expect(await decoder.calls == 0)
    }
}
@Test func avatarReportReviewNativeRejectsManifestTargetRebindingAndBoundedPrefix() async throws {
    let f = try ReportedPhotoWireFixture()
    let (root, image) = try reportedPhotoParts(f.inspection)
    let photo = try #require(root["photo"] as? [String: Any])
    let manifest = try #require(photo["manifest"] as? [String: Any])
    for patch: [String: Any] in [
        ["ownerID": "6a000000-0000-4000-8000-000000000001"],
        ["versionID": "6a000000-0000-4000-8000-000000000002"],
        ["publicationGeneration": 0], ["publicationGeneration": 9_007_199_254_740_991], ["extra": true],
        ["manifest": manifest.merging(["variant": "thumbnail"]) { _, n in n }],
        ["manifest": manifest.merging(["byteCount": 256001]) { _, n in n }],
        ["manifest": manifest.merging(["width": 513]) { _, n in n }],
        ["manifest": manifest.merging(["sha256": String(repeating: "0", count: 64)]) { _, n in n }],
    ] {
        let response = try reportedPhotoFrame(
            root.merging(["photo": photo.merging(patch) { _, n in n }]) { _, n in n }, image: image)
        await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
            try await reportedPhotoClient(ReportedPhotoHTTPStub(response), clock: ReviewClock(f.now)).inspect(
                f.item, token: reviewBearer)
        }
    }
    for data in [
        Data(), Data([0, 0, 0]), Data([0, 0, 48, 1]), Data([255, 255, 255, 255]),
        Data(f.inspection.body.dropLast()), Data(repeating: 0, count: 268293),
    ] {
        #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
            try AvatarReportReviewFrame(data, item: f.item, now: f.now)
        }
    }
}
@Test func avatarReportReviewNativeActualRGBDecoderRejectsDimensionsAndMalformedJPEGWithMatchingDigest()
    async throws
{
    let f = try ReportedPhotoWireFixture()
    let (root, image) = try reportedPhotoParts(f.inspection)
    let photo = try #require(root["photo"] as? [String: Any])
    let manifest = try #require(photo["manifest"] as? [String: Any])
    let invalidImage = Data([255, 216, 1, 2, 3, 4, 255, 217])
    for (bytes, patch) in [
        (image, ["width": 257] as [String: Any]),
        (invalidImage, ["byteCount": invalidImage.count, "sha256": reviewDigest(invalidImage)]),
    ] {
        let response = try reportedPhotoFrame(
            root.merging([
                "photo": photo.merging(["manifest": manifest.merging(patch) { _, n in n }]) { _, n in n }
            ]) { _, n in n }, image: bytes)
        let decoder = ReportedPhotoDecoder()
        await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
            try await reportedPhotoClient(
                ReportedPhotoHTTPStub(response), clock: ReviewClock(f.now), decoder: decoder
            ).inspect(f.item, token: reviewBearer)
        }
        #expect(await decoder.calls == 1)
    }
}
@Test func avatarReportReviewNativeClosesAfterNetworkAndDecoderActivationOrClockChanges() async throws {
    let f = try ReportedPhotoWireFixture()
    for phase in 0..<4 {
        let clock = ReviewClock(f.now)
        let transport = ReportedPhotoHTTPStub(
            f.inspection,
            effect: { if phase == 0 { clock.disable() } else { clock.move(wall: 100, monotonic: 0.1) } })
        let decoder = ReportedPhotoDecoder(effect: {
            if phase == 1 { clock.disable() }
            if phase == 2 { clock.move(wall: -50, monotonic: -0.05) }
            if phase == 3 { clock.move(wall: 15_000, monotonic: 15) }
        })
        await #expect(throws: phase < 2 ? GatewayAvatarReportReviewFailure.unavailable : .stale) {
            try await reportedPhotoClient(transport, clock: clock, decoder: decoder).inspect(
                f.item, token: reviewBearer)
        }
        #expect(await decoder.calls == (phase == 0 ? 0 : 1))
    }
}
@Test func avatarReportReviewNativeRejectsCrossDomainIDsAndClosedWireContainsOnlyExpectedMetadata()
    async throws
{
    let f = try ReportedPhotoWireFixture()
    let inspection = try await reportedPhotoInspection(f)
    let intent = try GatewayAvatarReportReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .hidePhoto)
    for value in [
        "community-v1-report-" + String(repeating: "a", count: 64),
        "community-v1-avatarreport-" + String(repeating: "A", count: 64),
    ] {
        #expect(throws: GatewayAvatarReportReviewFailure.invalidInput) {
            try GatewayAvatarReportReviewCursor(value)
        }
    }
    for (operation, keys) in [
        (GatewayAvatarReportReviewOperation.queue(after: nil), ["after"] as Set<String>),
        (.inspect(f.item), ["reportID"]), (.decide(intent), ["inspectionID", "decisionID", "verdict"]),
        (.recover(f.recovery), ["reportID", "decisionID", "verdict", "contentHash"]),
        (.retire(f.recovery), ["reportID", "decisionID", "verdict", "contentHash"]),
    ] {
        let object = try #require(JSONSerialization.jsonObject(with: operation.wire()) as? [String: Any])
        #expect(Set(object.keys) == keys)
        #expect(!String(describing: operation).contains(f.item.reportID))
    }
    #expect(!String(describing: inspection).contains(inspection.reason))
    #expect(
        Mirror(reflecting: inspection).children.isEmpty
            && Mirror(reflecting: inspection.receipt).children.isEmpty)
}
@Test func avatarReportReviewNativeDefaultOffInvalidTokenAndExpiredReceiptNeverDispatch() async throws {
    let f = try ReportedPhotoWireFixture()
    let stub = ReportedPhotoHTTPStub(f.queue)
    let clock = ReviewClock(f.now)
    let off = try GatewayAvatarReportReviewHTTPClient(
        configuration: .init(origin: reportedPhotoOrigin), transport: stub)
    await #expect(throws: GatewayAvatarReportReviewFailure.unavailable) {
        try await off.queue(after: nil, token: reviewBearer)
    }
    await #expect(throws: GatewayAvatarReportReviewFailure.invalidInput) {
        try await reportedPhotoClient(stub, clock: clock).queue(after: nil, token: GatewaySecret("bad"))
    }
    let result = try await reportedPhotoInspection(f)
    let intent = try GatewayAvatarReportReviewDecisionIntent(
        receipt: result.receipt, decisionID: f.decisionID, verdict: .hidePhoto)
    clock.move(wall: 90_000, monotonic: 90)
    await #expect(throws: GatewayAvatarReportReviewFailure.stale) {
        try await reportedPhotoClient(stub, clock: clock).decide(intent, token: reviewBearer)
    }
    #expect(await stub.requests.isEmpty)
}
@Test func avatarReportReviewNativeOutcomeCannotRebindIdentityOrTreatNotAppliedAsRetired() async throws {
    let f = try ReportedPhotoWireFixture()
    for patch: [String: Any] in [
        ["reportID": "community-v1-avatarreport-" + String(repeating: "a", count: 64)],
        ["decisionID": "6a000000-0000-4000-8000-000000000001"], ["verdict": "dismiss"],
        ["contentHash": String(repeating: "0", count: 64)], ["revision": NSNull()], ["outcome": "unknown"],
    ] {
        let response = try reportedPhotoBody(f.cases["recover-confirmed"]!, patch)
        await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
            try await reportedPhotoClient(ReportedPhotoHTTPStub(response), clock: ReviewClock(f.now)).recover(
                f.recovery, token: reviewBearer)
        }
    }
    await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
        try await reportedPhotoClient(
            ReportedPhotoHTTPStub(f.cases["recover-not-applied"]!), clock: ReviewClock(f.now)
        ).retire(f.recovery, token: reviewBearer)
    }
    #expect(!GatewayAvatarReportReviewOutcome.notApplied.isTerminal)
}
@Test func avatarReportReviewNativeQueueRequiresStrictOrderDatesLimitsAndAdvancingCursor() async throws {
    let f = try ReportedPhotoWireFixture()
    let fields = try #require(JSONSerialization.jsonObject(with: f.queue.body) as? [String: Any])
    let row = try #require((fields["items"] as? [[String: Any]])?.first)
    for patch: [String: Any] in [
        ["items": [row, row]], ["items": Array(repeating: row, count: 21)],
        ["items": [row.merging(["createdAt": f.now + 1]) { _, n in n }]],
        ["items": [row.merging(["extra": true]) { _, n in n }]], ["after": "bad"], ["extra": "leak"],
    ] {
        let response = try reportedPhotoBody(f.queue, patch)
        await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
            try await reportedPhotoClient(ReportedPhotoHTTPStub(response), clock: ReviewClock(f.now)).queue(
                after: nil, token: reviewBearer)
        }
    }
    let after = try GatewayAvatarReportReviewCursor(f.item.reportID)
    let response = try reportedPhotoJSON([
        "protocolVersion": 1, "schemaVersion": 1, "items": [], "after": after.value,
    ])
    await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
        try await reportedPhotoClient(ReportedPhotoHTTPStub(response), clock: ReviewClock(f.now)).queue(
            after: after, token: reviewBearer)
    }
}
@Test func avatarReportReviewNativeSignInRequiredOnlyForExactNative401Pair() async throws {
    let f = try ReportedPhotoWireFixture()
    for (status, code, expected): (Int, String, GatewayAvatarReportReviewFailure?) in [
        (401, "INVALID_SESSION", nil), (403, "AVATAR_REPORT_REVIEW_SCOPE", .denied),
        (403, "INVALID_SESSION", .invalidResponse), (503, "AVATAR_REPORT_REVIEW_UNAVAILABLE", .unavailable),
        (200, "INVALID_SESSION", .invalidResponse),
    ] {
        let response = try reportedPhotoJSON(["protocolVersion": 1, "error": code], status: status)
        if let expected {
            await #expect(throws: expected) {
                try await reportedPhotoClient(ReportedPhotoHTTPStub(response), clock: ReviewClock(f.now))
                    .queue(
                        after: nil, token: reviewBearer)
            }
        } else {
            await #expect(throws: GatewayFailure.signInRequired) {
                try await reportedPhotoClient(ReportedPhotoHTTPStub(response), clock: ReviewClock(f.now))
                    .queue(
                        after: nil, token: reviewBearer)
            }
        }
    }
}

@Test func avatarReportReviewNativeReasonUTF16BoundaryAndLoneSurrogateAreValidatedInCompleteMetadata()
    async throws
{
    let f = try ReportedPhotoWireFixture()
    let (root, image) = try reportedPhotoParts(f.inspection)
    let reason = String(repeating: "😀", count: 250)
    let response = try reportedPhotoFrame(root.merging(["reason": reason]) { _, n in n }, image: image)
    let result = try await reportedPhotoClient(ReportedPhotoHTTPStub(response), clock: ReviewClock(f.now))
        .inspect(f.item, token: reviewBearer)
    #expect(result.reason == reason && result.reason.utf16.count == 500 && result.avatar != nil)
    let json = String(
        data: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), encoding: .utf8)!
    let invalid = json.replacingOccurrences(of: "PRIVATE_SYNTHETIC_PHOTO_REASON", with: "\\uD800")
    #expect(invalid != json)
    let malformed = try reportedPhotoRawFrame(Data(invalid.utf8), image: image)
    await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
        try await reportedPhotoClient(ReportedPhotoHTTPStub(malformed), clock: ReviewClock(f.now)).inspect(
            f.item, token: reviewBearer)
    }
}
