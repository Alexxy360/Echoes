import CryptoKit
import EchoesCore
import Foundation

public enum GatewayAvatarFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidInput, invalidResponse, notFound, unavailable
    case limited(retryAfterSeconds: Int?)
    public var errorDescription: String? {
        switch self {
        case .invalidInput, .invalidResponse, .unavailable:
            "Nie udało się pobrać zdjęcia. Spróbuj ponownie."
        case .notFound: "To zdjęcie nie jest teraz dostępne."
        case .limited: "Odczekaj chwilę przed ponownym pobraniem zdjęcia."
        }
    }
}

/// A selection from a freshly authorized profile. No asset URL or CloudKit receipt is accepted.
public struct GatewayAvatarQuery: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let reference: AvatarReference
    public let variant: AvatarVariant
    public let coordinate: Coordinate?
    public let knownSHA256: String?
    public init(
        reference: AvatarReference, variant: AvatarVariant, coordinate: Coordinate? = nil,
        knownSHA256: String? = nil
    ) throws {
        guard coordinate == nil || coordinate!.isValid,
            knownSHA256 == nil || Self.validDigest(knownSHA256!)
        else { throw GatewayAvatarFailure.invalidInput }
        self.reference = reference
        self.variant = variant
        self.coordinate = coordinate
        self.knownSHA256 = knownSHA256
    }
    public var description: String { "GatewayAvatarQuery(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func encodedBody() throws -> Data {
        var fields: [String: Any] = [
            "ownerID": reference.ownerID, "versionID": reference.versionID, "variant": variant.rawValue,
        ]
        if let coordinate {
            fields["coordinate"] = ["latitude": coordinate.latitude, "longitude": coordinate.longitude]
        }
        if let knownSHA256 { fields["knownSHA256"] = knownSHA256 }
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }
}

/// Network authorization applies to this request only. Before rendering, decode with
/// AvatarPayloadValidator and recheck viewer identity, visibility and the selected version.
/// A 204 never authorizes offline display or substitutes for validating the cached bytes.
public enum GatewayAvatarReply: Sendable, CustomStringConvertible, CustomReflectable {
    case downloaded(manifest: AvatarManifest, bytes: Data)
    case revalidated(manifest: AvatarManifest)
    public var description: String { "GatewayAvatarReply(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public protocol GatewayAvatarReadAPI: Sendable {
    var origin: String { get }
    func read(_ query: GatewayAvatarQuery, token: GatewaySecret) async throws -> GatewayAvatarReply
}

/// Separate binary transport. Authentication/deletion retain their smaller JSON response limit.
public protocol GatewayAvatarTransport: Sendable {
    func send(_ request: URLRequest, query: GatewayAvatarQuery) async throws -> GatewayAvatarHTTPResponse
}

public struct GatewayAvatarHTTPResponse: Sendable, CustomStringConvertible, CustomReflectable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
    public var description: String { "GatewayAvatarHTTPResponse(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Validated before URLSession's body is buffered, and again after injected transports.
private struct AvatarResponseBoundary {
    let manifest: AvatarManifest?
    let maximumBytes: Int
    init(status: Int, headers: [String: String], query: GatewayAvatarQuery) throws {
        var normalized: [String: String] = [:]
        for (key, value) in headers {
            let lower = key.lowercased()
            guard normalized[lower] == nil else { throw GatewayAvatarFailure.invalidResponse }
            normalized[lower] = value
        }
        guard normalized["content-range"] == nil,
            normalized["content-encoding"] == nil || normalized["content-encoding"] == "identity"
        else { throw GatewayAvatarFailure.invalidResponse }
        if status == 200 || status == 204 {
            guard let raw = normalized["x-echoes-avatar-manifest"], raw.utf8.count <= 2048,
                raw.utf8.allSatisfy({ (32...126).contains($0) }),
                let policy = normalized["cache-control"]?.lowercased(),
                policy.split(separator: ",", omittingEmptySubsequences: false)
                    .map({ $0.trimmingCharacters(in: .whitespaces) }).sorted() == ["no-store", "private"],
                normalized["x-content-type-options"]?.lowercased() == "nosniff",
                let value = try? AvatarManifest(
                    data: Data(raw.utf8), expected: query.reference, variant: query.variant)
            else { throw GatewayAvatarFailure.invalidResponse }
            if status == 200 {
                guard normalized["content-type"]?.lowercased() == "image/jpeg",
                    normalized["content-length"] == String(value.byteCount)
                else { throw GatewayAvatarFailure.invalidResponse }
                maximumBytes = value.byteCount
            } else {
                guard normalized["content-type"] == nil, normalized["content-length"] == nil,
                    query.knownSHA256 == value.sha256
                else { throw GatewayAvatarFailure.invalidResponse }
                maximumBytes = 0
            }
            manifest = value
        } else {
            let type = normalized["content-type"]?.lowercased().replacingOccurrences(of: " ", with: "")
            guard (400...599).contains(status),
                type == "application/json" || type == "application/json;charset=utf-8"
            else { throw GatewayAvatarFailure.invalidResponse }
            if let length = normalized["content-length"] {
                guard !length.isEmpty, length.utf8.count <= 5,
                    length.utf8.allSatisfy({ (48...57).contains($0) }),
                    let count = Int(length), count <= 32_768
                else { throw GatewayAvatarFailure.invalidResponse }
            }
            manifest = nil
            maximumBytes = 32_768
        }
    }
}

private final class RefuseAvatarRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

private final class AvatarTransportAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    func acquire() throws {
        try lock.withLock {
            guard active < 4 else { throw GatewayAvatarFailure.limited(retryAfterSeconds: nil) }
            active += 1
        }
    }
    func release() { lock.withLock { active -= 1 } }
}

public final class NativeGatewayAvatarTransport: GatewayAvatarTransport {
    private let admission = AvatarTransportAdmission()
    private let session: URLSession
    public convenience init() { self.init(protocolClasses: nil) }
    // Package-only protocol injection exercises the actual URLSession body and redirect boundary.
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
            configuration: configuration, delegate: RefuseAvatarRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest, query: GatewayAvatarQuery) async throws
        -> GatewayAvatarHTTPResponse
    {
        do {
            try Task.checkCancellation()
            try admission.acquire()
            defer { admission.release() }
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.url == request.url else {
                throw GatewayAvatarFailure.invalidResponse
            }
            var headers: [String: String] = [:]
            for name in [
                "Content-Type", "Content-Length", "Content-Encoding", "Content-Range", "Cache-Control",
                "X-Content-Type-Options", "X-Echoes-Avatar-Manifest", "Retry-After",
            ] {
                if let value = http.value(forHTTPHeaderField: name) { headers[name] = value }
            }
            let boundary = try AvatarResponseBoundary(status: http.statusCode, headers: headers, query: query)
            guard response.expectedContentLength <= boundary.maximumBytes else {
                throw GatewayAvatarFailure.invalidResponse
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < boundary.maximumBytes else { throw GatewayAvatarFailure.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            return .init(status: http.statusCode, headers: headers, body: data)
        } catch {
            if Task.isCancelled || error is CancellationError { throw GatewayFailure.cancelled }
            if let failure = error as? GatewayAvatarFailure { throw failure }
            throw GatewayAvatarFailure.unavailable
        }
    }
}

/// Prepared protocol only: no endpoint is activated by constructing this client. The future host
/// must explicitly enable it after protected binary HTTP admission and account fencing are composed.
public struct GatewayAvatarHTTPClient: GatewayAvatarReadAPI {
    private let configuration: GatewayConfiguration
    private let transport: any GatewayAvatarTransport
    private let isEnabled: @Sendable () -> Bool
    public var origin: String { configuration.origin.absoluteString }
    public init(
        configuration: GatewayConfiguration,
        transport: any GatewayAvatarTransport = NativeGatewayAvatarTransport(),
        isEnabled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.isEnabled = isEnabled
    }
    public func read(_ query: GatewayAvatarQuery, token: GatewaySecret) async throws -> GatewayAvatarReply {
        try checkActivation()
        guard token.value.utf8.count == 80, gatewayUUID(String(token.value.prefix(36))),
            token.value.dropFirst(36).first == ".",
            token.value.suffix(43).utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                    || $0 == 95
            })
        else { throw GatewayAvatarFailure.invalidInput }
        var request = URLRequest(
            url: configuration.origin.appendingPathComponent("/v1/community/avatar/read"),
            cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = try query.encodedBody()
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("image/jpeg, application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer " + token.value, forHTTPHeaderField: "Authorization")
        let response: GatewayAvatarHTTPResponse
        do { response = try await transport.send(request, query: query) } catch {
            try checkActivation()
            if error is CancellationError { throw GatewayFailure.cancelled }
            if let failure = error as? GatewayAvatarFailure { throw failure }
            if let failure = error as? GatewayFailure, failure == .cancelled { throw failure }
            throw GatewayAvatarFailure.unavailable
        }
        try checkActivation()
        let boundary = try AvatarResponseBoundary(
            status: response.status, headers: response.headers, query: query)
        guard response.body.count <= boundary.maximumBytes else { throw GatewayAvatarFailure.invalidResponse }
        if let manifest = boundary.manifest {
            if response.status == 204 {
                try checkActivation()
                return .revalidated(manifest: manifest)
            }
            guard response.body.count == manifest.byteCount,
                response.body.starts(with: [0xff, 0xd8]),
                response.body.suffix(2).elementsEqual([0xff, 0xd9]),
                SHA256.hash(data: response.body).map({ String(format: "%02x", $0) }).joined()
                    == manifest.sha256
            else { throw GatewayAvatarFailure.invalidResponse }
            try checkActivation()
            return .downloaded(manifest: manifest, bytes: response.body)
        }
        throw try serverFailure(response)
    }
    private func checkActivation() throws {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isEnabled() else { throw GatewayAvatarFailure.unavailable }
    }
    private func serverFailure(_ response: GatewayAvatarHTTPResponse) throws -> any Error {
        struct Body: Decodable { let protocolVersion: Int, error: String }
        guard let value = try? JSONDecoder().decode(Body.self, from: response.body),
            value.protocolVersion == 1
        else { throw GatewayAvatarFailure.invalidResponse }
        let retryHeader = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
        let retry = retryHeader.flatMap {
            raw -> Int? in
            guard (1...6).contains(raw.utf8.count), raw.utf8.allSatisfy({ (48...57).contains($0) }),
                let seconds = Int(raw), seconds <= 86_400
            else { return nil }
            return seconds
        }
        switch value.error {
        case "INVALID_SESSION", "REAUTH_REQUIRED", "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS",
            "AVATAR_READ_STALE":
            return GatewayFailure.signInRequired
        case "AVATAR_READ_INPUT": return GatewayAvatarFailure.invalidInput
        case "AVATAR_READ_NOT_FOUND": return GatewayAvatarFailure.notFound
        case "AVATAR_READ_LIMIT", "RATE_LIMITED":
            return GatewayAvatarFailure.limited(retryAfterSeconds: retry)
        default: return GatewayAvatarFailure.unavailable
        }
    }
}
