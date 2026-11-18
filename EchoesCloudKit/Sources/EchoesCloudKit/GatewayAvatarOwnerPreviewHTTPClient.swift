import Foundation

public protocol GatewayAvatarOwnerPreviewAPI: Sendable {
    var origin: String { get }
    func preview(_ query: GatewayAvatarOwnerPreviewQuery, token: GatewaySecret) async throws
        -> GatewayAvatarOwnerPreview
}
public protocol GatewayAvatarOwnerPreviewTransport: Sendable {
    func send(_ request: URLRequest, query: GatewayAvatarOwnerPreviewQuery) async throws
        -> GatewayAvatarHTTPResponse
}

/// Inactive by default. Dedicated read-only owner endpoint; no upload, GPS, cache or moderator API.
public struct GatewayAvatarOwnerPreviewHTTPClient: GatewayAvatarOwnerPreviewAPI {
    private let configuration: GatewayConfiguration
    private let transport: any GatewayAvatarOwnerPreviewTransport
    private let decoder: any GatewayAvatarDecoding
    private let isEnabled: @Sendable () -> Bool
    private let date: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    public var origin: String { configuration.origin.absoluteString }
    public init(
        configuration: GatewayConfiguration,
        transport: any GatewayAvatarOwnerPreviewTransport = NativeGatewayAvatarOwnerPreviewTransport(),
        isEnabled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.init(
            configuration: configuration, transport: transport, decoder: NativeGatewayAvatarDecoder(),
            isEnabled: isEnabled, date: { Date() }, uptime: { ProcessInfo.processInfo.systemUptime })
    }
    init(
        configuration: GatewayConfiguration, transport: any GatewayAvatarOwnerPreviewTransport,
        decoder: any GatewayAvatarDecoding = NativeGatewayAvatarDecoder(),
        isEnabled: @escaping @Sendable () -> Bool, date: @escaping @Sendable () -> Date,
        uptime: @escaping @Sendable () -> TimeInterval
    ) {
        self.configuration = configuration
        self.transport = transport
        self.decoder = decoder
        self.isEnabled = isEnabled
        self.date = date
        self.uptime = uptime
    }
    public func preview(_ query: GatewayAvatarOwnerPreviewQuery, token: GatewaySecret) async throws
        -> GatewayAvatarOwnerPreview
    {
        try checkActivation()
        guard token.value.utf8.count == 80, gatewayUUID(String(token.value.prefix(36))),
            token.value.dropFirst(36).first == ".",
            token.value.suffix(43).utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 95
            })
        else { throw GatewayAvatarFailure.invalidInput }
        let observed = try stamp()
        var request = URLRequest(
            url: configuration.origin.appendingPathComponent("/v1/community/avatar/preview"),
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try query.wire()
        for (key, value) in [
            "Content-Type": "application/json; charset=utf-8", "Accept": "image/jpeg, application/json",
            "Accept-Encoding": "identity", "Cache-Control": "no-store",
            "Content-Length": String(request.httpBody!.count), "Authorization": "Bearer " + token.value,
        ] { request.setValue(value, forHTTPHeaderField: key) }
        let response: GatewayAvatarHTTPResponse
        do { response = try await transport.send(request, query: query) } catch {
            try checkActivation()
            if error is CancellationError || (error as? GatewayFailure) == .cancelled {
                throw GatewayFailure.cancelled
            }
            if let failure = error as? GatewayAvatarFailure { throw failure }
            throw GatewayAvatarFailure.unavailable
        }
        try checkActivation()
        try observed.validate(stamp())
        let boundary = try AvatarOwnerPreviewBoundary(
            status: response.status, headers: response.headers, query: query)
        try boundary.validate(response.body)
        if response.status != 200 {
            throw try avatarOwnerPreviewServerFailure(response, headers: boundary.headers)
        }
        guard let manifest = boundary.manifest else { throw GatewayAvatarFailure.invalidResponse }
        let avatar: ValidatedAvatar
        do { avatar = try await decoder.decode(response.body, manifest: manifest) } catch {
            try checkActivation()
            throw GatewayAvatarFailure.invalidResponse
        }
        try checkActivation()
        guard avatar.manifest == manifest, avatar.image.width == manifest.width,
            avatar.image.height == manifest.height
        else { throw GatewayAvatarFailure.invalidResponse }
        let result = GatewayAvatarOwnerPreview(
            query: query, avatar: avatar, origin: origin,
            sessionFingerprint: GatewayAvatarOwnerPreview.fingerprint(token), observed: observed)
        try result.validate(query: query, origin: origin, token: token, stamp: stamp())
        return result
    }
    private func stamp() throws -> AvatarOwnerPreviewStamp { try .init(date: date(), uptime: uptime()) }
    private func checkActivation() throws {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isEnabled() else { throw GatewayAvatarFailure.unavailable }
    }
}

private func avatarOwnerPreviewServerFailure(
    _ response: GatewayAvatarHTTPResponse, headers: [String: String]
) throws -> any Error {
    _ = try avatarOwnerPreviewObject(response.body, keys: ["protocolVersion", "error"])
    struct Wire: Decodable { let protocolVersion: Int, error: String }
    guard let value = try? JSONDecoder().decode(Wire.self, from: response.body), value.protocolVersion == 1,
        avatarOwnerPreviewErrorStatus[value.error] == response.status
    else { throw GatewayAvatarFailure.invalidResponse }
    let retry = headers["retry-after"].flatMap { raw -> Int? in
        guard (1...6).contains(raw.utf8.count), raw.utf8.allSatisfy({ (48...57).contains($0) }),
            let seconds = Int(raw), seconds <= 86_400
        else { return nil }
        return seconds
    }
    switch value.error {
    case "INVALID_SESSION", "AVATAR_READ_STALE", "REAUTH_REQUIRED", "ACCOUNT_DISABLED",
        "DELETION_IN_PROGRESS":
        return GatewayFailure.signInRequired
    case "AVATAR_READ_INPUT": return GatewayAvatarFailure.invalidInput
    case "AVATAR_READ_NOT_FOUND": return GatewayAvatarFailure.notFound
    case "AVATAR_READ_LIMIT", "RATE_LIMITED": return GatewayAvatarFailure.limited(retryAfterSeconds: retry)
    default: return GatewayAvatarFailure.unavailable
    }
}

let avatarOwnerPreviewErrorStatus = [
    "AVATAR_READ_INPUT": 400, "AVATAR_READ_NOT_FOUND": 404, "AVATAR_READ_STALE": 401,
    "AVATAR_READ_UNAVAILABLE": 503, "AVATAR_READ_RESPONSE": 503, "AVATAR_READ_LIMIT": 429,
    "INVALID_REQUEST": 400, "HTTPS_REQUIRED": 400, "NOT_FOUND": 404, "METHOD_NOT_ALLOWED": 405,
    "ORIGIN_NOT_ALLOWED": 403, "UNSUPPORTED_MEDIA_TYPE": 415, "BODY_TOO_LARGE": 413,
    "REQUEST_TIMEOUT": 408, "INVALID_SESSION": 401, "REAUTH_REQUIRED": 401, "ACCOUNT_DISABLED": 403,
    "DELETION_IN_PROGRESS": 403, "FEATURE_DISABLED": 503, "GATEWAY_DISABLED": 503,
    "RATE_LIMITED": 429, "CAPACITY_LIMITED": 503, "LIMIT_UNAVAILABLE": 503, "UNAVAILABLE": 503,
    "PUBLIC_INPUT": 400, "PUBLIC_CONFLICT": 409, "PUBLIC_PENDING": 409, "PUBLIC_ERASED": 409,
    "PUBLIC_LIMIT": 429, "PUBLIC_THROTTLED": 503, "PUBLIC_REGISTRY_UNVERIFIED": 503,
    "PUBLIC_UNAVAILABLE": 503,
]
