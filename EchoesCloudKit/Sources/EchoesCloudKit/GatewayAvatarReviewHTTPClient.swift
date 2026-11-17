import Foundation

public protocol GatewayAvatarReviewAPI: Sendable {
    var origin: String { get }
    func queue(token: GatewaySecret) async throws -> [GatewayAvatarReviewItem]
    func inspect(_ item: GatewayAvatarReviewItem, token: GatewaySecret) async throws
        -> GatewayAvatarReviewInspection
    func decide(_ intent: GatewayAvatarReviewDecisionIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReviewDecisionResult
}
public protocol GatewayAvatarReviewTransport: Sendable {
    func send(_ request: URLRequest, operation: GatewayAvatarReviewOperation) async throws
        -> GatewayAvatarHTTPResponse
}

/// Inactive by default. A dedicated host must fence native/private/session/foreground scope,
/// acknowledge actual display, and durably record the exact decision before calling decide.
public struct GatewayAvatarReviewHTTPClient: GatewayAvatarReviewAPI {
    private let configuration: GatewayConfiguration
    private let transport: any GatewayAvatarReviewTransport
    private let decoder: any GatewayAvatarDecoding
    private let isEnabled: @Sendable () -> Bool
    private let date: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    public var origin: String { configuration.origin.absoluteString }
    public init(
        configuration: GatewayConfiguration,
        transport: any GatewayAvatarReviewTransport = NativeGatewayAvatarReviewTransport(),
        isEnabled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.init(
            configuration: configuration, transport: transport, decoder: NativeGatewayAvatarDecoder(),
            isEnabled: isEnabled, date: { Date() }, uptime: { ProcessInfo.processInfo.systemUptime })
    }
    init(
        configuration: GatewayConfiguration, transport: any GatewayAvatarReviewTransport,
        decoder: any GatewayAvatarDecoding = NativeGatewayAvatarDecoder(),
        isEnabled: @escaping @Sendable () -> Bool = { true }, date: @escaping @Sendable () -> Date,
        uptime: @escaping @Sendable () -> TimeInterval
    ) {
        self.configuration = configuration
        self.transport = transport
        self.decoder = decoder
        self.isEnabled = isEnabled
        self.date = date
        self.uptime = uptime
    }
    public func queue(token: GatewaySecret) async throws -> [GatewayAvatarReviewItem] {
        let (response, _, _) = try await perform(.queue, token: token)
        let object = try avatarReviewObject(
            response.body, keys: ["protocolVersion", "schemaVersion", "items"])
        struct Wire: Decodable { let protocolVersion: Int, schemaVersion: Int }
        guard let versions = try? JSONDecoder().decode(Wire.self, from: response.body),
            versions.protocolVersion == 1, versions.schemaVersion == 1,
            let rows = object["items"] as? [[String: Any]], rows.count <= 20
        else { throw GatewayAvatarReviewFailure.invalidResponse }
        var seen = Set<String>()
        let result = try rows.map { row in
            let data = try JSONSerialization.data(withJSONObject: row)
            _ = try avatarReviewObject(
                data, keys: ["accountID", "requestID", "versionID", "generation", "reviewRevision"])
            struct Item: Decodable {
                let accountID: String, requestID: String, versionID: String, reviewRevision: String
                let generation: Int
            }
            guard let value = try? JSONDecoder().decode(Item.self, from: data),
                let item = try? GatewayAvatarReviewItem(
                    accountID: value.accountID, requestID: value.requestID, versionID: value.versionID,
                    generation: value.generation, reviewRevision: value.reviewRevision),
                seen.insert(item.accountID).inserted
            else { throw GatewayAvatarReviewFailure.invalidResponse }
            return item
        }
        try checkActivation()
        return result
    }
    public func inspect(_ item: GatewayAvatarReviewItem, token: GatewaySecret) async throws
        -> GatewayAvatarReviewInspection
    {
        let (response, boundary, observed) = try await perform(.inspect(item), token: token)
        guard let manifest = boundary.manifest, let proof = boundary.proof else {
            throw GatewayAvatarReviewFailure.invalidResponse
        }
        let receipt = GatewayAvatarReviewReceipt(
            item: item, inspectionID: proof.inspectionID, expiresAtMilliseconds: proof.expiresAt,
            origin: origin, sessionFingerprint: GatewayAvatarReviewReceipt.fingerprint(token),
            observedAtMilliseconds: observed.milliseconds, observedUptime: observed.uptime)
        let avatar: ValidatedAvatar
        do { avatar = try await decoder.decode(response.body, manifest: manifest) } catch {
            try checkActivation()
            throw GatewayAvatarReviewFailure.invalidResponse
        }
        try checkActivation()
        try receipt.validate(origin: origin, token: token, stamp: stamp())
        guard avatar.manifest == manifest, avatar.image.width == manifest.width,
            avatar.image.height == manifest.height
        else { throw GatewayAvatarReviewFailure.invalidResponse }
        return .init(receipt: receipt, avatar: avatar)
    }
    public func decide(_ intent: GatewayAvatarReviewDecisionIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReviewDecisionResult
    {
        let (response, _, _) = try await perform(.decide(intent), token: token)
        _ = try avatarReviewObject(
            response.body,
            keys: [
                "protocolVersion", "schemaVersion", "inspectionID", "accountID", "requestID",
                "decisionID", "revision", "verdict",
            ])
        struct Wire: Decodable {
            let protocolVersion: Int, schemaVersion: Int
            let inspectionID: String, accountID: String, requestID: String, decisionID: String
            let revision: String, verdict: String
        }
        guard let value = try? JSONDecoder().decode(Wire.self, from: response.body),
            value.protocolVersion == 1, value.schemaVersion == 1,
            value.inspectionID == intent.receipt.inspectionID,
            value.accountID == intent.receipt.item.accountID,
            value.requestID == intent.receipt.item.requestID, value.decisionID == intent.decisionID,
            value.verdict == intent.verdict.rawValue, gatewayUUID(value.revision),
            value.revision != intent.receipt.item.reviewRevision
        else { throw GatewayAvatarReviewFailure.invalidResponse }
        try checkActivation()
        try intent.receipt.validate(origin: origin, token: token, stamp: stamp())
        return .init(intent: intent, revision: value.revision)
    }
    private func perform(_ operation: GatewayAvatarReviewOperation, token: GatewaySecret) async throws
        -> (GatewayAvatarHTTPResponse, AvatarReviewResponseBoundary, AvatarReviewStamp)
    {
        try checkActivation()
        guard token.value.utf8.count == 80, gatewayUUID(String(token.value.prefix(36))),
            token.value.dropFirst(36).first == ".",
            token.value.suffix(43).utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 95
            })
        else { throw GatewayAvatarReviewFailure.invalidInput }
        let started = try stamp()
        if case .decide(let intent) = operation {
            try intent.receipt.validate(origin: origin, token: token, stamp: started)
        }
        var request = URLRequest(
            url: configuration.origin.appendingPathComponent("/v1/moderation/avatar/" + operation.action),
            cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = try operation.wire()
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("image/jpeg, application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(String(request.httpBody!.count), forHTTPHeaderField: "Content-Length")
        request.setValue("Bearer " + token.value, forHTTPHeaderField: "Authorization")
        let response: GatewayAvatarHTTPResponse
        do { response = try await transport.send(request, operation: operation) } catch {
            try checkActivation()
            if error is CancellationError || (error as? GatewayFailure) == .cancelled {
                throw GatewayFailure.cancelled
            }
            if let failure = error as? GatewayAvatarReviewFailure { throw failure }
            throw GatewayAvatarReviewFailure.unavailable
        }
        try checkActivation()
        let now = try stamp()
        guard now.milliseconds >= started.milliseconds, now.uptime >= started.uptime else {
            throw GatewayAvatarReviewFailure.stale
        }
        let boundary = try AvatarReviewResponseBoundary(
            status: response.status, headers: response.headers, operation: operation,
            nowMilliseconds: now.milliseconds)
        try boundary.validate(response.body)
        if response.status != 200 { throw try avatarReviewServerFailure(response, headers: boundary.headers) }
        return (response, boundary, started)
    }
    private func checkActivation() throws {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isEnabled() else { throw GatewayAvatarReviewFailure.unavailable }
    }
    private func stamp() throws -> AvatarReviewStamp { try .init(date: date(), uptime: uptime()) }
}

func avatarReviewObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
    guard !data.isEmpty, data.count <= 8192, String(data: data, encoding: .utf8) != nil,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        Set(object.keys) == keys
    else { throw GatewayAvatarReviewFailure.invalidResponse }
    return object
}

private func avatarReviewServerFailure(_ response: GatewayAvatarHTTPResponse, headers: [String: String])
    throws -> any Error
{
    _ = try avatarReviewObject(response.body, keys: ["protocolVersion", "error"])
    struct Wire: Decodable { let protocolVersion: Int, error: String }
    guard let value = try? JSONDecoder().decode(Wire.self, from: response.body), value.protocolVersion == 1,
        let status = avatarReviewErrorStatus[value.error], status == response.status
    else { throw GatewayAvatarReviewFailure.invalidResponse }
    let retry = headers["retry-after"].flatMap { raw -> Int? in
        guard (1...6).contains(raw.utf8.count), raw.utf8.allSatisfy({ (48...57).contains($0) }),
            let seconds = Int(raw), seconds <= 86_400
        else { return nil }
        return seconds
    }
    switch value.error {
    case "INVALID_SESSION", "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS": return GatewayFailure.signInRequired
    case "AVATAR_REVIEW_INPUT": return GatewayAvatarReviewFailure.invalidInput
    case "AVATAR_REVIEW_SCOPE": return GatewayAvatarReviewFailure.denied
    case "AVATAR_REVIEW_STALE": return GatewayAvatarReviewFailure.stale
    case "AVATAR_REVIEW_PENDING": return GatewayAvatarReviewFailure.pending
    case "AVATAR_REVIEW_RATE", "AVATAR_REVIEW_CAPACITY", "RATE_LIMITED":
        return GatewayAvatarReviewFailure.limited(retryAfterSeconds: retry)
    default: return GatewayAvatarReviewFailure.unavailable
    }
}

let avatarReviewErrorStatus = [
    "AVATAR_REVIEW_INPUT": 400, "AVATAR_REVIEW_SCOPE": 403, "AVATAR_REVIEW_STALE": 409,
    "AVATAR_REVIEW_PENDING": 409, "AVATAR_REVIEW_RESPONSE": 503, "AVATAR_REVIEW_UNAVAILABLE": 503,
    "AVATAR_REVIEW_RATE": 429, "AVATAR_REVIEW_CAPACITY": 429, "INVALID_REQUEST": 400,
    "HTTPS_REQUIRED": 400, "NOT_FOUND": 404, "METHOD_NOT_ALLOWED": 405, "ORIGIN_NOT_ALLOWED": 403,
    "UNSUPPORTED_MEDIA_TYPE": 415, "BODY_TOO_LARGE": 413, "REQUEST_TIMEOUT": 408, "INVALID_SESSION": 401,
    "ACCOUNT_DISABLED": 403, "DELETION_IN_PROGRESS": 403, "FEATURE_DISABLED": 503,
    "GATEWAY_DISABLED": 503, "RATE_LIMITED": 429, "CAPACITY_LIMITED": 503, "LIMIT_UNAVAILABLE": 503,
    "UNAVAILABLE": 503,
]
