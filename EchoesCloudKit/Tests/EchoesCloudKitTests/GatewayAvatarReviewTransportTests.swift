import Foundation
import Testing

@testable import EchoesCloudKit

private final class ReviewNetworkPlan: @unchecked Sendable {
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
private final class ReviewURLProtocol: URLProtocol, @unchecked Sendable {
    static let plan = ReviewNetworkPlan()
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
private func nativeReviewClient(_ origin: URL, transport: NativeGatewayAvatarReviewTransport? = nil)
    throws -> GatewayAvatarReviewHTTPClient
{
    try .init(
        configuration: .init(origin: origin),
        transport: transport
            ?? NativeGatewayAvatarReviewTransport(protocolClasses: [ReviewURLProtocol.self]),
        isEnabled: { true })
}
private func reviewNetworkEventually(_ predicate: @Sendable () -> Bool) async throws {
    for _ in 0..<5000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayAvatarReviewFailure.unavailable
}

@Test func avatarReviewURLSessionActualServerQueueImageAndSameDecisionReplay() async throws {
    let f = try ReviewWireFixture()
    let origin = ReviewURLProtocol.plan.install(.init(response: f.queue))
    defer { _ = ReviewURLProtocol.plan.finish(origin) }
    let client = try nativeReviewClient(origin)
    #expect(try await client.queue(token: reviewBearer) == [f.item])
    ReviewURLProtocol.plan.replace(origin, reply: .init(response: try f.freshImage()))
    let inspection = try await client.inspect(f.item, token: reviewBearer)
    let intent = try GatewayAvatarReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .approved)
    ReviewURLProtocol.plan.replace(origin, reply: .init(response: f.decision))
    let first = try await client.decide(intent, token: reviewBearer)
    #expect(try await client.decide(intent, token: reviewBearer) == first)
    let bodies = ReviewURLProtocol.plan.capturedBodies(origin)
    #expect(bodies.count == 4 && bodies[2] == bodies[3])
    #expect(try bodies[0] == GatewayAvatarReviewOperation.queue.wire())
    #expect(try bodies[1] == GatewayAvatarReviewOperation.inspect(f.item).wire())
    #expect(try bodies[2] == GatewayAvatarReviewOperation.decide(intent).wire())
    let requests = ReviewURLProtocol.plan.finish(origin)
    #expect(requests.count == 4)
    #expect(
        requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + reviewBearer.value
        })
    #expect(
        requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Origin") == nil
        })
}

@Test func avatarReviewURLSessionRefusesRedirectWithoutForwardingBearer() async throws {
    let f = try ReviewWireFixture()
    let origin = ReviewURLProtocol.plan.install(.init(response: f.queue, redirect: true))
    defer { _ = ReviewURLProtocol.plan.finish(origin) }
    do {
        _ = try await nativeReviewClient(origin).queue(token: reviewBearer)
        Issue.record("Redirect must fail")
    } catch let failure as GatewayAvatarReviewFailure {
        #expect(failure == .invalidResponse || failure == .unavailable)
    }
    let requests = ReviewURLProtocol.plan.finish(origin)
    #expect(requests.count == 1 && requests.allSatisfy { $0.url?.host == origin.host })
}

@Test func avatarReviewURLSessionRejectsResponseURLFromAnotherOrigin() async throws {
    let f = try ReviewWireFixture()
    let origin = ReviewURLProtocol.plan.install(.init(response: f.queue, alteredURL: true))
    defer { _ = ReviewURLProtocol.plan.finish(origin) }
    await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
        try await nativeReviewClient(origin).queue(token: reviewBearer)
    }
}

@Test func avatarReviewURLSessionRejectsUnsafeJSONHeadersBeforeWaitingForEOF() async throws {
    let f = try ReviewWireFixture()
    for changes in [
        ["content-length": "8193"], ["content-encoding": "gzip"], ["content-type": "text/html"],
        ["cache-control": "public"], ["content-range": "bytes 0-1/2"],
    ] {
        let response = GatewayAvatarHTTPResponse(
            status: 200, headers: f.queue.headers.merging(changes) { _, n in n }, body: Data())
        let origin = ReviewURLProtocol.plan.install(.init(response: response, finish: false))
        defer { _ = ReviewURLProtocol.plan.finish(origin) }
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await nativeReviewClient(origin).queue(token: reviewBearer)
        }
    }
}

@Test func avatarReviewURLSessionRejectsWrongBinaryVersionOrProofBeforeWaitingForEOF() async throws {
    let f = try ReviewWireFixture()
    let image = try f.freshImage()
    let wrongVersion = try reviewHeader(
        image, "x-echoes-avatar-manifest", ["versionID": UUID().uuidString.lowercased()])
    let wrongProof = try reviewHeader(
        image, "x-echoes-avatar-review", ["reviewRevision": UUID().uuidString.lowercased()])
    for response in [wrongVersion, wrongProof] {
        let origin = ReviewURLProtocol.plan.install(.init(response: response, finish: false))
        defer { _ = ReviewURLProtocol.plan.finish(origin) }
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await nativeReviewClient(origin).inspect(f.item, token: reviewBearer)
        }
    }
}

@Test func avatarReviewURLSessionBoundsUnknownLengthQueueAndErrorStreams() async throws {
    for (status, count) in [(200, 8193), (503, 2049)] {
        let response = GatewayAvatarHTTPResponse(
            status: status, headers: reviewJSONHeaders, body: Data(repeating: 32, count: count))
        let origin = ReviewURLProtocol.plan.install(.init(response: response))
        defer { _ = ReviewURLProtocol.plan.finish(origin) }
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await nativeReviewClient(origin).queue(token: reviewBearer)
        }
    }
}

@Test func avatarReviewURLSessionOneUnsettledSlotCancelsWithoutAutomaticRetryOrRenewal() async throws {
    let f = try ReviewWireFixture()
    let origin = ReviewURLProtocol.plan.install(.init(response: f.queue, finish: false))
    defer { _ = ReviewURLProtocol.plan.finish(origin) }
    let client = try nativeReviewClient(origin)
    let first = Task { try await client.queue(token: reviewBearer) }
    defer { first.cancel() }
    try await reviewNetworkEventually { ReviewURLProtocol.plan.count(origin) == 1 }
    await #expect(throws: GatewayAvatarReviewFailure.busy) {
        try await client.inspect(f.item, token: reviewBearer)
    }
    first.cancel()
    await #expect(throws: GatewayFailure.cancelled) { try await first.value }
    ReviewURLProtocol.plan.replace(origin, reply: .init(response: f.queue))
    #expect(try await client.queue(token: reviewBearer) == [f.item])
    #expect(ReviewURLProtocol.plan.count(origin) == 2)
}

@Test func avatarReviewURLSessionNeverStoresCookiesOrReusesModeratorImageOffline() async throws {
    let f = try ReviewWireFixture()
    var headers = f.queue.headers
    headers["set-cookie"] = "synthetic=private; Path=/; Secure; HttpOnly"
    let origin = ReviewURLProtocol.plan.install(
        .init(response: .init(status: 200, headers: headers, body: f.queue.body)))
    defer { _ = ReviewURLProtocol.plan.finish(origin) }
    let client = try nativeReviewClient(origin)
    for _ in 0..<2 { _ = try await client.queue(token: reviewBearer) }
    ReviewURLProtocol.plan.replace(origin, reply: .init(response: try f.freshImage()))
    _ = try await client.inspect(f.item, token: reviewBearer)
    ReviewURLProtocol.plan.replace(
        origin, reply: .init(response: .init(status: 204, headers: [:], body: Data())))
    await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
        try await client.inspect(f.item, token: reviewBearer)
    }
    let requests = ReviewURLProtocol.plan.finish(origin)
    #expect(requests.count == 4 && requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
}

@Test func avatarReviewRecoveryURLSessionReadsAllActualServerOutcomesWithExactMetadata() async throws {
    let f = try ReviewRecoveryWireFixture()
    for row in f.rows {
        let origin = ReviewURLProtocol.plan.install(.init(response: row.response))
        defer { _ = ReviewURLProtocol.plan.finish(origin) }
        let value = try await nativeReviewClient(origin).recover(row.intent, token: reviewBearer)
        #expect(value.outcome == row.expected)
        let bodies = ReviewURLProtocol.plan.capturedBodies(origin)
        #expect(bodies.count == 1)
        #expect(try bodies[0] == GatewayAvatarReviewOperation.recover(row.intent).wire())
        let requests = ReviewURLProtocol.plan.finish(origin)
        #expect(requests.count == 1 && requests[0].url?.path == "/v1/moderation/avatar/recover")
    }
}

@Test func avatarReviewRecoveryURLSessionBoundsSuccessAt2048BeforeBufferingOrEOF() async throws {
    let f = try ReviewRecoveryWireFixture()
    let row = try #require(f.rows.first)
    for advertised in [true, false] {
        var headers = reviewJSONHeaders
        if advertised { headers["content-length"] = "2049" }
        let response = GatewayAvatarHTTPResponse(
            status: 200, headers: headers, body: Data(repeating: 32, count: 2049))
        let origin = ReviewURLProtocol.plan.install(.init(response: response, finish: !advertised))
        defer { _ = ReviewURLProtocol.plan.finish(origin) }
        await #expect(throws: GatewayAvatarReviewFailure.invalidResponse) {
            try await nativeReviewClient(origin).recover(row.intent, token: reviewBearer)
        }
    }
}
