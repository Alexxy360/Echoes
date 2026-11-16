import EchoesCore
import Foundation
import Testing

@testable import EchoesCloudKit

let avatarBearer = try! GatewaySecret(
    "65000000-0000-4000-8000-000000000001." + String(repeating: "a", count: 43))

struct AvatarWireFixture {
    let query: GatewayAvatarQuery
    let downloaded: GatewayAvatarHTTPResponse
    let revalidated: GatewayAvatarHTTPResponse
    init(_ variant: AvatarVariant = .thumbnail) throws {
        struct Wire: Decodable {
            struct Entry: Decodable {
                struct Selection: Decodable {
                    let ownerID: String, versionID: String, variant: String
                    let coordinate: Coordinate
                }
                struct Response: Decodable { let status: Int, headers: [String: String] }
                let query: Selection, downloaded: Response, revalidated: Response
            }
            let variants: [String: Entry]
        }
        let directory = "Fixtures/avatar-read"
        let wireURL = try #require(
            Bundle.module.url(forResource: "wire", withExtension: "json", subdirectory: directory))
        let wire = try JSONDecoder().decode(Wire.self, from: Data(contentsOf: wireURL))
        let entry = try #require(wire.variants[variant.rawValue])
        query = try .init(
            reference: .init(ownerID: entry.query.ownerID, versionID: entry.query.versionID),
            variant: variant, coordinate: entry.query.coordinate)
        let imageURL = try #require(
            Bundle.module.url(forResource: variant.rawValue, withExtension: "jpg", subdirectory: directory))
        downloaded = .init(
            status: entry.downloaded.status, headers: entry.downloaded.headers,
            body: try Data(contentsOf: imageURL))
        revalidated = .init(
            status: entry.revalidated.status, headers: entry.revalidated.headers, body: Data())
    }
    func knownQuery() throws -> GatewayAvatarQuery {
        let raw = try #require(revalidated.headers["x-echoes-avatar-manifest"])
        let manifest = try AvatarManifest(
            data: Data(raw.utf8), expected: query.reference, variant: query.variant)
        return try .init(
            reference: query.reference, variant: query.variant, coordinate: query.coordinate,
            knownSHA256: manifest.sha256)
    }
}

private actor AvatarReplyTransport: GatewayAvatarTransport {
    var requests: [URLRequest] = []
    let response: GatewayAvatarHTTPResponse
    let beforeReply: @Sendable () -> Void
    init(_ response: GatewayAvatarHTTPResponse, beforeReply: @escaping @Sendable () -> Void = {}) {
        self.response = response
        self.beforeReply = beforeReply
    }
    func send(_ request: URLRequest, query: GatewayAvatarQuery) async throws -> GatewayAvatarHTTPResponse {
        requests.append(request)
        beforeReply()
        return response
    }
}
private final class AvatarActivation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func enabled() -> Bool { lock.withLock { value } }
    func disable() { lock.withLock { value = false } }
}
private func avatarClient(_ transport: any GatewayAvatarTransport) throws -> GatewayAvatarHTTPClient {
    try .init(
        configuration: .init(origin: URL(string: "https://avatar.example.invalid")!),
        transport: transport, isEnabled: { true })
}
private func avatarError(_ code: String, status: Int = 400, retry: String? = nil) -> GatewayAvatarHTTPResponse
{
    var headers = ["Content-Type": "application/json; charset=utf-8"]
    headers["Retry-After"] = retry
    return .init(
        status: status, headers: headers,
        body: try! JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "error": code]))
}

@Test func avatarWireFromActualServerDecodesAndRevalidatesBothVariants() async throws {
    for variant in [AvatarVariant.image, .thumbnail] {
        let f = try AvatarWireFixture(variant)
        let client = try avatarClient(AvatarReplyTransport(f.downloaded))
        guard case .downloaded(let manifest, let bytes) = try await client.read(f.query, token: avatarBearer)
        else {
            Issue.record("Expected a fresh download")
            return
        }
        let image = try AvatarPayloadValidator.decode(bytes, manifest: manifest)
        #expect(image.image.width == (variant == .image ? 256 : 128))
        #expect(image.image.height == (variant == .image ? 128 : 64))
        let cachedClient = try avatarClient(AvatarReplyTransport(f.revalidated))
        guard
            case .revalidated(let cachedManifest) = try await cachedClient.read(
                f.knownQuery(), token: avatarBearer)
        else {
            Issue.record("Expected fresh cache authorization")
            return
        }
        #expect(cachedManifest == manifest)
    }
}

@Test func avatarClientEmitsOnlyClosedSelectionToConfiguredOrigin() async throws {
    let f = try AvatarWireFixture()
    let transport = AvatarReplyTransport(f.downloaded)
    _ = try await avatarClient(transport).read(f.query, token: avatarBearer)
    let request = try #require(await transport.requests.first)
    #expect(request.url?.absoluteString == "https://avatar.example.invalid/v1/community/avatar/read")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + avatarBearer.value)
    #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    let bodyData = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(Set(body.keys) == Set(["ownerID", "versionID", "variant", "coordinate"]))
    #expect(body["ownerID"] as? String == f.query.reference.ownerID)
    #expect(body["versionID"] as? String == f.query.reference.versionID)
}

@Test func avatarQueryRejectsInvalidCoordinatesAndDigestBeforeDispatch() throws {
    let f = try AvatarWireFixture()
    for coordinate in [Coordinate(latitude: .nan, longitude: 0), .init(latitude: 91, longitude: 0)] {
        #expect(throws: GatewayAvatarFailure.invalidInput) {
            try GatewayAvatarQuery(reference: f.query.reference, variant: .thumbnail, coordinate: coordinate)
        }
    }
    for hash in ["", String(repeating: "A", count: 64), String(repeating: "a", count: 65), "\r\nX: 1"] {
        #expect(throws: GatewayAvatarFailure.invalidInput) {
            try GatewayAvatarQuery(reference: f.query.reference, variant: .image, knownSHA256: hash)
        }
    }
}

@Test func avatarClientStaysInactiveByDefaultAndRejectsMalformedBearer() async throws {
    let f = try AvatarWireFixture()
    let transport = AvatarReplyTransport(f.downloaded)
    let client = try GatewayAvatarHTTPClient(
        configuration: .init(origin: URL(string: "https://avatar.example.invalid")!), transport: transport)
    await #expect(throws: GatewayAvatarFailure.unavailable) {
        try await client.read(f.query, token: avatarBearer)
    }
    let enabled = try avatarClient(transport)
    for raw in ["", "bearer\r\nX: 1"] {
        #expect(throws: GatewayFailure.invalidInput) { try GatewaySecret(raw) }
    }
    for raw in [String(repeating: "a", count: 80), avatarBearer.value + "a"] {
        await #expect(throws: GatewayAvatarFailure.invalidInput) {
            try await enabled.read(f.query, token: GatewaySecret(raw))
        }
    }
    #expect(await transport.requests.isEmpty)
}

@Test func avatarActivationAndCancellationFenceLateReplies() async throws {
    let f = try AvatarWireFixture()
    let flag = AvatarActivation()
    let transport = AvatarReplyTransport(f.downloaded, beforeReply: { flag.disable() })
    let client = try GatewayAvatarHTTPClient(
        configuration: .init(origin: URL(string: "https://avatar.example.invalid")!), transport: transport,
        isEnabled: { flag.enabled() })
    await #expect(throws: GatewayAvatarFailure.unavailable) {
        try await client.read(f.query, token: avatarBearer)
    }
    let cancelledTransport = AvatarReplyTransport(
        f.downloaded,
        beforeReply: {
            withUnsafeCurrentTask { $0?.cancel() }
        })
    let cancelledClient = try avatarClient(cancelledTransport)
    let operation = Task { try await cancelledClient.read(f.query, token: avatarBearer) }
    await #expect(throws: GatewayFailure.cancelled) { try await operation.value }
}

@Test func avatarManifestHeadersRejectWrongVersionOwnerVariantAndAdditionalFields() async throws {
    let f = try AvatarWireFixture()
    let raw = try #require(f.downloaded.headers["x-echoes-avatar-manifest"])
    let original = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    let mutations: [[String: Any]] = [
        ["ownerID": "65000000-0000-4000-8000-000000000009"],
        ["versionID": "65000000-0000-4000-8000-000000000008"], ["variant": "image"],
        ["downloadURL": "https://untrusted.example.invalid"], ["schemaVersion": 2],
        ["byteCount": 32_001], ["width": 129],
    ]
    for mutation in mutations {
        let modified = original.merging(mutation) { _, new in new }
        var headers = f.downloaded.headers
        headers["x-echoes-avatar-manifest"] = String(
            decoding: try JSONSerialization.data(withJSONObject: modified), as: UTF8.self)
        let client = try avatarClient(
            AvatarReplyTransport(.init(status: 200, headers: headers, body: f.downloaded.body)))
        await #expect(throws: GatewayAvatarFailure.invalidResponse) {
            try await client.read(f.query, token: avatarBearer)
        }
    }
}

@Test func avatarResponseRequiresPrivateNoStoreExactLengthAndNoContentTransformation() async throws {
    let f = try AvatarWireFixture()
    let mutations: [(String, String?)] = [
        ("cache-control", nil), ("cache-control", "public, max-age=600"),
        ("cache-control", "private, no-store, no-store"), ("x-content-type-options", nil),
        ("content-type", "image/png"), ("content-length", nil), ("content-length", "032"),
        ("content-length", String(f.downloaded.body.count + 1)), ("content-range", "bytes 0-31/32"),
        ("content-encoding", "gzip"), ("x-echoes-avatar-manifest", String(repeating: "a", count: 2049)),
        ("x-echoes-avatar-manifest", "{\"unicode\":\"ą\"}"),
    ]
    for (name, value) in mutations {
        var headers = f.downloaded.headers
        headers[name] = value
        let client = try avatarClient(
            AvatarReplyTransport(.init(status: 200, headers: headers, body: f.downloaded.body)))
        await #expect(throws: GatewayAvatarFailure.invalidResponse) {
            try await client.read(f.query, token: avatarBearer)
        }
    }
}

@Test func avatarBodyRejectsSameSizeCorruptionTruncationAndOversize() async throws {
    let f = try AvatarWireFixture()
    var altered = f.downloaded.body
    altered[altered.count / 2] ^= 1
    for bytes in [altered, f.downloaded.body.dropLast(), f.downloaded.body + Data([0])] {
        let client = try avatarClient(
            AvatarReplyTransport(.init(status: 200, headers: f.downloaded.headers, body: bytes)))
        await #expect(throws: GatewayAvatarFailure.invalidResponse) {
            try await client.read(f.query, token: avatarBearer)
        }
    }
}

@Test func avatarRevalidationRequiresKnownMatchingHashAndEmptyUnframedBody() async throws {
    let f = try AvatarWireFixture()
    let client = try avatarClient(AvatarReplyTransport(f.revalidated))
    await #expect(throws: GatewayAvatarFailure.invalidResponse) {
        try await client.read(f.query, token: avatarBearer)
    }
    let wrong = try GatewayAvatarQuery(
        reference: f.query.reference, variant: .thumbnail, knownSHA256: String(repeating: "0", count: 64))
    await #expect(throws: GatewayAvatarFailure.invalidResponse) {
        try await client.read(wrong, token: avatarBearer)
    }
    for (headers, bytes) in [
        (f.revalidated.headers, Data([0])),
        (f.revalidated.headers.merging(["content-length": "0"]) { _, new in new }, Data()),
        (f.revalidated.headers.merging(["content-type": "image/jpeg"]) { _, new in new }, Data()),
    ] {
        let malformed = try avatarClient(
            AvatarReplyTransport(.init(status: 204, headers: headers, body: bytes)))
        await #expect(throws: GatewayAvatarFailure.invalidResponse) {
            try await malformed.read(f.knownQuery(), token: avatarBearer)
        }
    }
}

@Test func avatarDifferentKnownDigestAllowsFreshDownloadButNoOfflineFallback() async throws {
    let f = try AvatarWireFixture()
    let query = try GatewayAvatarQuery(
        reference: f.query.reference, variant: .thumbnail, knownSHA256: String(repeating: "0", count: 64))
    let result = try await avatarClient(AvatarReplyTransport(f.downloaded)).read(query, token: avatarBearer)
    guard case .downloaded = result else {
        Issue.record("Expected fresh bytes")
        return
    }
    await #expect(throws: GatewayAvatarFailure.notFound) {
        try await avatarClient(AvatarReplyTransport(avatarError("AVATAR_READ_NOT_FOUND", status: 404))).read(
            query, token: avatarBearer)
    }
}

@Test func avatarRevokedAndExpiredSessionsRequireNativeReauthentication() async throws {
    let f = try AvatarWireFixture()
    for code in [
        "INVALID_SESSION", "REAUTH_REQUIRED", "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS", "AVATAR_READ_STALE",
    ] {
        await #expect(throws: GatewayFailure.signInRequired) {
            try await avatarClient(AvatarReplyTransport(avatarError(code, status: 401))).read(
                f.query, token: avatarBearer)
        }
    }
}

@Test func avatarServerErrorsAreTypedBoundedAndNeverExposeRawMessages() async throws {
    let f = try AvatarWireFixture()
    for (code, expected) in [
        ("AVATAR_READ_INPUT", GatewayAvatarFailure.invalidInput),
        ("AVATAR_READ_RESPONSE", .unavailable), ("AVATAR_READ_UNAVAILABLE", .unavailable),
        ("UNKNOWN-private-secret", .unavailable), ("AVATAR_READ_LIMIT", .limited(retryAfterSeconds: 12)),
    ] {
        await #expect(throws: expected) {
            try await avatarClient(AvatarReplyTransport(avatarError(code, retry: "12"))).read(
                f.query, token: avatarBearer)
        }
    }
    for value in ["-1", "86401", "9999999", "Wed, 1 Jan 2026", "\r\nsecret"] {
        await #expect(throws: GatewayAvatarFailure.limited(retryAfterSeconds: nil)) {
            try await avatarClient(AvatarReplyTransport(avatarError("RATE_LIMITED", retry: value))).read(
                f.query, token: avatarBearer)
        }
    }
}

@Test func avatarClientRejectsRedirectUnexpectedStatusDuplicateHeadersAndMalformedErrors() async throws {
    let f = try AvatarWireFixture()
    var duplicate = f.downloaded.headers
    duplicate["Content-Type"] = "image/jpeg"
    let invalid: [GatewayAvatarHTTPResponse] = [
        .init(status: 302, headers: ["Location": "https://other.example.invalid"], body: Data()),
        .init(status: 206, headers: f.downloaded.headers, body: f.downloaded.body),
        .init(status: 200, headers: duplicate, body: f.downloaded.body),
        .init(status: 404, headers: ["Content-Type": "text/html"], body: Data("secret".utf8)),
        .init(status: 404, headers: ["Content-Type": "application/json"], body: Data("{}".utf8)),
        .init(
            status: 404, headers: ["Content-Type": "application/json"],
            body: Data(repeating: 32, count: 32_769)),
    ]
    for response in invalid {
        await #expect(throws: GatewayAvatarFailure.invalidResponse) {
            try await avatarClient(AvatarReplyTransport(response)).read(f.query, token: avatarBearer)
        }
    }
}

@Test func avatarDiagnosticsRedactPhotoSelectionBodyAndHeaders() throws {
    let f = try AvatarWireFixture()
    for text in [String(describing: f.query), String(reflecting: f.query), String(reflecting: f.downloaded)] {
        #expect(!text.contains(f.query.reference.ownerID))
        #expect(!text.contains(f.query.reference.versionID))
        #expect(!text.contains("sha256"))
    }
    #expect(Mirror(reflecting: f.query).children.isEmpty)
    #expect(Mirror(reflecting: f.downloaded).children.isEmpty)
}

private struct FailingAvatarTransport: GatewayAvatarTransport {
    let error: any Error & Sendable
    func send(_ request: URLRequest, query: GatewayAvatarQuery) async throws -> GatewayAvatarHTTPResponse {
        throw error
    }
}
@Test func avatarTransportFailuresAndCancellationNeverReturnCachedAuthorization() async throws {
    let f = try AvatarWireFixture()
    for error in [URLError(.notConnectedToInternet), URLError(.timedOut)] {
        await #expect(throws: GatewayAvatarFailure.unavailable) {
            try await avatarClient(FailingAvatarTransport(error: error)).read(
                f.knownQuery(), token: avatarBearer)
        }
    }
    await #expect(throws: GatewayFailure.cancelled) {
        try await avatarClient(FailingAvatarTransport(error: CancellationError())).read(
            f.query, token: avatarBearer)
    }
}
@Test func avatarCancellationBeforeDispatchSendsNoBearer() async throws {
    let f = try AvatarWireFixture()
    let transport = AvatarReplyTransport(f.downloaded)
    let client = try avatarClient(transport)
    let operation = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await client.read(f.query, token: avatarBearer)
    }
    await #expect(throws: GatewayFailure.cancelled) { try await operation.value }
    #expect(await transport.requests.isEmpty)
}
