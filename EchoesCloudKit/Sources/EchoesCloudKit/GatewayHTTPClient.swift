import Foundation

public struct GatewayConfiguration: Equatable, Sendable {
    public let origin: URL
    /// A trusted, explicit service origin. No fallback to a diagnostic worker or arbitrary redirect.
    public init(origin: URL) throws {
        guard let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
            parts.scheme == "https", let host = parts.host, host == host.lowercased(),
            host.contains("."), host != "localhost", host.utf8.count <= 253,
            host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
                    )
            }), !host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
            parts.port == nil, parts.user == nil, parts.password == nil,
            parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
            let canonical = URL(string: "https://" + host)
        else { throw GatewayFailure.configuration }
        self.origin = canonical
    }
}

public struct GatewayHTTPResponse: Sendable {
    public let status: Int
    public let contentType: String?
    public let retryAfter: String?
    public let body: Data
    public init(status: Int, contentType: String?, retryAfter: String? = nil, body: Data) {
        self.status = status
        self.contentType = contentType
        self.retryAfter = retryAfter
        self.body = body
    }
}

/// A trusted transport dependency, injectable for offline tests; never supplied by an HTTP response.
public protocol GatewayHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GatewayHTTPResponse
}

private final class RefuseGatewayRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

public final class NativeGatewayTransport: GatewayHTTPTransport {
    private let session: URLSession
    public convenience init() { self.init(protocolClasses: nil) }
    // Package-only injection for exercising the real URLSession streaming and redirect delegate.
    init(protocolClasses: [AnyClass]?) {
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: RefuseGatewayRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest) async throws -> GatewayHTTPResponse {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.url == request.url,
                response.expectedContentLength <= 32_768
            else { throw GatewayFailure.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 32_768 else { throw GatewayFailure.invalidResponse }
                data.append(byte)
            }
            return .init(
                status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"),
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"), body: data)
        } catch let failure as GatewayFailure { throw failure } catch is CancellationError {
            throw GatewayFailure.cancelled
        } catch { throw Task.isCancelled ? GatewayFailure.cancelled : GatewayFailure.transport }
    }
}

public struct GatewayHTTPClient: GatewayAuthenticationAPI {
    private let configuration: GatewayConfiguration
    private let transport: any GatewayHTTPTransport
    private let now: @Sendable () -> Date
    public var origin: String { configuration.origin.absoluteString }

    public init(
        configuration: GatewayConfiguration, transport: any GatewayHTTPTransport = NativeGatewayTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }

    public func challenge(purpose: GatewayChallengePurpose) async throws -> GatewayChallenge {
        let response: GatewayChallenge = try await post(
            "/v1/auth/challenge", fields: ["purpose": purpose.rawValue])
        try response.validate(now: now())
        return response
    }
    public func login(challengeID: String, identityToken: GatewaySecret, authorizationCode: GatewaySecret)
        async throws -> GatewaySessionPair
    {
        guard gatewayUUID(challengeID), identityToken.value.utf8.count <= 12_288,
            authorizationCode.value.utf8.count <= 2_048
        else { throw GatewayFailure.invalidInput }
        let response: GatewaySessionPair = try await post(
            "/v1/auth/login",
            fields: [
                "challengeID": challengeID,
                "identityToken": identityToken.value, "authorizationCode": authorizationCode.value,
            ])
        try response.validate(now: now())
        return response
    }
    public func renew(token: GatewaySecret) async throws -> GatewaySessionPair {
        guard token.value.utf8.count <= 120 else { throw GatewayFailure.invalidInput }
        let response: GatewaySessionPair = try await post("/v1/auth/renew", token: token)
        try response.validate(now: now())
        return response
    }
    public func session(token: GatewaySecret) async throws -> GatewaySessionStatus {
        let response: GatewaySessionStatus = try await post("/v1/auth/session", token: token)
        guard response.protocolVersion == 1, gatewayUUID(response.accountID),
            Double(response.expiresAt) > now().timeIntervalSince1970,
            Double(response.expiresAt) <= now().timeIntervalSince1970 + 660
        else { throw GatewayFailure.invalidResponse }
        return response
    }
    public func logout(token: GatewaySecret) async throws {
        try await emptyPost("/v1/auth/logout", token: token)
    }
    public func logoutAll(token: GatewaySecret) async throws {
        try await emptyPost("/v1/auth/logout-all", token: token)
    }

    private func post<T: Decodable>(
        _ path: String, fields: [String: String] = [:], token: GatewaySecret? = nil
    )
        async throws -> T
    {
        let response = try await request(path, fields: fields, token: token)
        guard response.status == 200 else { throw try serverFailure(response) }
        do { return try JSONDecoder().decode(T.self, from: response.body) } catch {
            throw GatewayFailure.invalidResponse
        }
    }
    private func emptyPost(_ path: String, token: GatewaySecret) async throws {
        let response = try await request(path, fields: [:], token: token)
        guard response.status == 204, response.body.isEmpty else {
            if response.status >= 400 { throw try serverFailure(response) }
            throw GatewayFailure.invalidResponse
        }
    }
    private func request(_ path: String, fields: [String: String], token: GatewaySecret?) async throws
        -> GatewayHTTPResponse
    {
        guard token == nil || token!.value.utf8.count <= 512 else { throw GatewayFailure.invalidInput }
        var request = URLRequest(url: configuration.origin.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token { request.setValue("Bearer " + token.value, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(fields)
        guard request.httpBody!.count <= 16_384 else { throw GatewayFailure.invalidInput }
        let response: GatewayHTTPResponse
        do { response = try await transport.send(request) } catch let failure as GatewayFailure {
            throw failure
        } catch { throw Task.isCancelled ? GatewayFailure.cancelled : GatewayFailure.transport }
        guard response.body.count <= 32_768 else { throw GatewayFailure.invalidResponse }
        if response.status != 204 {
            let type = response.contentType?.lowercased().replacingOccurrences(of: " ", with: "")
            guard type == "application/json" || type == "application/json;charset=utf-8" else {
                throw GatewayFailure.invalidResponse
            }
        }
        return response
    }
    private func serverFailure(_ response: GatewayHTTPResponse) throws -> GatewayFailure {
        struct Failure: Decodable {
            let protocolVersion: Int
            let error: String
        }
        guard (400...599).contains(response.status),
            let body = try? JSONDecoder().decode(Failure.self, from: response.body), body.protocolVersion == 1
        else { throw GatewayFailure.invalidResponse }
        let retry = response.retryAfter.flatMap { value -> Int? in
            guard !value.isEmpty, value.utf8.count <= 6, value.utf8.allSatisfy({ (48...57).contains($0) }),
                let seconds = Int(value), seconds <= 86_400
            else { return nil }
            return seconds
        }
        return .server(
            GatewayErrorCode(rawValue: body.error) ?? .other, status: response.status,
            retryAfterSeconds: retry)
    }
}
