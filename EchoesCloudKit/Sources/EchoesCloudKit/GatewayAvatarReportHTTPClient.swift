import Foundation

public protocol GatewayAvatarReportAPI: Sendable {
    var origin: String { get }
    func submit(_ submission: GatewayAvatarReportSubmission, token: GatewaySecret) async throws
        -> GatewayAvatarReportResult
    func recover(_ identity: GatewayAvatarReportIdentity, token: GatewaySecret) async throws
        -> GatewayAvatarReportResult
}
public protocol GatewayAvatarReportTransport: Sendable {
    func send(_ request: URLRequest, operation: GatewayAvatarReportOperation) async throws
        -> GatewayAvatarReportHTTPResponse
}

/// Disabled by default. No automatic retry, new requestID, journal or implicit display authorization.
public struct GatewayAvatarReportHTTPClient: GatewayAvatarReportAPI {
    private let configuration: GatewayConfiguration
    private let transport: any GatewayAvatarReportTransport
    private let isEnabled: @Sendable () -> Bool
    private let date: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    public var origin: String { configuration.origin.absoluteString }
    public init(
        configuration: GatewayConfiguration, transport: (any GatewayAvatarReportTransport)? = nil,
        isEnabled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.init(
            configuration: configuration,
            transport: transport ?? NativeGatewayAvatarReportTransport(configuration: configuration),
            isEnabled: isEnabled, date: { Date() }, uptime: { ProcessInfo.processInfo.systemUptime })
    }
    init(
        configuration: GatewayConfiguration, transport: any GatewayAvatarReportTransport,
        isEnabled: @escaping @Sendable () -> Bool = { true }, date: @escaping @Sendable () -> Date,
        uptime: @escaping @Sendable () -> TimeInterval
    ) {
        self.configuration = configuration
        self.transport = transport
        self.isEnabled = isEnabled
        self.date = date
        self.uptime = uptime
    }
    public func submit(_ submission: GatewayAvatarReportSubmission, token: GatewaySecret) async throws
        -> GatewayAvatarReportResult
    {
        try await perform(.submit(submission), token: token)
    }
    public func recover(_ identity: GatewayAvatarReportIdentity, token: GatewaySecret) async throws
        -> GatewayAvatarReportResult
    {
        try await perform(.recover(identity), token: token)
    }
    private func stamp() throws -> (wall: TimeInterval, uptime: TimeInterval) {
        let wall = date().timeIntervalSince1970
        let tick = uptime()
        guard wall.isFinite, wall >= 0, wall < 9_007_199_254_650, tick.isFinite, tick >= 0 else {
            throw GatewayAvatarReportFailure.unavailable
        }
        return (wall, tick)
    }
    private func checkActivation() throws {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isEnabled() else { throw GatewayAvatarReportFailure.unavailable }
    }
    private func perform(_ operation: GatewayAvatarReportOperation, token: GatewaySecret) async throws
        -> GatewayAvatarReportResult
    {
        try checkActivation()
        guard reportReviewToken(token.value) else { throw GatewayAvatarReportFailure.invalidInput }
        let start = try stamp()
        var request = URLRequest(
            url: configuration.origin.appendingPathComponent(operation.path),
            cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = try operation.wire()
        for (key, value) in [
            "Content-Type": "application/json; charset=utf-8", "Accept": "application/json",
            "Accept-Encoding": "identity", "Cache-Control": "no-store",
            "Authorization": "Bearer " + token.value, "Content-Length": String(request.httpBody!.count),
        ] { request.setValue(value, forHTTPHeaderField: key) }
        let response: GatewayAvatarReportHTTPResponse
        do { response = try await transport.send(request, operation: operation) } catch {
            try checkActivation()
            if error is CancellationError || (error as? GatewayFailure) == .cancelled {
                throw GatewayFailure.cancelled
            }
            throw (error as? GatewayAvatarReportFailure) ?? .unavailable
        }
        try checkActivation()
        let now = try stamp()
        guard now.wall >= start.wall, now.uptime >= start.uptime, now.wall - start.wall < 15,
            now.uptime - start.uptime < 15
        else { throw GatewayAvatarReportFailure.unavailable }
        let boundary = try AvatarReportResponseBoundary(
            status: response.status, headers: response.headers, operation: operation)
        try boundary.validate(response.body)
        if response.status != 200 { throw try avatarReportServerFailure(response, headers: boundary.headers) }
        _ = try avatarReportObject(
            response.body, keys: ["protocolVersion", "schemaVersion", "requestID", "reportID", "outcome"])
        struct Wire: Decodable {
            let protocolVersion: Int, schemaVersion: Int
            let requestID: String, reportID: String, outcome: String
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: response.body), wire.protocolVersion == 1,
            wire.schemaVersion == 1,
            wire.requestID == operation.identity.requestID, wire.reportID == operation.identity.reportID,
            let outcome = GatewayAvatarReportOutcome(rawValue: wire.outcome)
        else { throw GatewayAvatarReportFailure.invalidResponse }
        if case .submit = operation, outcome != .accepted { throw GatewayAvatarReportFailure.invalidResponse }
        try checkActivation()
        return .init(identity: operation.identity, outcome: outcome)
    }
}
func avatarReportObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
    guard !data.isEmpty, data.count <= 2048, String(data: data, encoding: .utf8) != nil,
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(value.keys) == keys
    else { throw GatewayAvatarReportFailure.invalidResponse }
    return value
}
private func avatarReportServerFailure(_ response: GatewayAvatarReportHTTPResponse, headers: [String: String])
    throws -> GatewayAvatarReportFailure
{
    _ = try avatarReportObject(response.body, keys: ["protocolVersion", "error"])
    struct Wire: Decodable {
        let protocolVersion: Int
        let error: String
    }
    guard let wire = try? JSONDecoder().decode(Wire.self, from: response.body), wire.protocolVersion == 1,
        avatarReportErrorStatuses[wire.error] == response.status
    else { throw GatewayAvatarReportFailure.invalidResponse }
    let retry = headers["retry-after"].flatMap { raw -> Int? in
        guard (1...6).contains(raw.utf8.count), raw.utf8.allSatisfy({ (48...57).contains($0) }),
            let value = Int(raw), value <= 86400
        else { return nil }
        return value
    }
    switch wire.error {
    case "INVALID_SESSION", "AVATAR_REPORT_SCOPE", "REAUTH_REQUIRED": throw GatewayFailure.signInRequired
    case "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS": return .denied
    case "AVATAR_REPORT_INPUT", "PUBLIC_INPUT": return .invalidInput
    case "AVATAR_REPORT_NOT_FOUND": return .notFound
    case "AVATAR_REPORT_CONFLICT", "PUBLIC_CONFLICT", "PUBLIC_PENDING", "PUBLIC_ERASED": return .conflict
    case "AVATAR_REPORT_LIMIT", "RATE_LIMITED", "PUBLIC_LIMIT": return .limited(retryAfterSeconds: retry)
    default: return .unavailable
    }
}
let avatarReportErrorStatuses = [
    "AVATAR_REPORT_INPUT": 400, "AVATAR_REPORT_SCOPE": 401, "AVATAR_REPORT_NOT_FOUND": 404,
    "AVATAR_REPORT_CONFLICT": 409,
    "AVATAR_REPORT_LIMIT": 429, "AVATAR_REPORT_RESPONSE": 503, "AVATAR_REPORT_UNAVAILABLE": 503,
    "REAUTH_REQUIRED": 401, "PUBLIC_INPUT": 400, "PUBLIC_SCOPE": 503, "PUBLIC_RESPONSE": 503,
    "PUBLIC_CONFLICT": 409,
    "PUBLIC_PENDING": 409, "PUBLIC_ERASED": 409, "PUBLIC_LIMIT": 429, "PUBLIC_THROTTLED": 503,
    "PUBLIC_REGISTRY_UNVERIFIED": 503, "PUBLIC_UNAVAILABLE": 503,
    "INVALID_REQUEST": 400, "HTTPS_REQUIRED": 400, "NOT_FOUND": 404, "METHOD_NOT_ALLOWED": 405,
    "ORIGIN_NOT_ALLOWED": 403,
    "INVALID_SESSION": 401, "ACCOUNT_DISABLED": 403, "DELETION_IN_PROGRESS": 403, "FEATURE_DISABLED": 503,
    "GATEWAY_DISABLED": 503,
    "RATE_LIMITED": 429, "CAPACITY_LIMITED": 503, "LIMIT_UNAVAILABLE": 503, "UNAVAILABLE": 503,
]
