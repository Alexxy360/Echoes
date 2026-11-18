import Foundation
import Testing

@testable import EchoesCloudKit

private final class OwnerPreviewNetworkPlan: @unchecked Sendable {
    struct Reply: Sendable {
        let response: GatewayAvatarHTTPResponse
        var redirect = false, alteredURL = false, finish = true
    }
    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var requests: [String: [URLRequest]] = [:]
    private var bodies: [String: [Data?]] = [:]
    func install(_ reply: Reply) -> URL {
        let host = "review-avatar-" + UUID().uuidString.lowercased() + ".example.invalid"
        lock.withLock {
            replies[host] = reply
            requests[host] = []
            bodies[host] = []
        }
        return URL(string: "https://" + host)!
    }
    func take(_ request: URLRequest, body: Data?) -> Reply? {
        lock.withLock {
            guard let host = request.url?.host else { return nil }
            let key = host.replacingOccurrences(of: "redirect-target-", with: "")
            requests[key, default: []].append(request)
            bodies[key, default: []].append(body)
            guard var reply = replies[key] else { return nil }
            if host.hasPrefix("redirect-target-") { reply.redirect = false }
            return reply
        }
    }
    func replace(_ origin: URL, reply: Reply) { lock.withLock { replies[origin.host!] = reply } }
    func count(_ origin: URL) -> Int { lock.withLock { requests[origin.host!]?.count ?? 0 } }
    func capturedBodies(_ origin: URL) -> [Data?] { lock.withLock { bodies[origin.host!] ?? [] } }
    func finish(_ origin: URL) -> [URLRequest] {
        lock.withLock {
            replies.removeValue(forKey: origin.host!)
            bodies.removeValue(forKey: origin.host!)
            return requests.removeValue(forKey: origin.host!) ?? []
        }
    }
}
private final class OwnerPreviewURLProtocol: URLProtocol, @unchecked Sendable {
    static let plan = OwnerPreviewNetworkPlan()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func outgoingBody() -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return bytes }
            guard count > 0, bytes.count + count <= 512 else { return nil }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }
    override func startLoading() {
        let body = outgoingBody()
        guard let url = request.url, let reply = Self.plan.take(request, body: body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if reply.redirect {
            let target = URL(string: "https://redirect-target-" + url.host! + "/stolen")!
            let response = HTTPURLResponse(
                url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(
                url: reply.alteredURL ? URL(string: "https://untrusted.example.invalid/snapshot")! : url,
                statusCode: reply.response.status, httpVersion: "HTTP/1.1",
                headerFields: reply.response.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.response.body.isEmpty { client?.urlProtocol(self, didLoad: reply.response.body) }
            if reply.finish { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() {}
}

private func nativeOwnerPreviewClient(
    _ origin: URL, transport: NativeGatewayAvatarOwnerPreviewTransport? = nil
) throws -> GatewayAvatarOwnerPreviewHTTPClient {
    try .init(
        configuration: .init(origin: origin),
        transport: transport
            ?? NativeGatewayAvatarOwnerPreviewTransport(protocolClasses: [OwnerPreviewURLProtocol.self]),
        isEnabled: { true })
}
private func ownerPreviewEventually(_ predicate: @Sendable () -> Bool) async throws {
    for _ in 0..<5000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayAvatarFailure.unavailable
}

@Test func ownerPreviewURLSessionReadsConcreteImageAndExactBodyWithoutCookiesOrCacheReuse() async throws {
    let f = try OwnerPreviewWireFixture()
    var headers = f.image.headers
    headers["Set-Cookie"] = "synthetic=private; Path=/; Secure; HttpOnly"
    let origin = OwnerPreviewURLProtocol.plan.install(
        .init(response: .init(status: 200, headers: headers, body: f.image.body)))
    defer { _ = OwnerPreviewURLProtocol.plan.finish(origin) }
    let client = try nativeOwnerPreviewClient(origin)
    for _ in 0..<2 { #expect(try await client.preview(f.query, token: ownerPreviewBearer).query == f.query) }
    let bodies = OwnerPreviewURLProtocol.plan.capturedBodies(origin)
    #expect(bodies.count == 2 && bodies.allSatisfy { $0 == (try? f.query.wire()) })
    let requests = OwnerPreviewURLProtocol.plan.finish(origin)
    #expect(requests.count == 2)
    #expect(
        requests.allSatisfy {
            $0.url?.path == "/v1/community/avatar/preview"
                && $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + ownerPreviewBearer.value
        })
    #expect(
        requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Origin") == nil
        })
}

@Test func ownerPreviewURLSessionRefusesRedirectWithoutForwardingBearer() async throws {
    let f = try OwnerPreviewWireFixture()
    let origin = OwnerPreviewURLProtocol.plan.install(.init(response: f.image, redirect: true))
    defer { _ = OwnerPreviewURLProtocol.plan.finish(origin) }
    do {
        _ = try await nativeOwnerPreviewClient(origin).preview(f.query, token: ownerPreviewBearer)
        Issue.record("Redirect must fail")
    } catch let failure as GatewayAvatarFailure {
        #expect(failure == .invalidResponse || failure == .unavailable)
    }
    let requests = OwnerPreviewURLProtocol.plan.finish(origin)
    #expect(requests.count == 1 && requests.allSatisfy { $0.url?.host == origin.host })
}

@Test func ownerPreviewURLSessionRefusesResponseFromAnotherURL() async throws {
    let f = try OwnerPreviewWireFixture()
    let origin = OwnerPreviewURLProtocol.plan.install(.init(response: f.image, alteredURL: true))
    defer { _ = OwnerPreviewURLProtocol.plan.finish(origin) }
    await #expect(throws: GatewayAvatarFailure.invalidResponse) {
        try await nativeOwnerPreviewClient(origin).preview(f.query, token: ownerPreviewBearer)
    }
}

@Test func ownerPreviewURLSessionRejectsWrongSelectionOrOwnerBeforeWaitingForEOF() async throws {
    let f = try OwnerPreviewWireFixture()
    for (header, changes) in [
        ("x-echoes-avatar-selection", ["reviewRevision": UUID().uuidString.lowercased()]),
        ("x-echoes-avatar-manifest", ["ownerID": UUID().uuidString.lowercased()]),
    ] {
        let response = try reviewHeader(f.image, header, changes)
        let origin = OwnerPreviewURLProtocol.plan.install(.init(response: response, finish: false))
        defer { _ = OwnerPreviewURLProtocol.plan.finish(origin) }
        await #expect(throws: GatewayAvatarFailure.invalidResponse) {
            try await nativeOwnerPreviewClient(origin).preview(f.query, token: ownerPreviewBearer)
        }
    }
}

@Test func ownerPreviewURLSessionRejectsExcessDeclaredLengthBeforeEOFAndBoundsUnknownErrorLength()
    async throws
{
    let f = try OwnerPreviewWireFixture()
    let error = try ownerPreviewJSON(["protocolVersion": 1, "error": "UNAVAILABLE"], status: 503)
    var longHeaders = error.headers
    longHeaders["Content-Length"] = "2049"
    let cases = [
        GatewayAvatarHTTPResponse(status: 503, headers: longHeaders, body: Data()),
        GatewayAvatarHTTPResponse(
            status: 503, headers: error.headers, body: Data(repeating: 32, count: 2049)),
    ]
    for (index, response) in cases.enumerated() {
        let origin = OwnerPreviewURLProtocol.plan.install(.init(response: response, finish: index != 0))
        defer { _ = OwnerPreviewURLProtocol.plan.finish(origin) }
        await #expect(throws: GatewayAvatarFailure.invalidResponse) {
            try await nativeOwnerPreviewClient(origin).preview(f.query, token: ownerPreviewBearer)
        }
    }
}

@Test func ownerPreviewURLSessionOneUnsettledSlotCancelsAndRequiresAnotherExplicitRequest() async throws {
    let f = try OwnerPreviewWireFixture()
    let origin = OwnerPreviewURLProtocol.plan.install(.init(response: f.image, finish: false))
    defer { _ = OwnerPreviewURLProtocol.plan.finish(origin) }
    let client = try nativeOwnerPreviewClient(origin)
    let first = Task { try await client.preview(f.query, token: ownerPreviewBearer) }
    defer { first.cancel() }
    try await ownerPreviewEventually { OwnerPreviewURLProtocol.plan.count(origin) == 1 }
    await #expect(throws: GatewayAvatarFailure.busy) {
        try await client.preview(f.query, token: ownerPreviewBearer)
    }
    first.cancel()
    await #expect(throws: GatewayFailure.cancelled) { try await first.value }
    OwnerPreviewURLProtocol.plan.replace(origin, reply: .init(response: f.image))
    #expect(try await client.preview(f.query, token: ownerPreviewBearer).query == f.query)
    #expect(OwnerPreviewURLProtocol.plan.count(origin) == 2)
}

@Test func ownerPreviewURLSessionNeverUsesPreviouslyDecodedImageFor204OrServerDenial() async throws {
    let f = try OwnerPreviewWireFixture()
    let origin = OwnerPreviewURLProtocol.plan.install(.init(response: f.image))
    defer { _ = OwnerPreviewURLProtocol.plan.finish(origin) }
    let client = try nativeOwnerPreviewClient(origin)
    _ = try await client.preview(f.query, token: ownerPreviewBearer)
    OwnerPreviewURLProtocol.plan.replace(
        origin, reply: .init(response: .init(status: 204, headers: [:], body: Data())))
    await #expect(throws: GatewayAvatarFailure.invalidResponse) {
        try await client.preview(f.query, token: ownerPreviewBearer)
    }
    OwnerPreviewURLProtocol.plan.replace(origin, reply: .init(response: f.cases["other-account-denied"]!))
    await #expect(throws: GatewayAvatarFailure.notFound) {
        try await client.preview(f.query, token: ownerPreviewBearer)
    }
    #expect(OwnerPreviewURLProtocol.plan.count(origin) == 3)
}
