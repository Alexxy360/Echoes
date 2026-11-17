import Foundation

struct AvatarMutationResponseBoundary {
    let maximum: Int
    let length: Int?
    let headers: [String: String]
    init(status: Int, headers: [String: String]) throws {
        var values: [String: String] = [:]
        for (key, value) in headers {
            let name = key.lowercased()
            guard values[name] == nil else { throw GatewayAvatarMutationFailure.invalidResponse }
            values[name] = value
        }
        let type = values["content-type"]?.lowercased().replacingOccurrences(of: " ", with: "")
        guard [200, 400, 401, 403, 404, 405, 408, 409, 413, 415, 429, 503].contains(status),
            type == "application/json" || type == "application/json;charset=utf-8",
            values["cache-control"]?.lowercased() == "no-store",
            values["x-content-type-options"]?.lowercased() == "nosniff",
            values["content-range"] == nil,
            values["content-encoding"] == nil || values["content-encoding"] == "identity"
        else { throw GatewayAvatarMutationFailure.invalidResponse }
        maximum = status == 200 ? 2048 : 32_768
        if let raw = values["content-length"] {
            guard (1...5).contains(raw.utf8.count), raw.utf8.allSatisfy({ (48...57).contains($0) }),
                let count = Int(raw), count > 0, count <= maximum
            else { throw GatewayAvatarMutationFailure.invalidResponse }
            length = count
        } else {
            length = nil
        }
        self.headers = values
    }
    func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximum, length == nil || length == data.count else {
            throw GatewayAvatarMutationFailure.invalidResponse
        }
    }
}

private final class AvatarMutationRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
private final class AvatarMutationTransportAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var uploads = 0, controls = 0
    func acquire(upload: Bool) throws {
        try lock.withLock {
            guard upload ? uploads < 1 : controls < 4 else { throw GatewayAvatarMutationFailure.busy }
            if upload { uploads += 1 } else { controls += 1 }
        }
    }
    func release(upload: Bool) { lock.withLock { if upload { uploads -= 1 } else { controls -= 1 } } }
}

/// One upload/four controls per shared transport. Response limits apply before buffering;
/// cancellation/redirect failures never retry or replace the caller's persistent intent.
public final class NativeGatewayAvatarMutationTransport: GatewayAvatarMutationTransport {
    private let admission = AvatarMutationTransportAdmission()
    private let session: URLSession
    public convenience init() { self.init(protocolClasses: nil) }
    init(protocolClasses: [AnyClass]?) {
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 35
        configuration.waitsForConnectivity = false
        session = URLSession(
            configuration: configuration, delegate: AvatarMutationRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest, isUpload: Bool) async throws -> GatewayAvatarHTTPResponse {
        do {
            try Task.checkCancellation()
            try admission.acquire(upload: isUpload)
            defer { admission.release(upload: isUpload) }
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url == request.url else {
                throw GatewayAvatarMutationFailure.invalidResponse
            }
            var headers: [String: String] = [:]
            for name in [
                "Content-Type", "Content-Length", "Content-Encoding", "Content-Range", "Cache-Control",
                "X-Content-Type-Options", "Retry-After",
            ] {
                if let value = http.value(forHTTPHeaderField: name) { headers[name] = value }
            }
            let boundary = try AvatarMutationResponseBoundary(status: http.statusCode, headers: headers)
            guard response.expectedContentLength <= boundary.maximum else {
                throw GatewayAvatarMutationFailure.invalidResponse
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < boundary.maximum else {
                    throw GatewayAvatarMutationFailure.invalidResponse
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            try boundary.validate(data)
            return .init(status: http.statusCode, headers: headers, body: data)
        } catch {
            if Task.isCancelled || error is CancellationError { throw GatewayFailure.cancelled }
            if let failure = error as? GatewayAvatarMutationFailure { throw failure }
            throw GatewayAvatarMutationFailure.unavailable
        }
    }
}
