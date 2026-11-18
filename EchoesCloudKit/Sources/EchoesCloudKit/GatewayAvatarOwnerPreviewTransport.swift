import CryptoKit
import Foundation

struct AvatarOwnerPreviewBoundary {
    let manifest: AvatarManifest?
    let maximum: Int, length: Int?
    let headers: [String: String]
    init(status: Int, headers: [String: String], query: GatewayAvatarOwnerPreviewQuery) throws {
        var values: [String: String] = [:]
        for (key, value) in headers {
            let name = key.lowercased()
            guard values[name] == nil else { throw GatewayAvatarFailure.invalidResponse }
            values[name] = value
        }
        guard status == 200 || avatarOwnerPreviewErrorStatus.values.contains(status),
            values["content-range"] == nil, values["x-echoes-avatar-review"] == nil,
            values["content-encoding"] == nil || values["content-encoding"] == "identity",
            values["x-content-type-options"]?.lowercased() == "nosniff"
        else { throw GatewayAvatarFailure.invalidResponse }
        if status == 200 {
            guard values["content-type"]?.lowercased() == "image/jpeg",
                values["cache-control"]?.lowercased().split(separator: ",", omittingEmptySubsequences: false)
                    .map({ $0.trimmingCharacters(in: .whitespaces) }).sorted() == ["no-store", "private"],
                let rawManifest = values["x-echoes-avatar-manifest"], rawManifest.utf8.count <= 2048,
                let rawProof = values["x-echoes-avatar-selection"], rawProof.utf8.count <= 512,
                [rawManifest, rawProof].allSatisfy({ $0.utf8.allSatisfy({ (32...126).contains($0) }) }),
                let reference = try? AvatarReference(
                    ownerID: query.ownerID, versionID: query.selection.versionID),
                let image = try? AvatarManifest(
                    data: Data(rawManifest.utf8), expected: reference, variant: .image)
            else { throw GatewayAvatarFailure.invalidResponse }
            _ = try avatarOwnerPreviewObject(
                Data(rawProof.utf8),
                keys: ["schemaVersion", "requestID", "versionID", "generation", "reviewRevision"])
            struct Proof: Decodable {
                let schemaVersion: Int, generation: Int
                let requestID: String, versionID: String, reviewRevision: String
            }
            guard let proof = try? JSONDecoder().decode(Proof.self, from: Data(rawProof.utf8)),
                proof.schemaVersion == 1, proof.requestID == query.selection.requestID,
                proof.versionID == query.selection.versionID, proof.generation == query.selection.generation,
                proof.reviewRevision == query.selection.reviewRevision,
                values["content-length"] == String(image.byteCount)
            else { throw GatewayAvatarFailure.invalidResponse }
            manifest = image
            maximum = image.byteCount
            length = image.byteCount
        } else {
            let type = values["content-type"]?.lowercased().replacingOccurrences(of: " ", with: "")
            guard type == "application/json" || type == "application/json;charset=utf-8",
                values["cache-control"]?.lowercased() == "no-store",
                values["x-echoes-avatar-manifest"] == nil, values["x-echoes-avatar-selection"] == nil
            else { throw GatewayAvatarFailure.invalidResponse }
            maximum = 2048
            if let raw = values["content-length"] {
                guard (1...4).contains(raw.utf8.count), raw.first != "0",
                    raw.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(raw), count <= maximum
                else { throw GatewayAvatarFailure.invalidResponse }
                length = count
            } else {
                length = nil
            }
            manifest = nil
        }
        self.headers = values
    }
    func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximum, length == nil || length == data.count else {
            throw GatewayAvatarFailure.invalidResponse
        }
        if let manifest {
            guard data.starts(with: [0xff, 0xd8]), data.suffix(2).elementsEqual([0xff, 0xd9]),
                SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == manifest.sha256
            else { throw GatewayAvatarFailure.invalidResponse }
        }
    }
}

private final class AvatarOwnerPreviewRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
private final class AvatarOwnerPreviewAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false
    func acquire() throws {
        try lock.withLock {
            guard !occupied else { throw GatewayAvatarFailure.busy }
            occupied = true
        }
    }
    func release() { lock.withLock { occupied = false } }
}

/// Dedicated ephemeral session. One unsettled operation, no redirects/cookies/cache/credentials
/// or application retry. Validate the exact selection BEFORE accepting the bounded binary stream.
public final class NativeGatewayAvatarOwnerPreviewTransport: GatewayAvatarOwnerPreviewTransport {
    private let admission = AvatarOwnerPreviewAdmission()
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
            configuration: configuration, delegate: AvatarOwnerPreviewRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest, query: GatewayAvatarOwnerPreviewQuery) async throws
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
                throw GatewayAvatarFailure.invalidResponse
            }
            var headers: [String: String] = [:]
            for name in [
                "Content-Type", "Content-Length", "Content-Encoding", "Content-Range", "Cache-Control",
                "X-Content-Type-Options", "X-Echoes-Avatar-Manifest", "X-Echoes-Avatar-Selection",
                "X-Echoes-Avatar-Review", "Retry-After",
            ] { if let value = http.value(forHTTPHeaderField: name) { headers[name] = value } }
            let boundary = try AvatarOwnerPreviewBoundary(
                status: http.statusCode, headers: headers, query: query)
            guard response.expectedContentLength <= boundary.maximum else {
                throw GatewayAvatarFailure.invalidResponse
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < boundary.maximum else { throw GatewayAvatarFailure.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            try boundary.validate(data)
            return .init(status: http.statusCode, headers: headers, body: data)
        } catch {
            if Task.isCancelled || error is CancellationError { throw GatewayFailure.cancelled }
            if let failure = error as? GatewayAvatarFailure { throw failure }
            throw GatewayAvatarFailure.unavailable
        }
    }
}
