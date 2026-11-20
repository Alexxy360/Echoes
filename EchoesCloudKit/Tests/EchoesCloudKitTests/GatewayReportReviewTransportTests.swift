import Foundation
import Testing

@testable import EchoesCloudKit

private final class ReportNetworkPlan: @unchecked Sendable {
    struct Reply: Sendable {
        let response: GatewayReportReviewHTTPResponse
        var redirect = false, alteredURL = false, finish = true
    }
    private let lock = NSLock()
    private var replies: [String: Reply] = [:], requests: [String: [URLRequest]] = [:],
        bodies: [String: [Data?]] = [:]
    func install(_ reply: Reply) -> URL {
        let host = "report-" + UUID().uuidString.lowercased() + ".example.invalid"
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
private final class ReportURLProtocol: URLProtocol, @unchecked Sendable {
    static let plan = ReportNetworkPlan()
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
            guard count > 0, bytes.count + count <= 512 else { return nil }
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
private func reportEventually(_ predicate: @Sendable () -> Bool) async throws {
    for _ in 0..<5000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayReportReviewFailure.unavailable
}
private func reportNative(
    _ origin: URL, fixture: ReportWireFixture, transport: NativeGatewayReportReviewTransport? = nil
) throws -> GatewayReportReviewHTTPClient {
    try reportClient(
        transport
            ?? NativeGatewayReportReviewTransport(
                configuration: .init(origin: origin), protocolClasses: [ReportURLProtocol.self]),
        clock: ReviewClock(fixture.now), origin: origin)
}
private func reportRequest(_ origin: URL) throws -> URLRequest {
    var request = URLRequest(url: origin.appendingPathComponent("/v1/moderation/reports/queue"))
    request.httpMethod = "POST"
    request.httpBody = try GatewayReportReviewOperation.queue(after: nil).wire()
    for (name, value) in [
        "Content-Type": "application/json; charset=utf-8", "Accept": "application/json",
        "Accept-Encoding": "identity", "Cache-Control": "no-store",
        "Content-Length": String(request.httpBody!.count), "Authorization": "Bearer " + reviewBearer.value,
    ] {
        request.setValue(value, forHTTPHeaderField: name)
    }
    return request
}

@Test func reportReviewURLSessionConcreteServerWireAcrossAllFiveOperationsAndReplay() async throws {
    let f = try ReportWireFixture()
    let origin = ReportURLProtocol.plan.install(.init(response: f.queue))
    defer { ReportURLProtocol.plan.remove(origin) }
    let client = try reportNative(origin, fixture: f)
    #expect(try await client.queue(after: nil, token: reviewBearer).items == [f.item])
    ReportURLProtocol.plan.replace(origin, .init(response: f.inspection))
    let inspection = try await client.inspect(f.item, token: reviewBearer)
    let intent = try GatewayReportReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .hideMessage)
    ReportURLProtocol.plan.replace(origin, .init(response: f.decision))
    let first = try await client.decide(intent, token: reviewBearer)
    #expect(try await client.decide(intent, token: reviewBearer) == first)
    ReportURLProtocol.plan.replace(origin, .init(response: f.cases["recover-confirmed"]!))
    #expect(
        try await client.recover(f.recovery, token: reviewBearer).outcome
            == .confirmed(revision: first.revision))
    ReportURLProtocol.plan.replace(origin, .init(response: f.cases["retire-already-confirmed"]!))
    #expect(
        try await client.retire(f.recovery, token: reviewBearer).outcome
            == .confirmed(revision: first.revision))
    let (requests, bodies) = ReportURLProtocol.plan.captured(origin)
    #expect(requests.count == 6 && bodies[2] == bodies[3])
    #expect(requests[5].url?.path == "/v1/moderation/reports/retire")
    #expect(try bodies[5] == GatewayReportReviewOperation.retire(f.recovery).wire())
    #expect(try bodies[4] == GatewayReportReviewOperation.recover(f.recovery).wire())
    #expect(
        requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + reviewBearer.value
                && $0.value(forHTTPHeaderField: "Cookie") == nil
                && $0.value(forHTTPHeaderField: "Origin") == nil
        })
}
@Test func reportReviewURLSessionRefusesRedirectAndForeignResponseURLWithoutForwardingBearer() async throws {
    let f = try ReportWireFixture()
    for reply in [
        ReportNetworkPlan.Reply(response: f.queue, redirect: true),
        .init(response: f.queue, alteredURL: true),
    ] {
        let origin = ReportURLProtocol.plan.install(reply)
        defer { ReportURLProtocol.plan.remove(origin) }
        await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
            try await reportNative(origin, fixture: f).queue(after: nil, token: reviewBearer)
        }
        #expect(ReportURLProtocol.plan.count(origin) == 1)
    }
}
@Test func reportReviewURLSessionPinsRequestBeforeCreatingSystemTask() async throws {
    let f = try ReportWireFixture()
    let origin = ReportURLProtocol.plan.install(.init(response: f.queue))
    defer { ReportURLProtocol.plan.remove(origin) }
    let transport = try NativeGatewayReportReviewTransport(
        configuration: .init(origin: origin), protocolClasses: [ReportURLProtocol.self])
    var badURL = try reportRequest(origin)
    badURL.url = URL(string: "https://evil.example.invalid/v1/moderation/reports/queue")!
    var cookie = try reportRequest(origin)
    cookie.setValue("private=yes", forHTTPHeaderField: "Cookie")
    var wrongBody = try reportRequest(origin)
    wrongBody.httpBody = Data("{}".utf8)
    var get = try reportRequest(origin)
    get.httpMethod = "GET"
    for request in [badURL, cookie, wrongBody, get] {
        await #expect(throws: GatewayReportReviewFailure.invalidInput) {
            try await transport.send(request, operation: .queue(after: nil))
        }
    }
    #expect(ReportURLProtocol.plan.count(origin) == 0)
}
@Test func reportReviewURLSessionChecksHeadersBeforeBufferingOrWaitingForEOF() async throws {
    let f = try ReportWireFixture()
    for changes in [
        ["Content-Type": "image/jpeg"], ["Content-Length": "8193"], ["Cache-Control": "public"],
        ["Content-Encoding": "gzip"], ["Content-Range": "bytes 0-1/2"], ["X-Content-Type-Options": ""],
    ] {
        let response = GatewayReportReviewHTTPResponse(
            status: 200, headers: reviewJSONHeaders.merging(changes) { _, n in n }, body: Data())
        let origin = ReportURLProtocol.plan.install(.init(response: response, finish: false))
        defer { ReportURLProtocol.plan.remove(origin) }
        await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
            try await reportNative(origin, fixture: f).queue(after: nil, token: reviewBearer)
        }
    }
}
@Test func reportReviewURLSessionCapsUnknownLengthAndRequiresExactAdvertisedLength() async throws {
    let f = try ReportWireFixture()
    for (status, size, length) in [(200, 8193, nil), (503, 2049, nil), (200, 1, "2")] as [(Int, Int, String?)]
    {
        var headers = reviewJSONHeaders
        if let length { headers["Content-Length"] = length }
        let origin = ReportURLProtocol.plan.install(
            .init(response: .init(status: status, headers: headers, body: Data(repeating: 32, count: size))))
        defer { ReportURLProtocol.plan.remove(origin) }
        await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
            try await reportNative(origin, fixture: f).queue(after: nil, token: reviewBearer)
        }
    }
}
@Test func reportReviewURLSessionBusyAndCancellationNeverAutomaticallyDispatchAnotherOperation() async throws
{
    let f = try ReportWireFixture()
    let origin = ReportURLProtocol.plan.install(.init(response: f.queue, finish: false))
    defer { ReportURLProtocol.plan.remove(origin) }
    let client = try reportNative(origin, fixture: f)
    let first = Task { try await client.queue(after: nil, token: reviewBearer) }
    defer { first.cancel() }
    try await reportEventually { ReportURLProtocol.plan.count(origin) == 1 }
    await #expect(throws: GatewayReportReviewFailure.busy) {
        try await client.inspect(f.item, token: reviewBearer)
    }
    first.cancel()
    await #expect(throws: GatewayFailure.cancelled) { try await first.value }
    #expect(ReportURLProtocol.plan.count(origin) == 1)
}
@Test func reportReviewURLSessionNoCookiesOrOfflineReuse() async throws {
    let f = try ReportWireFixture()
    var headers = f.queue.headers
    headers["Set-Cookie"] = "synthetic=private; Path=/; Secure; HttpOnly"
    let origin = ReportURLProtocol.plan.install(
        .init(response: .init(status: 200, headers: headers, body: f.queue.body)))
    defer { ReportURLProtocol.plan.remove(origin) }
    let client = try reportNative(origin, fixture: f)
    for _ in 0..<2 { _ = try await client.queue(after: nil, token: reviewBearer) }
    ReportURLProtocol.plan.replace(origin, .init(response: .init(status: 204, headers: [:], body: Data())))
    await #expect(throws: GatewayReportReviewFailure.invalidResponse) {
        try await client.queue(after: nil, token: reviewBearer)
    }
    let (requests, _) = ReportURLProtocol.plan.captured(origin)
    #expect(requests.count == 3 && requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
}
@Test func reportReviewNetworkGateRetainsFailedOrCancelledTaskUntilExactSystemCompletion() async throws {
    let f = try ReportWireFixture()
    for failure: any Error in [
        GatewayFailure.cancelled, GatewayReportReviewFailure.invalidResponse,
        GatewayReportReviewFailure.unavailable,
    ] {
        let origin = ReportURLProtocol.plan.install(.init(response: f.queue, finish: false))
        defer { ReportURLProtocol.plan.remove(origin) }
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [ReportURLProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let gate = ReportReviewNetworkGate()
        let id = try gate.reserve(url: origin, operation: .queue(after: nil))
        let task = session.dataTask(with: origin)
        let running = Task {
            try await withCheckedThrowingContinuation { continuation in
                gate.attach(id: id, task: task, continuation: continuation)
            }
        }
        try await reportEventually { ReportURLProtocol.plan.count(origin) == 1 }
        gate.fail(id: id, error: failure)
        do {
            _ = try await running.value
            Issue.record("Failed gate returned data")
        } catch { #expect(String(describing: error) == String(describing: failure)) }
        #expect(throws: GatewayReportReviewFailure.busy) {
            try gate.reserve(url: origin, operation: .queue(after: nil))
        }
        let unrelated = session.dataTask(with: origin)
        gate.complete(task: unrelated, error: nil)
        #expect(throws: GatewayReportReviewFailure.busy) {
            try gate.reserve(url: origin, operation: .queue(after: nil))
        }
        gate.complete(task: task, error: URLError(.cancelled))
        let next = try gate.reserve(url: origin, operation: .queue(after: nil))
        gate.complete(task: task, error: nil)
        #expect(throws: GatewayReportReviewFailure.busy) {
            try gate.reserve(url: origin, operation: .queue(after: nil))
        }
        gate.fail(id: next, error: GatewayFailure.cancelled)
        let unused = session.dataTask(with: origin)
        await #expect(throws: GatewayFailure.cancelled) {
            try await withCheckedThrowingContinuation { continuation in
                gate.attach(id: next, task: unused, continuation: continuation)
            }
        }
        _ = try gate.reserve(url: origin, operation: .queue(after: nil))
    }
}
@Test func reportReviewNetworkGateLimitsNonemptyFragmentsBeforeSystemCompletion() async throws {
    let f = try ReportWireFixture()
    let origin = ReportURLProtocol.plan.install(.init(response: f.queue, finish: false))
    defer { ReportURLProtocol.plan.remove(origin) }
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [ReportURLProtocol.self]
    let session = URLSession(configuration: settings)
    defer { session.invalidateAndCancel() }
    let gate = ReportReviewNetworkGate()
    let id = try gate.reserve(url: origin, operation: .queue(after: nil))
    let task = session.dataTask(with: origin)
    let running = Task {
        try await withCheckedThrowingContinuation { continuation in
            gate.attach(id: id, task: task, continuation: continuation)
        }
    }
    try await reportEventually { ReportURLProtocol.plan.count(origin) == 1 }
    #expect(
        gate.response(
            task: task,
            response: HTTPURLResponse(
                url: origin, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: reviewJSONHeaders)!))
    for _ in 0..<128 { gate.data(task: task, data: Data([32])) }
    gate.data(task: task, data: Data())
    #expect(throws: GatewayReportReviewFailure.busy) {
        try gate.reserve(url: origin, operation: .queue(after: nil))
    }
    gate.data(task: task, data: Data([32]))
    await #expect(throws: GatewayReportReviewFailure.invalidResponse) { try await running.value }
    #expect(throws: GatewayReportReviewFailure.busy) {
        try gate.reserve(url: origin, operation: .queue(after: nil))
    }
    gate.complete(task: task, error: nil)
    _ = try gate.reserve(url: origin, operation: .queue(after: nil))
}
@Test func reportReviewURLSessionAbsoluteDeadlineDoesNotWaitForAnUnfinishedBodyOrRetry() async throws {
    let f = try ReportWireFixture()
    let origin = ReportURLProtocol.plan.install(.init(response: f.queue, finish: false))
    defer { ReportURLProtocol.plan.remove(origin) }
    let start = ProcessInfo.processInfo.systemUptime
    await #expect(throws: GatewayReportReviewFailure.unavailable) {
        try await reportNative(origin, fixture: f).queue(after: nil, token: reviewBearer)
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    #expect(elapsed >= 14 && elapsed < 19)
    #expect(ReportURLProtocol.plan.count(origin) == 1)
}
