import Foundation
import Testing

@testable import EchoesCloudKit

private final class ReportedPhotoNetworkPlan: @unchecked Sendable {
    struct Reply: Sendable {
        let response: GatewayAvatarReportReviewHTTPResponse
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
private final class ReportedPhotoURLProtocol: URLProtocol, @unchecked Sendable {
    static let plan = ReportedPhotoNetworkPlan()
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
private func reportedPhotoEventually(_ predicate: @Sendable () -> Bool) async throws {
    for _ in 0..<5000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayAvatarReportReviewFailure.unavailable
}
private func reportedPhotoNative(
    _ origin: URL, fixture: ReportedPhotoWireFixture,
    transport: NativeGatewayAvatarReportReviewTransport? = nil
) throws -> GatewayAvatarReportReviewHTTPClient {
    try reportedPhotoClient(
        transport
            ?? NativeGatewayAvatarReportReviewTransport(
                configuration: .init(origin: origin), protocolClasses: [ReportedPhotoURLProtocol.self]),
        clock: ReviewClock(fixture.now), origin: origin)
}
private func reportedPhotoRequest(_ origin: URL) throws -> URLRequest {
    var request = URLRequest(url: origin.appendingPathComponent("/v1/moderation/avatar-reports/queue"))
    request.httpMethod = "POST"
    request.httpBody = try GatewayAvatarReportReviewOperation.queue(after: nil).wire()
    for (name, value) in [
        "Content-Type": "application/json; charset=utf-8", "Accept": "application/json",
        "Accept-Encoding": "identity", "Cache-Control": "no-store",
        "Content-Length": String(request.httpBody!.count), "Authorization": "Bearer " + reviewBearer.value,
    ] {
        request.setValue(value, forHTTPHeaderField: name)
    }
    return request
}

@Test func avatarReportReviewURLSessionConcreteServerWireAcrossAllFiveOperationsAndReplay() async throws {
    let f = try ReportedPhotoWireFixture()
    let origin = ReportedPhotoURLProtocol.plan.install(.init(response: f.queue))
    defer { ReportedPhotoURLProtocol.plan.remove(origin) }
    let client = try reportedPhotoNative(origin, fixture: f)
    #expect(try await client.queue(after: nil, token: reviewBearer).items == [f.item])
    ReportedPhotoURLProtocol.plan.replace(origin, .init(response: f.inspection))
    let inspection = try await client.inspect(f.item, token: reviewBearer)
    let intent = try GatewayAvatarReportReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .hidePhoto)
    ReportedPhotoURLProtocol.plan.replace(origin, .init(response: f.decision))
    let first = try await client.decide(intent, token: reviewBearer)
    #expect(try await client.decide(intent, token: reviewBearer) == first)
    ReportedPhotoURLProtocol.plan.replace(origin, .init(response: f.cases["recover-confirmed"]!))
    #expect(
        try await client.recover(f.recovery, token: reviewBearer).outcome
            == .confirmed(revision: first.revision))
    ReportedPhotoURLProtocol.plan.replace(origin, .init(response: f.cases["retire-already-confirmed"]!))
    #expect(
        try await client.retire(f.recovery, token: reviewBearer).outcome
            == .confirmed(revision: first.revision))
    let (requests, bodies) = ReportedPhotoURLProtocol.plan.captured(origin)
    #expect(requests.count == 6 && bodies[2] == bodies[3])
    #expect(requests[1].value(forHTTPHeaderField: "Accept") == avatarReportReviewInspectionType)
    #expect(requests[1].value(forHTTPHeaderField: "Content-Length") == String(bodies[1]!.count))
    #expect(requests[5].url?.path == "/v1/moderation/avatar-reports/retire")
    #expect(try bodies[5] == GatewayAvatarReportReviewOperation.retire(f.recovery).wire())
    #expect(try bodies[4] == GatewayAvatarReportReviewOperation.recover(f.recovery).wire())
    #expect(
        requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + reviewBearer.value
                && $0.value(forHTTPHeaderField: "Cookie") == nil
                && $0.value(forHTTPHeaderField: "Origin") == nil
        })
}
@Test func avatarReportReviewURLSessionRefusesRedirectAndForeignResponseURLWithoutForwardingBearer()
    async throws
{
    let f = try ReportedPhotoWireFixture()
    for reply in [
        ReportedPhotoNetworkPlan.Reply(response: f.queue, redirect: true),
        .init(response: f.queue, alteredURL: true),
    ] {
        let origin = ReportedPhotoURLProtocol.plan.install(reply)
        defer { ReportedPhotoURLProtocol.plan.remove(origin) }
        await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
            try await reportedPhotoNative(origin, fixture: f).queue(after: nil, token: reviewBearer)
        }
        #expect(ReportedPhotoURLProtocol.plan.count(origin) == 1)
    }
}
@Test func avatarReportReviewURLSessionPinsRequestBeforeCreatingSystemTask() async throws {
    let f = try ReportedPhotoWireFixture()
    let origin = ReportedPhotoURLProtocol.plan.install(.init(response: f.queue))
    defer { ReportedPhotoURLProtocol.plan.remove(origin) }
    let transport = try NativeGatewayAvatarReportReviewTransport(
        configuration: .init(origin: origin), protocolClasses: [ReportedPhotoURLProtocol.self])
    var badURL = try reportedPhotoRequest(origin)
    badURL.url = URL(string: "https://evil.example.invalid/v1/moderation/avatar-reports/queue")!
    var cookie = try reportedPhotoRequest(origin)
    cookie.setValue("private=yes", forHTTPHeaderField: "Cookie")
    var wrongBody = try reportedPhotoRequest(origin)
    wrongBody.httpBody = Data("{}".utf8)
    var get = try reportedPhotoRequest(origin)
    get.httpMethod = "GET"
    for request in [badURL, cookie, wrongBody, get] {
        await #expect(throws: GatewayAvatarReportReviewFailure.invalidInput) {
            try await transport.send(request, operation: .queue(after: nil))
        }
    }
    #expect(ReportedPhotoURLProtocol.plan.count(origin) == 0)
}
@Test func avatarReportReviewURLSessionChecksHeadersBeforeBufferingOrWaitingForEOF() async throws {
    let f = try ReportedPhotoWireFixture()
    for changes in [
        ["Content-Type": "image/jpeg"], ["Content-Length": "8193"], ["Cache-Control": "public"],
        ["Content-Encoding": "gzip"], ["Content-Range": "bytes 0-1/2"], ["X-Content-Type-Options": ""],
    ] {
        let response = GatewayAvatarReportReviewHTTPResponse(
            status: 200, headers: reviewJSONHeaders.merging(changes) { _, n in n }, body: Data())
        let origin = ReportedPhotoURLProtocol.plan.install(.init(response: response, finish: false))
        defer { ReportedPhotoURLProtocol.plan.remove(origin) }
        await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
            try await reportedPhotoNative(origin, fixture: f).queue(after: nil, token: reviewBearer)
        }
    }
}
@Test func avatarReportReviewURLSessionCapsUnknownLengthAndRequiresExactAdvertisedLength() async throws {
    let f = try ReportedPhotoWireFixture()
    for (status, size, length) in [(200, 8193, nil), (503, 2049, nil), (200, 1, "2")] as [(Int, Int, String?)]
    {
        var headers = reviewJSONHeaders
        if let length { headers["Content-Length"] = length }
        let origin = ReportedPhotoURLProtocol.plan.install(
            .init(response: .init(status: status, headers: headers, body: Data(repeating: 32, count: size))))
        defer { ReportedPhotoURLProtocol.plan.remove(origin) }
        await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
            try await reportedPhotoNative(origin, fixture: f).queue(after: nil, token: reviewBearer)
        }
    }
}
@Test func avatarReportReviewURLSessionBusyAndCancellationNeverAutomaticallyDispatchAnotherOperation()
    async throws
{
    let f = try ReportedPhotoWireFixture()
    let origin = ReportedPhotoURLProtocol.plan.install(.init(response: f.queue, finish: false))
    defer { ReportedPhotoURLProtocol.plan.remove(origin) }
    let client = try reportedPhotoNative(origin, fixture: f)
    let first = Task { try await client.queue(after: nil, token: reviewBearer) }
    defer { first.cancel() }
    try await reportedPhotoEventually { ReportedPhotoURLProtocol.plan.count(origin) == 1 }
    await #expect(throws: GatewayAvatarReportReviewFailure.busy) {
        try await client.inspect(f.item, token: reviewBearer)
    }
    first.cancel()
    await #expect(throws: GatewayFailure.cancelled) { try await first.value }
    #expect(ReportedPhotoURLProtocol.plan.count(origin) == 1)
}
@Test func avatarReportReviewURLSessionNoCookiesOrOfflineReuse() async throws {
    let f = try ReportedPhotoWireFixture()
    var headers = f.queue.headers
    headers["Set-Cookie"] = "synthetic=private; Path=/; Secure; HttpOnly"
    let origin = ReportedPhotoURLProtocol.plan.install(
        .init(response: .init(status: 200, headers: headers, body: f.queue.body)))
    defer { ReportedPhotoURLProtocol.plan.remove(origin) }
    let client = try reportedPhotoNative(origin, fixture: f)
    for _ in 0..<2 { _ = try await client.queue(after: nil, token: reviewBearer) }
    ReportedPhotoURLProtocol.plan.replace(
        origin, .init(response: .init(status: 204, headers: [:], body: Data())))
    await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
        try await client.queue(after: nil, token: reviewBearer)
    }
    let (requests, _) = ReportedPhotoURLProtocol.plan.captured(origin)
    #expect(requests.count == 3 && requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
}
@Test func avatarReportReviewNetworkGateRetainsFailedOrCancelledTaskUntilExactSystemCompletion() async throws
{
    let f = try ReportedPhotoWireFixture()
    for failure: any Error in [
        GatewayFailure.cancelled, GatewayAvatarReportReviewFailure.invalidResponse,
        GatewayAvatarReportReviewFailure.unavailable,
    ] {
        let origin = ReportedPhotoURLProtocol.plan.install(.init(response: f.queue, finish: false))
        defer { ReportedPhotoURLProtocol.plan.remove(origin) }
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [ReportedPhotoURLProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let gate = AvatarReportReviewNetworkGate()
        let id = try gate.reserve(url: origin, operation: .queue(after: nil))
        let task = session.dataTask(with: origin)
        let running = Task {
            try await withCheckedThrowingContinuation { continuation in
                gate.attach(id: id, task: task, continuation: continuation)
            }
        }
        try await reportedPhotoEventually { ReportedPhotoURLProtocol.plan.count(origin) == 1 }
        gate.fail(id: id, error: failure)
        do {
            _ = try await running.value
            Issue.record("Failed gate returned data")
        } catch { #expect(String(describing: error) == String(describing: failure)) }
        #expect(throws: GatewayAvatarReportReviewFailure.busy) {
            try gate.reserve(url: origin, operation: .queue(after: nil))
        }
        let unrelated = session.dataTask(with: origin)
        gate.complete(task: unrelated, error: nil)
        #expect(throws: GatewayAvatarReportReviewFailure.busy) {
            try gate.reserve(url: origin, operation: .queue(after: nil))
        }
        gate.complete(task: task, error: URLError(.cancelled))
        let next = try gate.reserve(url: origin, operation: .queue(after: nil))
        gate.complete(task: task, error: nil)
        #expect(throws: GatewayAvatarReportReviewFailure.busy) {
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
@Test func avatarReportReviewNetworkGateLimitsNonemptyFragmentsBeforeSystemCompletion() async throws {
    let f = try ReportedPhotoWireFixture()
    let origin = ReportedPhotoURLProtocol.plan.install(.init(response: f.queue, finish: false))
    defer { ReportedPhotoURLProtocol.plan.remove(origin) }
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [ReportedPhotoURLProtocol.self]
    let session = URLSession(configuration: settings)
    defer { session.invalidateAndCancel() }
    let gate = AvatarReportReviewNetworkGate()
    let id = try gate.reserve(url: origin, operation: .queue(after: nil))
    let task = session.dataTask(with: origin)
    let running = Task {
        try await withCheckedThrowingContinuation { continuation in
            gate.attach(id: id, task: task, continuation: continuation)
        }
    }
    try await reportedPhotoEventually { ReportedPhotoURLProtocol.plan.count(origin) == 1 }
    #expect(
        gate.response(
            task: task,
            response: HTTPURLResponse(
                url: origin, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: reviewJSONHeaders)!))
    for _ in 0..<128 { gate.data(task: task, data: Data([32])) }
    gate.data(task: task, data: Data())
    #expect(throws: GatewayAvatarReportReviewFailure.busy) {
        try gate.reserve(url: origin, operation: .queue(after: nil))
    }
    gate.data(task: task, data: Data([32]))
    await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) { try await running.value }
    #expect(throws: GatewayAvatarReportReviewFailure.busy) {
        try gate.reserve(url: origin, operation: .queue(after: nil))
    }
    gate.complete(task: task, error: nil)
    _ = try gate.reserve(url: origin, operation: .queue(after: nil))
}
@Test func avatarReportReviewURLSessionAbsoluteDeadlineDoesNotWaitForAnUnfinishedBodyOrRetry() async throws {
    let f = try ReportedPhotoWireFixture()
    let origin = ReportedPhotoURLProtocol.plan.install(.init(response: f.queue, finish: false))
    defer { ReportedPhotoURLProtocol.plan.remove(origin) }
    let start = ProcessInfo.processInfo.systemUptime
    let wallStart = Date()
    await #expect(throws: GatewayAvatarReportReviewFailure.unavailable) {
        try await reportedPhotoNative(origin, fixture: f).queue(after: nil, token: reviewBearer)
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    // Either clock reaching the deadline must close the request. A machine sleep or wall
    // adjustment can legitimately end it before 14 seconds of process uptime.
    let wallElapsed = Date().timeIntervalSince(wallStart)
    #expect(max(elapsed, wallElapsed) >= 14 && elapsed >= 0 && elapsed < 19)
    #expect(ReportedPhotoURLProtocol.plan.count(origin) == 1)
}

@Test func avatarReportReviewNetworkGateRejectsPartialClockRollbackAfterAChunk() async throws {
    let f = try ReportedPhotoWireFixture()
    for (wall, monotonic) in [(-50, 0.0), (0, -0.05), (15_000, 15.0)] {
        let clock = ReviewClock(f.now)
        let origin = ReportedPhotoURLProtocol.plan.install(.init(response: f.queue, finish: false))
        defer { ReportedPhotoURLProtocol.plan.remove(origin) }
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [ReportedPhotoURLProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let gate = AvatarReportReviewNetworkGate(date: { clock.date() }, uptime: { clock.up() })
        let id = try gate.reserve(url: origin, operation: .queue(after: nil))
        let task = session.dataTask(with: origin)
        let running = Task {
            try await withCheckedThrowingContinuation { continuation in
                gate.attach(id: id, task: task, continuation: continuation)
            }
        }
        try await reportedPhotoEventually { ReportedPhotoURLProtocol.plan.count(origin) == 1 }
        #expect(
            gate.response(
                task: task,
                response: HTTPURLResponse(
                    url: origin, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: reviewJSONHeaders)!))
        clock.move(wall: 100, monotonic: 0.1)
        gate.data(task: task, data: Data([32]))
        clock.move(wall: wall, monotonic: monotonic)
        gate.data(task: task, data: Data([32]))
        await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) { try await running.value }
        #expect(throws: GatewayAvatarReportReviewFailure.busy) {
            try gate.reserve(url: origin, operation: .queue(after: nil))
        }
        gate.complete(task: task, error: nil)
        _ = try gate.reserve(url: origin, operation: .queue(after: nil))
    }
}
@Test func avatarReportReviewURLSessionFrameRequiresLengthAndPrivateHeadersBeforeBuffering() async throws {
    let f = try ReportedPhotoWireFixture()
    for patch: [String: String?] in [
        ["content-length": nil], ["content-length": "268293"], ["cache-control": "no-store"],
        ["content-type": "application/json"], ["content-encoding": "gzip"],
        ["x-echoes-avatar-manifest": "private"], ["x-echoes-avatar-report-review": "private"],
        ["content-range": "bytes 0-1/2"],
    ] {
        var headers = Dictionary(
            uniqueKeysWithValues: f.inspection.headers.map { ($0.key.lowercased(), $0.value) })
        for (key, value) in patch {
            if let value { headers[key] = value } else { headers.removeValue(forKey: key) }
        }
        let origin = ReportedPhotoURLProtocol.plan.install(
            .init(response: .init(status: 200, headers: headers, body: Data()), finish: false))
        defer { ReportedPhotoURLProtocol.plan.remove(origin) }
        await #expect(throws: GatewayAvatarReportReviewFailure.invalidResponse) {
            try await reportedPhotoNative(origin, fixture: f).inspect(f.item, token: reviewBearer)
        }
    }
}
