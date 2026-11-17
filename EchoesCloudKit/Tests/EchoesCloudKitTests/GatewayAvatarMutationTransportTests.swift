import Foundation
import Testing

@testable import EchoesCloudKit

private final class MutationNetworkPlan: @unchecked Sendable {
    struct Reply: Sendable {
        let response: GatewayAvatarHTTPResponse
        var redirect = false, alteredURL = false, finish = true
    }
    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var requests: [String: [URLRequest]] = [:]
    private var bodies: [String: [Data?]] = [:]
    func install(_ reply: Reply) -> URL {
        let host = "owner-avatar-" + UUID().uuidString.lowercased() + ".example.invalid"
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
private final class MutationURLProtocol: URLProtocol, @unchecked Sendable {
    static let plan = MutationNetworkPlan()
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
            guard count > 0, bytes.count + count <= 256000 else { return nil }
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
private func nativeMutationClient(_ origin: URL, transport: NativeGatewayAvatarMutationTransport? = nil)
    throws -> GatewayAvatarMutationHTTPClient
{
    try .init(
        configuration: .init(origin: origin),
        transport: transport
            ?? NativeGatewayAvatarMutationTransport(protocolClasses: [MutationURLProtocol.self]),
        isEnabled: { true })
}
private func mutationNetworkEventually(_ predicate: @Sendable () -> Bool) async throws {
    for _ in 0..<5000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayAvatarMutationFailure.unavailable
}

@Test func avatarMutationNativeURLSessionSendsActualServerContractAndBinarySourceForAllSuccessActions()
    async throws
{
    let fixture = try MutationWireFixture()
    for row in fixture.cases where row.response.status == 200 {
        let origin = MutationURLProtocol.plan.install(.init(response: row.response))
        defer { _ = MutationURLProtocol.plan.finish(origin) }
        let value = try await nativeMutationClient(origin).perform(row.operation, token: mutationBearer)
        #expect(value.generation >= 0)
        let bodies = MutationURLProtocol.plan.capturedBodies(origin)
        #expect(bodies.count == 1)
        #expect(try bodies.first! == row.operation.wire().body)
        let requests = MutationURLProtocol.plan.finish(origin)
        #expect(requests.count == 1 && requests[0].value(forHTTPHeaderField: "Cookie") == nil)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer " + mutationBearer.value)
    }
}

@Test func avatarMutationNativeURLSessionRefusesRedirectWithoutForwardingTheBearer() async throws {
    let origin = MutationURLProtocol.plan.install(.init(response: try mutationResponse(), redirect: true))
    defer { _ = MutationURLProtocol.plan.finish(origin) }
    do {
        _ = try await nativeMutationClient(origin).perform(mutationUpload(), token: mutationBearer)
        Issue.record("Redirect must fail")
    } catch let error as GatewayAvatarMutationFailure {
        #expect(error == .invalidResponse || error == .unavailable)
    }
    let requests = MutationURLProtocol.plan.finish(origin)
    #expect(requests.count == 1 && requests.allSatisfy { $0.url?.host == origin.host })
}

@Test func avatarMutationNativeURLSessionRejectsAResponseFromAnotherOrigin() async throws {
    let origin = MutationURLProtocol.plan.install(.init(response: try mutationResponse(), alteredURL: true))
    defer { _ = MutationURLProtocol.plan.finish(origin) }
    await #expect(throws: GatewayAvatarMutationFailure.invalidResponse) {
        try await nativeMutationClient(origin).perform(mutationUpload(), token: mutationBearer)
    }
}

@Test func avatarMutationNativeURLSessionRejectsUnsafeHeadersBeforeWaitingForEOF() async throws {
    for changes in [
        ["Content-Length": "2049"], ["Content-Encoding": "gzip"], ["Content-Type": "text/html"],
        ["Cache-Control": "public"],
    ] {
        let response = try mutationResponse(headers: mutationHeaders.merging(changes) { _, new in new })
        let origin = MutationURLProtocol.plan.install(.init(response: response, finish: false))
        defer { _ = MutationURLProtocol.plan.finish(origin) }
        await #expect(throws: GatewayAvatarMutationFailure.invalidResponse) {
            try await nativeMutationClient(origin).perform(mutationUpload(), token: mutationBearer)
        }
    }
}

@Test func avatarMutationNativeURLSessionBoundsUnknownLengthJSONSuccessAndErrorBodies() async throws {
    for (status, count) in [(200, 2049), (503, 32769)] {
        let response = GatewayAvatarHTTPResponse(
            status: status, headers: mutationHeaders, body: Data(repeating: 32, count: count))
        let origin = MutationURLProtocol.plan.install(.init(response: response))
        defer { _ = MutationURLProtocol.plan.finish(origin) }
        await #expect(throws: GatewayAvatarMutationFailure.invalidResponse) {
            try await nativeMutationClient(origin).perform(.status, token: mutationBearer)
        }
    }
}

@Test func avatarMutationNativeURLSessionKeepsOneUploadSlotAndCancellationReleasesItWithoutRetry()
    async throws
{
    let response = try mutationResponse()
    let origin = MutationURLProtocol.plan.install(.init(response: response, finish: false))
    defer { _ = MutationURLProtocol.plan.finish(origin) }
    let client = try nativeMutationClient(origin)
    let upload = try mutationUpload(MutationWireFixture().image)
    let first = Task { try await client.perform(upload, token: mutationBearer) }
    defer { first.cancel() }
    try await mutationNetworkEventually { MutationURLProtocol.plan.count(origin) == 1 }
    await #expect(throws: GatewayAvatarMutationFailure.busy) {
        try await client.perform(upload, token: mutationBearer)
    }
    MutationURLProtocol.plan.replace(
        origin, reply: .init(response: try mutationResponse(mutationBody(.none))))
    #expect(try await client.perform(.status, token: mutationBearer).status == .none)
    first.cancel()
    await #expect(throws: GatewayFailure.cancelled) { try await first.value }
    MutationURLProtocol.plan.replace(origin, reply: .init(response: response))
    #expect(try await client.perform(upload, token: mutationBearer).status == .pendingReview)
    #expect(MutationURLProtocol.plan.count(origin) == 3)
}

@Test func avatarMutationNativeURLSessionBoundsFourControlsAndKeepsIndependentUploadAdmission() async throws {
    let response = try mutationResponse(mutationBody(.none))
    let origin = MutationURLProtocol.plan.install(.init(response: response, finish: false))
    defer { _ = MutationURLProtocol.plan.finish(origin) }
    let client = try nativeMutationClient(origin)
    let controls = (0..<4).map { _ in Task { try await client.perform(.status, token: mutationBearer) } }
    defer { for task in controls { task.cancel() } }
    try await mutationNetworkEventually { MutationURLProtocol.plan.count(origin) == 4 }
    await #expect(throws: GatewayAvatarMutationFailure.busy) {
        try await client.perform(.status, token: mutationBearer)
    }
    MutationURLProtocol.plan.replace(origin, reply: .init(response: try mutationResponse()))
    #expect(
        try await client.perform(mutationUpload(MutationWireFixture().image), token: mutationBearer).status
            == .pendingReview)
    for task in controls { task.cancel() }
    for task in controls { await #expect(throws: GatewayFailure.cancelled) { try await task.value } }
    MutationURLProtocol.plan.replace(origin, reply: .init(response: response))
    #expect(try await client.perform(.status, token: mutationBearer).status == .none)
    #expect(MutationURLProtocol.plan.count(origin) == 6)
}

@Test func avatarMutationNativeURLSessionNeverStoresResponseCookiesOrAddsThemToALaterRequest() async throws {
    let response = try mutationResponse(
        mutationBody(.none),
        headers: mutationHeaders.merging(["Set-Cookie": "synthetic=private; Path=/; Secure; HttpOnly"]) {
            _, n in n
        })
    let origin = MutationURLProtocol.plan.install(.init(response: response))
    defer { _ = MutationURLProtocol.plan.finish(origin) }
    let client = try nativeMutationClient(origin)
    for _ in 0..<2 { _ = try await client.perform(.status, token: mutationBearer) }
    let requests = MutationURLProtocol.plan.finish(origin)
    #expect(requests.count == 2 && requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
}
