import Foundation

struct ReportReviewResponseBoundary {
    let headers: [String: String]
    let maximum: Int, length: Int?
    init(status: Int, headers: [String: String], operation: GatewayReportReviewOperation) throws {
        var values: [String: String] = [:]
        guard headers.count <= 64, headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 8192
        else {
            throw GatewayReportReviewFailure.invalidResponse
        }
        for (key, value) in headers {
            let name = key.lowercased()
            guard values[name] == nil else { throw GatewayReportReviewFailure.invalidResponse }
            values[name] = value
        }
        let type = values["content-type"]?.lowercased().replacingOccurrences(of: " ", with: "")
        guard status == 200 || reportReviewErrorStatuses.values.contains(status),
            type == "application/json" || type == "application/json;charset=utf-8",
            values["cache-control"]?.lowercased() == "no-store",
            values["x-content-type-options"]?.lowercased() == "nosniff",
            values["content-encoding"] == nil || values["content-encoding"] == "identity",
            values["content-range"] == nil, values["x-echoes-avatar-manifest"] == nil,
            values["x-echoes-avatar-review"] == nil
        else { throw GatewayReportReviewFailure.invalidResponse }
        maximum = status == 200 ? operation.maximumResponseBytes : 2048
        if let raw = values["content-length"] {
            guard (1...5).contains(raw.utf8.count), raw.first != "0",
                raw.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(raw), count <= maximum
            else { throw GatewayReportReviewFailure.invalidResponse }
            length = count
        } else {
            length = nil
        }
        self.headers = values
    }
    func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximum, length == nil || length == data.count else {
            throw GatewayReportReviewFailure.invalidResponse
        }
    }
}

/// A cancelled caller is released promptly, but the admission slot belongs to the system task
/// until didCompleteWithError. Never replace an undrained task with another request.
final class ReportReviewNetworkGate: @unchecked Sendable {
    final class Ticket {
        let id = UUID(), url: URL, operation: GatewayReportReviewOperation
        let wall = Date(), uptime = ProcessInfo.processInfo.systemUptime
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<GatewayReportReviewHTTPResponse, any Error>?
        var failure: (any Error)?
        var boundary: ReportReviewResponseBoundary?
        var status = 0, data = Data(), chunks = 0
        var deadline: DispatchWorkItem?
        init(url: URL, operation: GatewayReportReviewOperation) {
            self.url = url
            self.operation = operation
        }
    }
    private let lock = NSLock()
    private var active: Ticket?
    func reserve(url: URL, operation: GatewayReportReviewOperation) throws -> UUID {
        try lock.withLock {
            guard active == nil else { throw GatewayReportReviewFailure.busy }
            let ticket = Ticket(url: url, operation: operation)
            active = ticket
            return ticket.id
        }
    }
    func attach(
        id: UUID, task: URLSessionDataTask,
        continuation: CheckedContinuation<GatewayReportReviewHTTPResponse, any Error>
    ) {
        let failure: (any Error)? = lock.withLock {
            guard let ticket = active, ticket.id == id else { return GatewayReportReviewFailure.unavailable }
            if let failure = ticket.failure {
                active = nil
                return failure
            }
            guard validTime(ticket) else {
                active = nil
                return GatewayReportReviewFailure.unavailable
            }
            ticket.task = task
            ticket.continuation = continuation
            let deadline = DispatchWorkItem { [weak self] in
                self?.fail(id: id, error: GatewayReportReviewFailure.unavailable)
            }
            ticket.deadline = deadline
            let elapsed = max(
                Date().timeIntervalSince(ticket.wall), ProcessInfo.processInfo.systemUptime - ticket.uptime)
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, 15 - elapsed), execute: deadline)
            return nil
        }
        if let failure {
            task.cancel()
            continuation.resume(throwing: failure)
        } else {
            task.resume()
        }
    }
    func fail(id: UUID, error: any Error) {
        let result: (URLSessionDataTask?, CheckedContinuation<GatewayReportReviewHTTPResponse, any Error>?) =
            lock.withLock {
                guard let ticket = active, ticket.id == id, ticket.failure == nil else { return (nil, nil) }
                ticket.failure = error
                ticket.data.removeAll(keepingCapacity: false)
                let continuation = ticket.continuation
                ticket.continuation = nil
                return (ticket.task, continuation)
            }
        result.0?.cancel()
        result.1?.resume(throwing: error)
    }
    private func validTime(_ ticket: Ticket) -> Bool {
        let wall = Date().timeIntervalSince(ticket.wall)
        let elapsed = ProcessInfo.processInfo.systemUptime - ticket.uptime
        return wall >= 0 && wall < 15 && elapsed >= 0 && elapsed < 15
    }
    func response(task: URLSessionDataTask, response: URLResponse) -> Bool {
        var failedID: UUID?
        let accepted = lock.withLock {
            guard let ticket = active, ticket.task === task, ticket.failure == nil else { return false }
            do {
                guard validTime(ticket), ticket.boundary == nil, let http = response as? HTTPURLResponse,
                    http.url == ticket.url
                else { throw GatewayReportReviewFailure.invalidResponse }
                var headers: [String: String] = [:]
                for (name, value) in http.allHeaderFields {
                    guard let name = name as? String, let value = value as? String else {
                        throw GatewayReportReviewFailure.invalidResponse
                    }
                    headers[name] = value
                }
                let boundary = try ReportReviewResponseBoundary(
                    status: http.statusCode, headers: headers, operation: ticket.operation)
                guard response.expectedContentLength <= boundary.maximum else {
                    throw GatewayReportReviewFailure.invalidResponse
                }
                ticket.boundary = boundary
                ticket.status = http.statusCode
                return true
            } catch {
                failedID = ticket.id
                return false
            }
        }
        if let failedID { fail(id: failedID, error: GatewayReportReviewFailure.invalidResponse) }
        return accepted
    }
    func data(task: URLSessionDataTask, data: Data) {
        var failedID: UUID?
        lock.withLock {
            guard let ticket = active, ticket.task === task, ticket.failure == nil else { return }
            guard validTime(ticket), let boundary = ticket.boundary,
                data.count <= boundary.maximum - ticket.data.count, data.isEmpty || ticket.chunks < 128
            else {
                failedID = ticket.id
                return
            }
            if !data.isEmpty {
                ticket.chunks += 1
                ticket.data.append(data)
            }
        }
        if let failedID { fail(id: failedID, error: GatewayReportReviewFailure.invalidResponse) }
    }
    func redirected(task: URLSessionTask) {
        let id = lock.withLock { active?.task === task ? active?.id : nil }
        if let id { fail(id: id, error: GatewayReportReviewFailure.invalidResponse) }
    }
    func complete(task: URLSessionTask, error: (any Error)?) {
        let result:
            (
                CheckedContinuation<GatewayReportReviewHTTPResponse, any Error>?,
                Result<GatewayReportReviewHTTPResponse, any Error>
            ) = lock.withLock {
                guard let ticket = active, ticket.task === task else {
                    return (nil, .failure(GatewayReportReviewFailure.unavailable))
                }
                ticket.deadline?.cancel()
                active = nil
                let continuation = ticket.continuation
                ticket.continuation = nil
                if let failure = ticket.failure { return (continuation, .failure(failure)) }
                guard error == nil, validTime(ticket), let boundary = ticket.boundary else {
                    return (continuation, .failure(GatewayReportReviewFailure.unavailable))
                }
                do {
                    try boundary.validate(ticket.data)
                    return (
                        continuation,
                        .success(.init(status: ticket.status, headers: boundary.headers, body: ticket.data))
                    )
                } catch { return (continuation, .failure(GatewayReportReviewFailure.invalidResponse)) }
            }
        result.0?.resume(with: result.1)
    }
}

private final class ReportReviewNetworkDelegate: NSObject, URLSessionDataDelegate {
    let gate: ReportReviewNetworkGate
    init(gate: ReportReviewNetworkGate) { self.gate = gate }
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(gate.response(task: dataTask, response: response) ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        gate.data(task: dataTask, data: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        gate.complete(task: task, error: error)
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        gate.redirected(task: task)
        completionHandler(nil)
    }
}

/// Dedicated pinned ephemeral session. No credentials/cookies/cache/redirects or automatic retry.
public final class NativeGatewayReportReviewTransport: GatewayReportReviewTransport {
    private let configuration: GatewayConfiguration
    private let gate = ReportReviewNetworkGate()
    private let session: URLSession
    public convenience init(configuration: GatewayConfiguration) {
        self.init(configuration: configuration, protocolClasses: nil)
    }
    init(configuration: GatewayConfiguration, protocolClasses: [AnyClass]?) {
        self.configuration = configuration
        let settings = URLSessionConfiguration.ephemeral
        if let protocolClasses { settings.protocolClasses = protocolClasses }
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.urlCredentialStorage = nil
        settings.urlCache = nil
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.timeoutIntervalForRequest = 15
        settings.timeoutIntervalForResource = 20
        settings.waitsForConnectivity = false
        session = URLSession(
            configuration: settings, delegate: ReportReviewNetworkDelegate(gate: gate), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest, operation: GatewayReportReviewOperation) async throws
        -> GatewayReportReviewHTTPResponse
    {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        let expected = configuration.origin.appendingPathComponent(
            "/v1/moderation/reports/" + operation.action)
        let body = try operation.wire()
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let names = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        guard request.url == expected, request.httpMethod == "POST", request.httpBody == body,
            request.httpBodyStream == nil,
            names == [
                "authorization", "content-type", "content-length", "accept", "accept-encoding",
                "cache-control",
            ],
            auth.hasPrefix("Bearer "), reportReviewToken(String(auth.dropFirst(7))),
            request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8",
            request.value(forHTTPHeaderField: "Accept") == "application/json",
            request.value(forHTTPHeaderField: "Accept-Encoding") == "identity",
            request.value(forHTTPHeaderField: "Cache-Control") == "no-store",
            request.value(forHTTPHeaderField: "Content-Length") == String(body.count)
        else { throw GatewayReportReviewFailure.invalidInput }
        let id = try gate.reserve(url: expected, operation: operation)
        var outbound = request
        outbound.timeoutInterval = 15
        outbound.cachePolicy = .reloadIgnoringLocalCacheData
        outbound.httpShouldHandleCookies = false
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.attach(id: id, task: session.dataTask(with: outbound), continuation: continuation)
            }
        } onCancel: {
            gate.fail(id: id, error: GatewayFailure.cancelled)
        }
    }
}
