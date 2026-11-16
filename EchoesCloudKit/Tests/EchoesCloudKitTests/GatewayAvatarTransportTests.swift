import Foundation
import Testing

@testable import EchoesCloudKit

private final class AvatarNetworkPlan: @unchecked Sendable {
    struct Reply: Sendable {
        let response: GatewayAvatarHTTPResponse
        var redirect = false
        var alteredURL = false
        var finish = true
        var started: (@Sendable () -> Void)?
    }
    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var requests: [String: [URLRequest]] = [:]
    func install(_ reply: Reply) -> URL {
        let host = "avatar-" + UUID().uuidString.lowercased() + ".example.invalid"
        lock.withLock {
            replies[host] = reply
            requests[host] = []
        }
        return URL(string: "https://" + host)!
    }
    func take(_ request: URLRequest) -> Reply? {
        lock.withLock {
            guard let host = request.url?.host else { return nil }
            let key = host.replacingOccurrences(of: "redirect-target-", with: "")
            requests[key, default: []].append(request)
            guard var reply = replies[key] else { return nil }
            if host.hasPrefix("redirect-target-") { reply.redirect = false }
            return reply
        }
    }
    func finish(_ origin: URL) -> [URLRequest] {
        lock.withLock {
            replies.removeValue(forKey: origin.host!)
            return requests.removeValue(forKey: origin.host!) ?? []
        }
    }
}
private final class AvatarURLProtocol: URLProtocol, @unchecked Sendable {
    static let plan = AvatarNetworkPlan()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let reply = Self.plan.take(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        reply.started?()
        if reply.redirect {
            let target = URL(string: "https://redirect-target-" + url.host! + "/stolen")!
            let response = HTTPURLResponse(
                url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(
                url: reply.alteredURL ? URL(string: "https://untrusted.example.invalid/file")! : url,
                statusCode: reply.response.status, httpVersion: "HTTP/1.1",
                headerFields: reply.response.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.response.body.isEmpty { client?.urlProtocol(self, didLoad: reply.response.body) }
            if reply.finish { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() {}
}
private func nativeAvatarClient(_ origin: URL) throws -> GatewayAvatarHTTPClient {
    try .init(
        configuration: .init(origin: origin),
        transport: NativeGatewayAvatarTransport(protocolClasses: [AvatarURLProtocol.self]),
        isEnabled: { true })
}

@Test func nativeAvatarURLSessionReceivesActualServerWireForBothVariantsAnd204() async throws {
    for variant in [AvatarVariant.image, .thumbnail] {
        let f = try AvatarWireFixture(variant)
        for (response, query) in [(f.downloaded, f.query), (f.revalidated, try f.knownQuery())] {
            let origin = AvatarURLProtocol.plan.install(.init(response: response))
            defer { _ = AvatarURLProtocol.plan.finish(origin) }
            let reply = try await nativeAvatarClient(origin).read(query, token: avatarBearer)
            if response.status == 200 {
                guard case .downloaded(let manifest, let bytes) = reply else {
                    Issue.record("Expected bytes")
                    return
                }
                #expect(try AvatarPayloadValidator.decode(bytes, manifest: manifest).image.width > 0)
            } else {
                guard case .revalidated = reply else {
                    Issue.record("Expected empty authorization")
                    return
                }
            }
            let requests = AvatarURLProtocol.plan.finish(origin)
            #expect(requests.count == 1)
            #expect(requests[0].value(forHTTPHeaderField: "Cookie") == nil)
            #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer " + avatarBearer.value)
        }
    }
}

@Test func nativeAvatarURLSessionRejectsRedirectBeforeForwardingCredentials() async throws {
    let f = try AvatarWireFixture()
    let origin = AvatarURLProtocol.plan.install(.init(response: f.downloaded, redirect: true))
    defer { _ = AvatarURLProtocol.plan.finish(origin) }
    do {
        _ = try await nativeAvatarClient(origin).read(f.query, token: avatarBearer)
        Issue.record("Redirect must not return an image")
    } catch let failure as GatewayAvatarFailure {
        // Foundation may terminate the refused URLProtocol redirect before delivering its 307.
        #expect(failure == .invalidResponse || failure == .unavailable)
    }
    let requests = AvatarURLProtocol.plan.finish(origin)
    #expect(requests.count == 1)
    #expect(requests.allSatisfy { $0.url?.host == origin.host })
}

@Test func nativeAvatarURLSessionRejectsResponseOriginSubstitution() async throws {
    let f = try AvatarWireFixture()
    let origin = AvatarURLProtocol.plan.install(.init(response: f.downloaded, alteredURL: true))
    defer { _ = AvatarURLProtocol.plan.finish(origin) }
    await #expect(throws: GatewayAvatarFailure.invalidResponse) {
        try await nativeAvatarClient(origin).read(f.query, token: avatarBearer)
    }
}

@Test func nativeAvatarURLSessionEnforcesManifestByteLimitEvenWithMisleadingLength() async throws {
    let f = try AvatarWireFixture()
    let oversized = GatewayAvatarHTTPResponse(
        status: 200, headers: f.downloaded.headers,
        body: f.downloaded.body + Data(repeating: 0, count: 32_001))
    let origin = AvatarURLProtocol.plan.install(.init(response: oversized))
    defer { _ = AvatarURLProtocol.plan.finish(origin) }
    await #expect(throws: GatewayAvatarFailure.invalidResponse) {
        try await nativeAvatarClient(origin).read(f.query, token: avatarBearer)
    }
}

@Test func nativeAvatarURLSessionRejectsInvalidHeadersWithoutWaitingForBodyEOF() async throws {
    let f = try AvatarWireFixture()
    for changed in [
        ["content-length": "32001"], ["content-encoding": "gzip"],
        ["x-echoes-avatar-manifest": String(repeating: "a", count: 2049)],
    ] {
        let headers = f.downloaded.headers.merging(changed) { _, new in new }
        let response = GatewayAvatarHTTPResponse(status: 200, headers: headers, body: Data())
        // The body never completes: header rejection must cancel the task before reading it.
        let origin = AvatarURLProtocol.plan.install(.init(response: response, finish: false))
        defer { _ = AvatarURLProtocol.plan.finish(origin) }
        await #expect(throws: GatewayAvatarFailure.invalidResponse) {
            try await nativeAvatarClient(origin).read(f.query, token: avatarBearer)
        }
    }
}

@Test func nativeAvatarURLSessionBoundsUnknownLengthJSONErrors() async throws {
    let f = try AvatarWireFixture()
    let oversized = GatewayAvatarHTTPResponse(
        status: 503, headers: ["Content-Type": "application/json"], body: Data(repeating: 32, count: 32_769))
    let origin = AvatarURLProtocol.plan.install(.init(response: oversized))
    defer { _ = AvatarURLProtocol.plan.finish(origin) }
    await #expect(throws: GatewayAvatarFailure.invalidResponse) {
        try await nativeAvatarClient(origin).read(f.query, token: avatarBearer)
    }
}

@Test func nativeAvatarURLSessionCancellationStopsWaitingForIncompleteBody() async throws {
    let f = try AvatarWireFixture()
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let response = GatewayAvatarHTTPResponse(status: 200, headers: f.downloaded.headers, body: Data())
    let origin = AvatarURLProtocol.plan.install(
        .init(
            response: response, finish: false,
            started: {
                continuation.yield()
                continuation.finish()
            }))
    defer { _ = AvatarURLProtocol.plan.finish(origin) }
    let client = try nativeAvatarClient(origin)
    let operation = Task { try await client.read(f.query, token: avatarBearer) }
    for await _ in stream { break }
    operation.cancel()
    await #expect(throws: GatewayFailure.cancelled) { try await operation.value }
}

@Test func nativeAvatarURLSessionCapsFourActiveReadsAndReleasesCancelledSlots() async throws {
    let f = try AvatarWireFixture()
    let transport = NativeGatewayAvatarTransport(protocolClasses: [AvatarURLProtocol.self])
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    var operations: [Task<GatewayAvatarHTTPResponse, any Error>] = []
    var origins: [URL] = []
    for _ in 0..<4 {
        let response = GatewayAvatarHTTPResponse(status: 200, headers: f.downloaded.headers, body: Data())
        let origin = AvatarURLProtocol.plan.install(
            .init(response: response, finish: false, started: { continuation.yield() }))
        origins.append(origin)
        operations.append(Task { try await transport.send(URLRequest(url: origin), query: f.query) })
    }
    defer {
        for operation in operations { operation.cancel() }
        for origin in origins { _ = AvatarURLProtocol.plan.finish(origin) }
        continuation.finish()
    }
    var started = 0
    for await _ in stream {
        started += 1
        if started == 4 { break }
    }
    await #expect(throws: GatewayAvatarFailure.limited(retryAfterSeconds: nil)) {
        try await transport.send(URLRequest(url: origins[0]), query: f.query)
    }
    for operation in operations { operation.cancel() }
    for operation in operations {
        await #expect(throws: GatewayFailure.cancelled) { try await operation.value }
    }
    let fresh = AvatarURLProtocol.plan.install(.init(response: f.downloaded))
    defer { _ = AvatarURLProtocol.plan.finish(fresh) }
    #expect(try await transport.send(URLRequest(url: fresh), query: f.query).body == f.downloaded.body)
}
