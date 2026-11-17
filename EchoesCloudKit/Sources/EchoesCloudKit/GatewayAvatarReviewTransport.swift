import CryptoKit
import Foundation

struct AvatarReviewResponseBoundary {
    struct Proof: Decodable {
        let schemaVersion: Int, expiresAt: Int, generation: Int
        let inspectionID: String, requestID: String, reviewRevision: String
    }
    let manifest: AvatarManifest?
    let proof: Proof?
    let maximum: Int, length: Int?
    let headers: [String: String]
    init(
        status: Int, headers: [String: String], operation: GatewayAvatarReviewOperation,
        nowMilliseconds: Int
    ) throws {
        var values: [String: String] = [:]
        for (key, value) in headers {
            let name = key.lowercased()
            guard values[name] == nil else { throw GatewayAvatarReviewFailure.invalidResponse }
            values[name] = value
        }
        guard status == 200 || avatarReviewErrorStatus.values.contains(status),
            values["content-range"] == nil,
            values["content-encoding"] == nil || values["content-encoding"] == "identity",
            values["x-content-type-options"]?.lowercased() == "nosniff"
        else { throw GatewayAvatarReviewFailure.invalidResponse }
        if status == 200, case .inspect(let item) = operation {
            guard values["content-type"]?.lowercased() == "image/jpeg",
                let policy = values["cache-control"]?.lowercased(),
                policy.split(separator: ",", omittingEmptySubsequences: false)
                    .map({ $0.trimmingCharacters(in: .whitespaces) }).sorted() == ["no-store", "private"],
                let rawManifest = values["x-echoes-avatar-manifest"],
                let rawProof = values["x-echoes-avatar-review"], rawManifest.utf8.count <= 2048,
                rawProof.utf8.count <= 1024,
                [rawManifest, rawProof].allSatisfy({ $0.utf8.allSatisfy({ (32...126).contains($0) }) }),
                let reference = try? AvatarReference(ownerID: item.accountID, versionID: item.versionID),
                let image = try? AvatarManifest(
                    data: Data(rawManifest.utf8), expected: reference, variant: .image)
            else { throw GatewayAvatarReviewFailure.invalidResponse }
            _ = try avatarReviewObject(
                Data(rawProof.utf8),
                keys: [
                    "schemaVersion", "inspectionID", "expiresAt", "requestID", "generation", "reviewRevision",
                ])
            guard let receipt = try? JSONDecoder().decode(Proof.self, from: Data(rawProof.utf8)),
                receipt.schemaVersion == 1, gatewayUUID(receipt.inspectionID),
                receipt.requestID == item.requestID, receipt.generation == item.generation,
                receipt.reviewRevision == item.reviewRevision, receipt.expiresAt > nowMilliseconds,
                receipt.expiresAt <= nowMilliseconds + 90_000,
                values["content-length"] == String(image.byteCount)
            else { throw GatewayAvatarReviewFailure.invalidResponse }
            manifest = image
            proof = receipt
            maximum = image.byteCount
            length = image.byteCount
        } else {
            let type = values["content-type"]?.lowercased().replacingOccurrences(of: " ", with: "")
            guard type == "application/json" || type == "application/json;charset=utf-8",
                values["cache-control"]?.lowercased() == "no-store",
                values["x-echoes-avatar-manifest"] == nil, values["x-echoes-avatar-review"] == nil
            else { throw GatewayAvatarReviewFailure.invalidResponse }
            maximum = status == 200 && operation == .queue ? 8192 : 2048
            if let raw = values["content-length"] {
                guard (1...4).contains(raw.utf8.count), raw.first != "0",
                    raw.utf8.allSatisfy({ (48...57).contains($0) }),
                    let count = Int(raw), count <= maximum
                else { throw GatewayAvatarReviewFailure.invalidResponse }
                length = count
            } else {
                length = nil
            }
            manifest = nil
            proof = nil
        }
        self.headers = values
    }
    func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximum, length == nil || length == data.count else {
            throw GatewayAvatarReviewFailure.invalidResponse
        }
        if let manifest {
            guard data.starts(with: [0xff, 0xd8]), data.suffix(2).elementsEqual([0xff, 0xd9]),
                SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == manifest.sha256
            else { throw GatewayAvatarReviewFailure.invalidResponse }
        }
    }
}

private final class AvatarReviewRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
private final class AvatarReviewTransportAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false
    func acquire() throws {
        try lock.withLock {
            guard !occupied else { throw GatewayAvatarReviewFailure.busy }
            occupied = true
        }
    }
    func release() { lock.withLock { occupied = false } }
}

/// Dedicated ephemeral session: one unsettled request, no cookies/cache/credentials/redirects.
/// Limits and correlated binary headers are checked before buffering. No retry or receipt renewal.
public final class NativeGatewayAvatarReviewTransport: GatewayAvatarReviewTransport {
    private let admission = AvatarReviewTransportAdmission()
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
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        session = URLSession(
            configuration: configuration, delegate: AvatarReviewRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest, operation: GatewayAvatarReviewOperation) async throws
        -> GatewayAvatarHTTPResponse
    {
        do {
            try Task.checkCancellation()
            try admission.acquire()
            defer { admission.release() }
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url == request.url else {
                throw GatewayAvatarReviewFailure.invalidResponse
            }
            var headers: [String: String] = [:]
            for name in [
                "Content-Type", "Content-Length", "Content-Encoding", "Content-Range", "Cache-Control",
                "X-Content-Type-Options", "X-Echoes-Avatar-Manifest", "X-Echoes-Avatar-Review", "Retry-After",
            ] {
                if let value = http.value(forHTTPHeaderField: name) { headers[name] = value }
            }
            let now = try AvatarReviewStamp(date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
            let boundary = try AvatarReviewResponseBoundary(
                status: http.statusCode, headers: headers, operation: operation,
                nowMilliseconds: now.milliseconds)
            guard response.expectedContentLength <= boundary.maximum else {
                throw GatewayAvatarReviewFailure.invalidResponse
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < boundary.maximum else { throw GatewayAvatarReviewFailure.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            try boundary.validate(data)
            return .init(status: http.statusCode, headers: headers, body: data)
        } catch {
            if Task.isCancelled || error is CancellationError { throw GatewayFailure.cancelled }
            if let failure = error as? GatewayAvatarReviewFailure { throw failure }
            throw GatewayAvatarReviewFailure.unavailable
        }
    }
}
