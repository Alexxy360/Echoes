import CryptoKit
import Foundation
import Testing

@testable import EchoesCloudKit

let ownerPreviewBearer = try! GatewaySecret(
    "6b000000-0000-4000-8000-000000000099." + String(repeating: "a", count: 43))
let ownerPreviewOrigin = URL(string: "https://owner-preview.example.invalid")!

struct OwnerPreviewWireFixture: Sendable {
    let now: Int
    let query: GatewayAvatarOwnerPreviewQuery
    let cases: [String: GatewayAvatarHTTPResponse]
    let inputs: [String: GatewayAvatarOwnerPreviewQuery]
    init() throws {
        let directory = "Fixtures/avatar-owner-preview"
        let json = try #require(
            Bundle.module.url(forResource: "responses", withExtension: "json", subdirectory: directory))
        let jpg = try #require(
            Bundle.module.url(forResource: "image", withExtension: "jpg", subdirectory: directory))
        let bytes = try Data(contentsOf: jpg)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["imageSHA256"] as? String == ownerPreviewDigest(bytes))
        now = try #require(object["nowMilliseconds"] as? Int)
        let selection = try #require(object["selection"] as? [String: Any])
        let owner = try #require(selection["ownerID"] as? String)
        func query(_ value: [String: Any]) throws -> GatewayAvatarOwnerPreviewQuery {
            try .init(
                ownerID: owner,
                selection: .init(
                    requestID: #require(value["requestID"] as? String),
                    versionID: #require(value["versionID"] as? String),
                    generation: #require(value["generation"] as? Int),
                    reviewRevision: #require(value["reviewRevision"] as? String)))
        }
        self.query = try query(selection)
        var replies: [String: GatewayAvatarHTTPResponse] = [:]
        var queries: [String: GatewayAvatarOwnerPreviewQuery] = [:]
        for row in try #require(object["cases"] as? [[String: Any]]) {
            let label = try #require(row["label"] as? String)
            queries[label] = try query(#require(row["input"] as? [String: Any]))
            replies[label] = .init(
                status: try #require(row["status"] as? Int),
                headers: try #require(row["headers"] as? [String: String]),
                body: row["image"] != nil ? bytes : try JSONSerialization.data(withJSONObject: row["body"]!))
        }
        cases = replies
        inputs = queries
    }
    var image: GatewayAvatarHTTPResponse { cases["approved-unpublished"]! }
}
func ownerPreviewDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func ownerPreviewJSON(_ body: [String: Any], status: Int) throws -> GatewayAvatarHTTPResponse {
    .init(
        status: status,
        headers: [
            "Content-Type": "application/json", "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ],
        body: try JSONSerialization.data(withJSONObject: body))
}
actor OwnerPreviewHTTPStub: GatewayAvatarOwnerPreviewTransport {
    let response: GatewayAvatarHTTPResponse
    let effect: (@Sendable () async -> Void)?
    var requests: [URLRequest] = []
    init(_ response: GatewayAvatarHTTPResponse, effect: (@Sendable () async -> Void)? = nil) {
        self.response = response
        self.effect = effect
    }
    func send(_ request: URLRequest, query: GatewayAvatarOwnerPreviewQuery) async throws
        -> GatewayAvatarHTTPResponse
    {
        requests.append(request)
        await effect?()
        return response
    }
}
final class OwnerPreviewClock: @unchecked Sendable {
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
    func stamp() throws -> AvatarOwnerPreviewStamp { try .init(date: date(), uptime: up()) }
}
func ownerPreviewClient(
    _ transport: any GatewayAvatarOwnerPreviewTransport, clock: OwnerPreviewClock,
    decoder: any GatewayAvatarDecoding = NativeGatewayAvatarDecoder()
) throws -> GatewayAvatarOwnerPreviewHTTPClient {
    try .init(
        configuration: .init(origin: ownerPreviewOrigin), transport: transport, decoder: decoder,
        isEnabled: { clock.enabled() }, date: { clock.date() }, uptime: { clock.up() })
}

@Test func ownerPreviewNativeDecodesConcreteApprovedAndReapprovedUnpublishedResponses() async throws {
    let f = try OwnerPreviewWireFixture()
    for label in ["approved-unpublished", "reapproved-unpublished"] {
        let stub = OwnerPreviewHTTPStub(f.cases[label]!)
        let clock = OwnerPreviewClock(f.now)
        let query = f.inputs[label]!
        let client = try ownerPreviewClient(stub, clock: clock)
        let result = try await client.preview(query, token: ownerPreviewBearer)
        #expect(result.query == query && result.avatar.manifest.reference.ownerID == query.ownerID)
        #expect(
            result.avatar.manifest.reference.versionID == query.selection.versionID
                && result.avatar.manifest.variant == .image)
        #expect(result.avatar.image.width == result.avatar.manifest.width)
        try result.validate(
            query: query, origin: client.origin, token: ownerPreviewBearer, stamp: clock.stamp())
        let request = try #require(await stub.requests.first)
        #expect(request.url?.path == "/v1/community/avatar/preview" && request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(
            Set(fields.keys) == ["requestID", "versionID", "generation", "reviewRevision"]
                && body.count <= 512)
        #expect(fields["reviewRevision"] as? String == query.selection.reviewRevision)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + ownerPreviewBearer.value)
        #expect(request.value(forHTTPHeaderField: "Content-Length") == String(body.count))
        #expect(
            request.value(forHTTPHeaderField: "Cookie") == nil
                && request.value(forHTTPHeaderField: "Origin") == nil)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }
}

@Test func ownerPreviewNativeDecodesAllConcreteServerRejectionsWithoutReturningPixels() async throws {
    let f = try OwnerPreviewWireFixture()
    for label in ["other-account-denied", "old-revision-denied", "cleared-denied"] {
        await #expect(throws: GatewayAvatarFailure.notFound) {
            try await ownerPreviewClient(
                OwnerPreviewHTTPStub(f.cases[label]!), clock: OwnerPreviewClock(f.now)
            ).preview(f.inputs[label]!, token: ownerPreviewBearer)
        }
    }
    await #expect(throws: GatewayFailure.signInRequired) {
        try await ownerPreviewClient(
            OwnerPreviewHTTPStub(f.cases["invalid-session"]!), clock: OwnerPreviewClock(f.now)
        ).preview(f.query, token: ownerPreviewBearer)
    }
    await #expect(throws: GatewayAvatarFailure.invalidInput) {
        try await ownerPreviewClient(
            OwnerPreviewHTTPStub(f.cases["client-owner-denied"]!), clock: OwnerPreviewClock(f.now)
        ).preview(f.query, token: ownerPreviewBearer)
    }
    await #expect(throws: GatewayAvatarFailure.unavailable) {
        try await ownerPreviewClient(
            OwnerPreviewHTTPStub(f.cases["feature-disabled"]!), clock: OwnerPreviewClock(f.now)
        ).preview(f.query, token: ownerPreviewBearer)
    }
}

@Test func ownerPreviewNativeDefaultActivationBadBearerAndCancellationStopBeforeTransport() async throws {
    let f = try OwnerPreviewWireFixture()
    let stub = OwnerPreviewHTTPStub(f.image)
    let inactive = try GatewayAvatarOwnerPreviewHTTPClient(
        configuration: .init(origin: ownerPreviewOrigin), transport: stub)
    await #expect(throws: GatewayAvatarFailure.unavailable) {
        try await inactive.preview(f.query, token: ownerPreviewBearer)
    }
    let active = try ownerPreviewClient(stub, clock: OwnerPreviewClock(f.now))
    await #expect(throws: GatewayAvatarFailure.invalidInput) {
        try await active.preview(f.query, token: GatewaySecret("bad"))
    }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await active.preview(f.query, token: ownerPreviewBearer)
    }
    await #expect(throws: GatewayFailure.cancelled) { try await cancelled.value }
    #expect(await stub.requests.isEmpty)
    #expect(throws: GatewayAvatarFailure.invalidInput) {
        try GatewayAvatarOwnerPreviewQuery(ownerID: "NOT-A-UUID", selection: f.query.selection)
    }
}

@Test func ownerPreviewNativeCorrelatesEverySelectionFieldAndExactProofSchema() async throws {
    let f = try OwnerPreviewWireFixture()
    for changes: [String: Any] in [
        ["requestID": UUID().uuidString.lowercased()], ["versionID": UUID().uuidString.lowercased()],
        ["reviewRevision": UUID().uuidString.lowercased()], ["generation": f.query.selection.generation + 1],
        ["schemaVersion": 2], ["generation": true], ["consentVersion": 1], ["ownerID": f.query.ownerID],
        ["reviewRevision": NSNull()],
    ] {
        let response = try reviewHeader(f.image, "x-echoes-avatar-selection", changes)
        await #expect(throws: GatewayAvatarFailure.invalidResponse) {
            try await ownerPreviewClient(OwnerPreviewHTTPStub(response), clock: OwnerPreviewClock(f.now))
                .preview(f.query, token: ownerPreviewBearer)
        }
    }
    let wrongOwner = try reviewHeader(
        f.image, "x-echoes-avatar-manifest", ["ownerID": UUID().uuidString.lowercased()])
    let wrongVersion = try reviewHeader(
        f.image, "x-echoes-avatar-manifest", ["versionID": UUID().uuidString.lowercased()])
    for response in [wrongOwner, wrongVersion] {
        await #expect(throws: GatewayAvatarFailure.invalidResponse) {
            try await ownerPreviewClient(OwnerPreviewHTTPStub(response), clock: OwnerPreviewClock(f.now))
                .preview(f.query, token: ownerPreviewBearer)
        }
    }
}

@Test func ownerPreviewNativeRejectsMissingOversizedAliasedAndUnsafeBinaryHeaders() async throws {
    let f = try OwnerPreviewWireFixture()
    for changes: [String: String?] in [
        ["content-type": "application/json"], ["cache-control": "public, max-age=3600"],
        ["content-length": "1"],
        ["content-length": nil], ["content-range": "bytes 0-10/10"], ["content-encoding": "gzip"],
        ["x-content-type-options": nil], ["x-echoes-avatar-selection": nil], ["x-echoes-avatar-review": "{}"],
        ["x-echoes-avatar-selection": String(repeating: "a", count: 513)],
        ["x-echoes-avatar-manifest": "żółw"],
        ["Content-Type": "image/jpeg"],
    ] {
        var headers = Dictionary(
            uniqueKeysWithValues: f.image.headers.map { ($0.key.lowercased(), $0.value) })
        for (key, value) in changes { headers[key] = value }
        let response = GatewayAvatarHTTPResponse(status: 200, headers: headers, body: f.image.body)
        await #expect(throws: GatewayAvatarFailure.invalidResponse) {
            try await ownerPreviewClient(OwnerPreviewHTTPStub(response), clock: OwnerPreviewClock(f.now))
                .preview(f.query, token: ownerPreviewBearer)
        }
    }
    let noImage = GatewayAvatarHTTPResponse(status: 204, headers: f.image.headers, body: Data())
    await #expect(throws: GatewayAvatarFailure.invalidResponse) {
        try await ownerPreviewClient(OwnerPreviewHTTPStub(noImage), clock: OwnerPreviewClock(f.now)).preview(
            f.query, token: ownerPreviewBearer)
    }
}

@Test func ownerPreviewNativeRejectsCorruptTruncatedAndUndecodableJPEGDespiteMatchingHash() async throws {
    let f = try OwnerPreviewWireFixture()
    for bytes in [Data(f.image.body.dropLast()), Data(repeating: 0, count: f.image.body.count)] {
        let response = GatewayAvatarHTTPResponse(status: 200, headers: f.image.headers, body: bytes)
        await #expect(throws: GatewayAvatarFailure.invalidResponse) {
            try await ownerPreviewClient(OwnerPreviewHTTPStub(response), clock: OwnerPreviewClock(f.now))
                .preview(f.query, token: ownerPreviewBearer)
        }
    }
    let malformed = Data([0xff, 0xd8, 0xff, 0xd9])
    var response = try reviewHeader(
        f.image, "x-echoes-avatar-manifest",
        ["sha256": ownerPreviewDigest(malformed), "byteCount": 4, "width": 1, "height": 1])
    var headers = response.headers
    headers["content-length"] = "4"
    response = .init(status: 200, headers: headers, body: malformed)
    await #expect(throws: GatewayAvatarFailure.invalidResponse) {
        try await ownerPreviewClient(OwnerPreviewHTTPStub(response), clock: OwnerPreviewClock(f.now)).preview(
            f.query, token: ownerPreviewBearer)
    }
}

@Test func ownerPreviewNativeRejectsErrorCodeStatusSchemaEncodingAndBodyLimitMismatch() async throws {
    let f = try OwnerPreviewWireFixture()
    let invalid = [
        try ownerPreviewJSON(["protocolVersion": 1, "error": "INVALID_SESSION"], status: 403),
        try ownerPreviewJSON(["protocolVersion": 1, "error": "UNKNOWN"], status: 503),
        try ownerPreviewJSON(["protocolVersion": true, "error": "INVALID_SESSION"], status: 401),
        try ownerPreviewJSON(
            ["protocolVersion": 1, "error": "INVALID_SESSION", "private": true], status: 401),
        GatewayAvatarHTTPResponse(
            status: 503, headers: reviewJSONHeaders, body: Data(repeating: 32, count: 2049)),
        GatewayAvatarHTTPResponse(status: 503, headers: reviewJSONHeaders, body: Data([0xff])),
    ]
    for response in invalid {
        await #expect(throws: GatewayAvatarFailure.invalidResponse) {
            try await ownerPreviewClient(OwnerPreviewHTTPStub(response), clock: OwnerPreviewClock(f.now))
                .preview(f.query, token: ownerPreviewBearer)
        }
    }
}

@Test func ownerPreviewNativeRateLimitAndAuthAreDistinctAndRetryIsBounded() async throws {
    let f = try OwnerPreviewWireFixture()
    for raw in ["5", "86401", "-1", "private", "1000000"] {
        var response = try ownerPreviewJSON(["protocolVersion": 1, "error": "RATE_LIMITED"], status: 429)
        var headers = response.headers
        headers["Retry-After"] = raw
        response = .init(status: response.status, headers: headers, body: response.body)
        await #expect(throws: GatewayAvatarFailure.limited(retryAfterSeconds: raw == "5" ? 5 : nil)) {
            try await ownerPreviewClient(OwnerPreviewHTTPStub(response), clock: OwnerPreviewClock(f.now))
                .preview(f.query, token: ownerPreviewBearer)
        }
    }
    for error in ["AVATAR_READ_STALE", "REAUTH_REQUIRED", "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS"] {
        let response = try ownerPreviewJSON(
            ["protocolVersion": 1, "error": error], status: avatarOwnerPreviewErrorStatus[error]!)
        await #expect(throws: GatewayFailure.signInRequired) {
            try await ownerPreviewClient(OwnerPreviewHTTPStub(response), clock: OwnerPreviewClock(f.now))
                .preview(f.query, token: ownerPreviewBearer)
        }
    }
}

@Test func ownerPreviewNativeNetworkExpiryRollbackAndActivationLossFencePixels() async throws {
    let f = try OwnerPreviewWireFixture()
    for (wall, monotonic) in [(30_000, 0.0), (0, 30.0), (-1, 0.0), (0, -0.1)] {
        let clock = OwnerPreviewClock(f.now)
        let stub = OwnerPreviewHTTPStub(f.image, effect: { clock.move(wall: wall, monotonic: monotonic) })
        await #expect(throws: GatewayAvatarFailure.superseded) {
            try await ownerPreviewClient(stub, clock: clock).preview(f.query, token: ownerPreviewBearer)
        }
    }
    let clock = OwnerPreviewClock(f.now)
    let stub = OwnerPreviewHTTPStub(f.image, effect: { clock.disable() })
    await #expect(throws: GatewayAvatarFailure.unavailable) {
        try await ownerPreviewClient(stub, clock: clock).preview(f.query, token: ownerPreviewBearer)
    }
}

@Test func ownerPreviewNativeLifetimeStartsBeforeNetworkAndIncludesDecodeWithoutRenewal() async throws {
    struct Decoder: GatewayAvatarDecoding {
        let clock: OwnerPreviewClock
        func decode(_ bytes: Data, manifest: AvatarManifest) async throws -> ValidatedAvatar {
            let image = try AvatarPayloadValidator.decode(bytes, manifest: manifest)
            clock.move(wall: 2000, monotonic: 2)
            return image
        }
    }
    let f = try OwnerPreviewWireFixture()
    let clock = OwnerPreviewClock(f.now)
    let stub = OwnerPreviewHTTPStub(f.image, effect: { clock.move(wall: 29_000, monotonic: 29) })
    await #expect(throws: GatewayAvatarFailure.superseded) {
        try await ownerPreviewClient(stub, clock: clock, decoder: Decoder(clock: clock)).preview(
            f.query, token: ownerPreviewBearer)
    }
}

@Test func ownerPreviewNativeDecodeCancellationAndDisableNeverReturnValidatedPixels() async throws {
    struct Decoder: GatewayAvatarDecoding {
        let clock: OwnerPreviewClock, cancel: Bool
        func decode(_ bytes: Data, manifest: AvatarManifest) async throws -> ValidatedAvatar {
            let image = try AvatarPayloadValidator.decode(bytes, manifest: manifest)
            if cancel { withUnsafeCurrentTask { $0?.cancel() } } else { clock.disable() }
            return image
        }
    }
    let f = try OwnerPreviewWireFixture()
    for cancel in [true, false] {
        let clock = OwnerPreviewClock(f.now)
        let task = Task {
            try await ownerPreviewClient(
                OwnerPreviewHTTPStub(f.image), clock: clock, decoder: Decoder(clock: clock, cancel: cancel)
            ).preview(f.query, token: ownerPreviewBearer)
        }
        if cancel {
            await #expect(throws: GatewayFailure.cancelled) { try await task.value }
        } else {
            await #expect(throws: GatewayAvatarFailure.unavailable) { try await task.value }
        }
    }
}

@Test func ownerPreviewNativeResultBindingExpiryAndDiagnosticsAreRedacted() async throws {
    let f = try OwnerPreviewWireFixture()
    let clock = OwnerPreviewClock(f.now)
    let client = try ownerPreviewClient(OwnerPreviewHTTPStub(f.image), clock: clock)
    let result = try await client.preview(f.query, token: ownerPreviewBearer)
    for value in [
        String(describing: result), String(reflecting: result), String(describing: f.query),
        String(reflecting: f.query),
    ] {
        #expect(
            !value.contains(f.query.ownerID) && !value.contains(f.query.selection.requestID)
                && !value.contains(ownerPreviewBearer.value))
    }
    #expect(Mirror(reflecting: result).children.isEmpty && Mirror(reflecting: f.query).children.isEmpty)
    let changed = try GatewayAvatarOwnerPreviewQuery(
        ownerID: f.query.ownerID,
        selection: .init(
            requestID: f.query.selection.requestID, versionID: f.query.selection.versionID,
            generation: f.query.selection.generation, reviewRevision: UUID().uuidString.lowercased()))
    let otherToken = try GatewaySecret(
        "6b000000-0000-4000-8000-000000000099." + String(repeating: "b", count: 43))
    for (query, origin, token) in [
        (changed, client.origin, ownerPreviewBearer),
        (f.query, "https://other.example.invalid", ownerPreviewBearer), (f.query, client.origin, otherToken),
    ] {
        #expect(throws: GatewayAvatarFailure.superseded) {
            try result.validate(query: query, origin: origin, token: token, stamp: clock.stamp())
        }
    }
    clock.move(wall: 29_999, monotonic: 29.999)
    try result.validate(
        query: f.query, origin: client.origin, token: ownerPreviewBearer, stamp: clock.stamp())
    clock.move(wall: 1, monotonic: 0.001)
    #expect(throws: GatewayAvatarFailure.superseded) {
        try result.validate(
            query: f.query, origin: client.origin, token: ownerPreviewBearer, stamp: clock.stamp())
    }
}
