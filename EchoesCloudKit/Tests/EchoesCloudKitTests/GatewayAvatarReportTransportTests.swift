import Foundation
import Testing

@testable import EchoesCloudKit

private final class PhotoReportNetworkPlan: @unchecked Sendable {
    struct Reply: Sendable {
        let response: GatewayAvatarReportHTTPResponse
        var redirect = false, alteredURL = false, finish = true
    }
    private let lock = NSLock()
    private var replies: [String: Reply] = [:], requests: [String: [URLRequest]] = [:],
        bodies: [String: [Data?]] = [:]
    func install(_ reply: Reply) -> URL {
        let host = "photo-report-" + UUID().uuidString.lowercased() + ".example.invalid"
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
            return replies[key]
        }
    }
    func replace(_ origin: URL, _ reply: Reply) { lock.withLock { replies[origin.host!] = reply } }
    func count(_ origin: URL) -> Int { lock.withLock { requests[origin.host!]?.count ?? 0 } }
    func captured(_ origin: URL) -> ([URLRequest], [Data?]) {
        lock.withLock { (requests[origin.host!] ?? [], bodies[origin.host!] ?? []) }
    }
    func remove(_ origin: URL) {
        lock.withLock {
            replies.removeValue(forKey: origin.host!)
            requests.removeValue(forKey: origin.host!)
            bodies.removeValue(forKey: origin.host!)
        }
    }
}
private final class PhotoReportURLProtocol: URLProtocol, @unchecked Sendable {
    static let plan = PhotoReportNetworkPlan()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func outgoingBody() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return bytes }
            guard count > 0, bytes.count + count <= 4096 else { return nil }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }
    override func startLoading() {
        guard let url = request.url, let reply = Self.plan.take(request, body: outgoingBody()) else {
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
                url: reply.alteredURL ? URL(string: "https://other.example.invalid/")! : url,
                statusCode: reply.response.status, httpVersion: "HTTP/1.1",
                headerFields: reply.response.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.response.body.isEmpty { client?.urlProtocol(self, didLoad: reply.response.body) }
            if reply.finish { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() {}
}
private func photoReportEventually(_ predicate: @Sendable () -> Bool) async throws {
    for _ in 0..<5000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayAvatarReportFailure.unavailable
}
private func photoReportNative(
    _ origin: URL, fixture: PhotoReportWireFixture, transport: NativeGatewayAvatarReportTransport? = nil
) throws -> GatewayAvatarReportHTTPClient {
    try photoReportClient(
        transport
            ?? NativeGatewayAvatarReportTransport(
                configuration: .init(origin: origin), protocolClasses: [PhotoReportURLProtocol.self]),
        clock: ReviewClock(fixture.now), origin: origin)
}
private func photoReportRequest(_ origin: URL, operation: GatewayAvatarReportOperation, token: GatewaySecret)
    throws -> URLRequest
{
    var request = URLRequest(url: origin.appendingPathComponent(operation.path))
    request.httpMethod = "POST"
    request.httpBody = try operation.wire()
    for (key, value) in [
        "Content-Type": "application/json; charset=utf-8", "Accept": "application/json",
        "Accept-Encoding": "identity", "Cache-Control": "no-store", "Authorization": "Bearer " + token.value,
        "Content-Length": String(request.httpBody!.count),
    ] { request.setValue(value, forHTTPHeaderField: key) }
    return request
}
@Test func avatarReportURLSessionConcreteRuntimeWireAndReadOnlyRecoveryUseExactOriginalAttempt() async throws
{
    let f = try PhotoReportWireFixture()
    let origin = PhotoReportURLProtocol.plan.install(.init(response: f.cases["submit"]!))
    defer { PhotoReportURLProtocol.plan.remove(origin) }
    let client = try photoReportNative(origin, fixture: f)
    let result = try await client.submit(f.submission, token: f.token)
    #expect(result.outcome == .accepted)
    PhotoReportURLProtocol.plan.replace(origin, .init(response: f.cases["recover-accepted"]!))
    #expect(try await client.recover(f.submission.identity, token: f.token) == result)
    PhotoReportURLProtocol.plan.replace(origin, .init(response: f.cases["recover-unconfirmed"]!))
    #expect(try await client.recover(f.unknown, token: f.token).outcome == .unconfirmed)
    PhotoReportURLProtocol.plan.replace(origin, .init(response: f.cases["cancel"]!))
    #expect(try await client.cancel(f.submission.identity, token: f.token).outcome == .cancelled)
    PhotoReportURLProtocol.plan.replace(origin, .init(response: f.cases["recover-cancelled"]!))
    #expect(try await client.recover(f.submission.identity, token: f.token).outcome == .cancelled)
    let (requests, bodies) = PhotoReportURLProtocol.plan.captured(origin)
    #expect(requests.count == 5)
    #expect(requests[3].url?.path == "/v1/community/avatar/report/cancel")
    #expect(try bodies[3] == GatewayAvatarReportOperation.cancel(f.submission.identity).wire())
    #expect(try bodies[0] == GatewayAvatarReportOperation.submit(f.submission).wire())
    #expect(try bodies[1] == GatewayAvatarReportOperation.recover(f.submission.identity).wire())
    #expect(
        requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + f.token.value
                && $0.value(forHTTPHeaderField: "Cookie") == nil
                && $0.value(forHTTPHeaderField: "Origin") == nil
        })
}
@Test func avatarReportURLSessionPinsURLMethodExactBodyAndHeadersBeforeSystemDispatch() async throws {
    let f = try PhotoReportWireFixture()
    let origin = PhotoReportURLProtocol.plan.install(.init(response: f.cases["submit"]!))
    let op = GatewayAvatarReportOperation.submit(f.submission)
    defer { PhotoReportURLProtocol.plan.remove(origin) }
    let transport = try NativeGatewayAvatarReportTransport(
        configuration: .init(origin: origin), protocolClasses: [PhotoReportURLProtocol.self])
    var foreign = try photoReportRequest(origin, operation: op, token: f.token)
    foreign.url = URL(string: "https://foreign.example.invalid/steal")!
    var cookie = try photoReportRequest(origin, operation: op, token: f.token)
    cookie.setValue("private", forHTTPHeaderField: "Cookie")
    var body = try photoReportRequest(origin, operation: op, token: f.token)
    body.httpBody = Data("{}".utf8)
    var get = try photoReportRequest(origin, operation: op, token: f.token)
    get.httpMethod = "GET"
    var privilege = try photoReportRequest(origin, operation: op, token: f.token)
    privilege.setValue("true", forHTTPHeaderField: "X-Operator")
    for request in [foreign, cookie, body, get, privilege] {
        await #expect(throws: GatewayAvatarReportFailure.invalidInput) {
            try await transport.send(request, operation: op)
        }
    }
    #expect(PhotoReportURLProtocol.plan.count(origin) == 0)
}
@Test func avatarReportURLSessionRejectsRedirectAndForeignResponseURLWithoutForwardingBearer() async throws {
    let f = try PhotoReportWireFixture()
    for reply in [
        PhotoReportNetworkPlan.Reply(response: f.cases["submit"]!, redirect: true),
        .init(response: f.cases["submit"]!, alteredURL: true),
    ] {
        let origin = PhotoReportURLProtocol.plan.install(reply)
        defer { PhotoReportURLProtocol.plan.remove(origin) }
        await #expect(throws: GatewayAvatarReportFailure.invalidResponse) {
            try await photoReportNative(origin, fixture: f).submit(f.submission, token: f.token)
        }
        #expect(PhotoReportURLProtocol.plan.count(origin) == 1)
    }
}
@Test func avatarReportURLSessionValidatesHeadersBeforeBodyOrEOF() async throws {
    let f = try PhotoReportWireFixture()
    for change in [
        ["Content-Type": "image/jpeg"], ["Content-Length": "2049"], ["Cache-Control": "public"],
        ["Content-Encoding": "gzip"], ["Content-Range": "bytes 0-1/2"], ["X-Content-Type-Options": ""],
        ["X-Echoes-Avatar-Manifest": "private"],
    ] {
        let origin = PhotoReportURLProtocol.plan.install(
            .init(
                response: .init(
                    status: 200, headers: photoReportHeaders.merging(change) { _, n in n }, body: Data()),
                finish: false))
        defer { PhotoReportURLProtocol.plan.remove(origin) }
        await #expect(throws: GatewayAvatarReportFailure.invalidResponse) {
            try await photoReportNative(origin, fixture: f).submit(f.submission, token: f.token)
        }
    }
}
@Test func avatarReportURLSessionBoundsActualBytesAndExactAdvertisedLength() async throws {
    let f = try PhotoReportWireFixture()
    for (status, size, length) in [(200, 2049, nil), (503, 2049, nil), (200, 1, "2")] as [(Int, Int, String?)]
    {
        var headers = photoReportHeaders
        if let length { headers["Content-Length"] = length }
        let origin = PhotoReportURLProtocol.plan.install(
            .init(response: .init(status: status, headers: headers, body: Data(repeating: 32, count: size))))
        defer { PhotoReportURLProtocol.plan.remove(origin) }
        await #expect(throws: GatewayAvatarReportFailure.invalidResponse) {
            try await photoReportNative(origin, fixture: f).recover(f.unknown, token: f.token)
        }
    }
}
@Test func avatarReportURLSessionBusyAndCancellationNeverDispatchAnotherWrite() async throws {
    let f = try PhotoReportWireFixture()
    let origin = PhotoReportURLProtocol.plan.install(.init(response: f.cases["submit"]!, finish: false))
    defer { PhotoReportURLProtocol.plan.remove(origin) }
    let client = try photoReportNative(origin, fixture: f)
    let pending = Task { try await client.submit(f.submission, token: f.token) }
    defer { pending.cancel() }
    try await photoReportEventually { PhotoReportURLProtocol.plan.count(origin) == 1 }
    await #expect(throws: GatewayAvatarReportFailure.busy) {
        try await client.recover(f.submission.identity, token: f.token)
    }
    pending.cancel()
    await #expect(throws: GatewayFailure.cancelled) { try await pending.value }
    #expect(PhotoReportURLProtocol.plan.count(origin) == 1)
}
@Test func avatarReportURLSessionDoesNotReuseCookiesOrOfflineResults() async throws {
    let f = try PhotoReportWireFixture()
    let original = f.cases["recover-accepted"]!
    let origin = PhotoReportURLProtocol.plan.install(
        .init(
            response: .init(
                status: 200,
                headers: original.headers.merging([
                    "Set-Cookie": "synthetic=private; Path=/; Secure; HttpOnly"
                ]) { _, n in n }, body: original.body)))
    defer { PhotoReportURLProtocol.plan.remove(origin) }
    let client = try photoReportNative(origin, fixture: f)
    for _ in 0..<2 { _ = try await client.recover(f.submission.identity, token: f.token) }
    PhotoReportURLProtocol.plan.replace(
        origin, .init(response: .init(status: 204, headers: [:], body: Data())))
    await #expect(throws: GatewayAvatarReportFailure.invalidResponse) {
        try await client.recover(f.submission.identity, token: f.token)
    }
    let (requests, _) = PhotoReportURLProtocol.plan.captured(origin)
    #expect(requests.count == 3 && requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
}
@Test func avatarReportNetworkGateRetainsFailureUntilExactSystemTaskCompletion() async throws {
    let f = try PhotoReportWireFixture()
    for failure: any Error in [
        GatewayFailure.cancelled, GatewayAvatarReportFailure.invalidResponse,
        GatewayAvatarReportFailure.unavailable,
    ] {
        let origin = PhotoReportURLProtocol.plan.install(.init(response: f.cases["submit"]!, finish: false))
        defer { PhotoReportURLProtocol.plan.remove(origin) }
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [PhotoReportURLProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let gate = AvatarReportNetworkGate()
        let operation = GatewayAvatarReportOperation.submit(f.submission)
        let id = try gate.reserve(url: origin, operation: operation)
        let task = session.dataTask(with: origin)
        let pending = Task {
            try await withCheckedThrowingContinuation { gate.attach(id: id, task: task, continuation: $0) }
        }
        try await photoReportEventually { PhotoReportURLProtocol.plan.count(origin) == 1 }
        gate.fail(id: id, error: failure)
        do {
            _ = try await pending.value
            Issue.record("Failure returned a report")
        } catch { #expect(String(describing: error) == String(describing: failure)) }
        #expect(throws: GatewayAvatarReportFailure.busy) {
            try gate.reserve(url: origin, operation: operation)
        }
        let unrelated = session.dataTask(with: origin)
        gate.complete(task: unrelated, error: nil)
        #expect(throws: GatewayAvatarReportFailure.busy) {
            try gate.reserve(url: origin, operation: operation)
        }
        gate.complete(task: task, error: URLError(.cancelled))
        let next = try gate.reserve(url: origin, operation: operation)
        gate.complete(task: task, error: nil)
        #expect(throws: GatewayAvatarReportFailure.busy) {
            try gate.reserve(url: origin, operation: operation)
        }
        gate.fail(id: next, error: GatewayFailure.cancelled)
        await #expect(throws: GatewayFailure.cancelled) {
            try await withCheckedThrowingContinuation {
                gate.attach(id: next, task: session.dataTask(with: origin), continuation: $0)
            }
        }
        _ = try gate.reserve(url: origin, operation: operation)
    }
}
@Test func avatarReportNetworkGateBoundsNonemptyChunksAndRetainsRejectedBodyUntilCompletion() async throws {
    let f = try PhotoReportWireFixture()
    let origin = PhotoReportURLProtocol.plan.install(.init(response: f.cases["submit"]!, finish: false))
    defer { PhotoReportURLProtocol.plan.remove(origin) }
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [PhotoReportURLProtocol.self]
    let session = URLSession(configuration: settings)
    defer { session.invalidateAndCancel() }
    let gate = AvatarReportNetworkGate()
    let operation = GatewayAvatarReportOperation.submit(f.submission)
    let id = try gate.reserve(url: origin, operation: operation)
    let task = session.dataTask(with: origin)
    let pending = Task {
        try await withCheckedThrowingContinuation { gate.attach(id: id, task: task, continuation: $0) }
    }
    try await photoReportEventually { PhotoReportURLProtocol.plan.count(origin) == 1 }
    #expect(
        gate.response(
            task: task,
            response: HTTPURLResponse(
                url: origin, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: photoReportHeaders)!))
    for _ in 0..<128 { gate.data(task: task, data: Data([32])) }
    gate.data(task: task, data: Data())
    #expect(throws: GatewayAvatarReportFailure.busy) { try gate.reserve(url: origin, operation: operation) }
    gate.data(task: task, data: Data([32]))
    await #expect(throws: GatewayAvatarReportFailure.invalidResponse) { try await pending.value }
    #expect(throws: GatewayAvatarReportFailure.busy) { try gate.reserve(url: origin, operation: operation) }
    gate.complete(task: task, error: nil)
    _ = try gate.reserve(url: origin, operation: operation)
}
@Test func avatarReportURLSessionRealDeadlineStopsUnfinishedBodyWithoutRetry() async throws {
    let f = try PhotoReportWireFixture()
    let origin = PhotoReportURLProtocol.plan.install(.init(response: f.cases["submit"]!, finish: false))
    defer { PhotoReportURLProtocol.plan.remove(origin) }
    let start = ProcessInfo.processInfo.systemUptime
    await #expect(throws: GatewayAvatarReportFailure.unavailable) {
        try await photoReportNative(origin, fixture: f).submit(f.submission, token: f.token)
    }
    #expect(
        ProcessInfo.processInfo.systemUptime - start >= 14
            && ProcessInfo.processInfo.systemUptime - start < 19)
    #expect(PhotoReportURLProtocol.plan.count(origin) == 1)
}
