import Foundation

public protocol GatewayAvatarReportReviewAPI: Sendable {
    var origin: String { get }
    func queue(after: GatewayAvatarReportReviewCursor?, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewPage
    func inspect(_ item: GatewayAvatarReportReviewItem, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewInspection
    func decide(_ intent: GatewayAvatarReportReviewDecisionIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewDecisionResult
    func recover(_ intent: GatewayAvatarReportReviewRecoveryIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewRecoveryResult
    func retire(_ intent: GatewayAvatarReportReviewRecoveryIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewRecoveryResult
}
extension GatewayAvatarReportReviewAPI {
    /// Legacy implementations remain closed until explicitly supporting the server fence.
    public func retire(_ intent: GatewayAvatarReportReviewRecoveryIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewRecoveryResult
    { throw GatewayAvatarReportReviewFailure.unavailable }
}
public protocol GatewayAvatarReportReviewTransport: Sendable {
    func send(_ request: URLRequest, operation: GatewayAvatarReportReviewOperation) async throws
        -> GatewayAvatarReportReviewHTTPResponse
}

/// Disabled by default. A host must fence native/private/session scope, actual display and durable decisions.
public struct GatewayAvatarReportReviewHTTPClient: GatewayAvatarReportReviewAPI {
    private let configuration: GatewayConfiguration
    private let transport: any GatewayAvatarReportReviewTransport
    private let decoder: any GatewayAvatarDecoding
    private let isEnabled: @Sendable () -> Bool
    private let date: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    public var origin: String { configuration.origin.absoluteString }
    public init(
        configuration: GatewayConfiguration, transport: (any GatewayAvatarReportReviewTransport)? = nil,
        isEnabled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.init(
            configuration: configuration,
            transport: transport ?? NativeGatewayAvatarReportReviewTransport(configuration: configuration),
            decoder: NativeGatewayAvatarDecoder(), isEnabled: isEnabled, date: { Date() },
            uptime: { ProcessInfo.processInfo.systemUptime })
    }
    init(
        configuration: GatewayConfiguration, transport: any GatewayAvatarReportReviewTransport,
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
    public func queue(after: GatewayAvatarReportReviewCursor?, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewPage
    {
        let (response, _, _) = try await perform(.queue(after: after), token: token)
        let root = try avatarReportReviewObject(
            response.body, keys: ["protocolVersion", "schemaVersion", "items", "after"])
        struct Wire: Decodable {
            let protocolVersion: Int, schemaVersion: Int
            let items: [AvatarReportReviewWireItem]
            let after: String?
        }
        guard let value = try? JSONDecoder().decode(Wire.self, from: response.body),
            value.protocolVersion == 1, value.schemaVersion == 1,
            let rows = root["items"] as? [[String: Any]], rows.count == value.items.count, rows.count <= 20
        else { throw GatewayAvatarReportReviewFailure.invalidResponse }
        let now = try stamp()
        var previous = after?.value ?? ""
        let items = try zip(rows, value.items).map { row, wire in
            guard Set(row.keys) == ["reportID", "createdAt", "expiresAt"] else {
                throw GatewayAvatarReportReviewFailure.invalidResponse
            }
            let item = try wire.item(now: now.milliseconds)
            guard item.reportID > previous else { throw GatewayAvatarReportReviewFailure.invalidResponse }
            previous = item.reportID
            return item
        }
        let next: GatewayAvatarReportReviewCursor?
        if let marker = value.after {
            guard let cursor = try? GatewayAvatarReportReviewCursor(marker), marker >= previous,
                marker > (after?.value ?? "")
            else { throw GatewayAvatarReportReviewFailure.invalidResponse }
            next = cursor
        } else {
            next = nil
        }
        try checkActivation()
        return .init(items: items, next: next)
    }
    public func inspect(_ item: GatewayAvatarReportReviewItem, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewInspection
    {
        let (response, observed, received) = try await perform(.inspect(item), token: token)
        let frame = try AvatarReportReviewFrame(response.body, item: item, now: received.milliseconds)
        let receipt = GatewayAvatarReportReviewReceipt(
            item: item, inspectionID: frame.inspectionID, contentHash: frame.contentHash,
            expiresAtMilliseconds: min(frame.expiresAt, observed.milliseconds + 90_000),
            origin: origin, sessionFingerprint: GatewayAvatarReportReviewReceipt.fingerprint(token),
            observed: observed, photoTarget: frame.target)
        let avatar: ValidatedAvatar?
        if let manifest = frame.manifest, let bytes = frame.image {
            do { avatar = try await decoder.decode(bytes, manifest: manifest) } catch {
                try checkActivation()
                if error is CancellationError || (error as? GatewayFailure) == .cancelled {
                    throw GatewayFailure.cancelled
                }
                throw GatewayAvatarReportReviewFailure.invalidResponse
            }
            guard avatar?.manifest == manifest, avatar?.image.width == manifest.width,
                avatar?.image.height == manifest.height
            else { throw GatewayAvatarReportReviewFailure.invalidResponse }
        } else {
            guard frame.manifest == nil, frame.image == nil, frame.target == nil else {
                throw GatewayAvatarReportReviewFailure.invalidResponse
            }
            avatar = nil
        }
        try checkActivation()
        let completed = try stamp()
        guard completed.milliseconds >= received.milliseconds, completed.uptime >= received.uptime,
            completed.milliseconds - observed.milliseconds < 15_000,
            (completed.uptime - observed.uptime) * 1000 < 15_000
        else { throw GatewayAvatarReportReviewFailure.stale }
        try receipt.validate(origin: origin, token: token, stamp: completed)
        return .init(receipt: receipt, reason: frame.reason, avatar: avatar)
    }
    public func decide(_ intent: GatewayAvatarReportReviewDecisionIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewDecisionResult
    {
        let (response, _, _) = try await perform(.decide(intent), token: token)
        _ = try avatarReportReviewObject(
            response.body,
            keys: [
                "protocolVersion", "schemaVersion", "reportID", "inspectionID", "decisionID", "verdict",
                "contentHash", "revision",
            ])
        struct Wire: Decodable {
            let protocolVersion: Int, schemaVersion: Int
            let reportID: String, inspectionID: String, decisionID: String, verdict: String,
                contentHash: String, revision: String
        }
        guard let value = try? JSONDecoder().decode(Wire.self, from: response.body),
            value.protocolVersion == 1, value.schemaVersion == 1,
            value.reportID == intent.receipt.item.reportID, value.inspectionID == intent.receipt.inspectionID,
            value.decisionID == intent.decisionID,
            value.verdict == intent.verdict.rawValue, value.contentHash == intent.receipt.contentHash,
            gatewayUUID(value.revision)
        else { throw GatewayAvatarReportReviewFailure.invalidResponse }
        try checkActivation()
        try intent.receipt.validate(origin: origin, token: token, stamp: stamp())
        return .init(intent: intent, revision: value.revision)
    }
    public func recover(_ intent: GatewayAvatarReportReviewRecoveryIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewRecoveryResult
    {
        try await outcome(intent, operation: .recover(intent), token: token)
    }
    public func retire(_ intent: GatewayAvatarReportReviewRecoveryIntent, token: GatewaySecret) async throws
        -> GatewayAvatarReportReviewRecoveryResult
    {
        try await outcome(intent, operation: .retire(intent), token: token)
    }
    private func outcome(
        _ intent: GatewayAvatarReportReviewRecoveryIntent, operation: GatewayAvatarReportReviewOperation,
        token: GatewaySecret
    ) async throws -> GatewayAvatarReportReviewRecoveryResult {
        let (response, _, _) = try await perform(operation, token: token)
        _ = try avatarReportReviewObject(
            response.body,
            keys: [
                "protocolVersion", "schemaVersion", "reportID", "decisionID", "verdict", "contentHash",
                "outcome", "revision",
            ])
        struct Wire: Decodable {
            let protocolVersion: Int, schemaVersion: Int
            let reportID: String, decisionID: String, verdict: String, contentHash: String, outcome: String
            let revision: String?
        }
        guard let value = try? JSONDecoder().decode(Wire.self, from: response.body),
            value.protocolVersion == 1, value.schemaVersion == 1,
            value.reportID == intent.reportID, value.decisionID == intent.decisionID,
            value.verdict == intent.verdict.rawValue, value.contentHash == intent.contentHash
        else { throw GatewayAvatarReportReviewFailure.invalidResponse }
        let outcome: GatewayAvatarReportReviewOutcome
        switch value.outcome {
        case "confirmed":
            guard let revision = value.revision, gatewayUUID(revision) else {
                throw GatewayAvatarReportReviewFailure.invalidResponse
            }
            outcome = .confirmed(revision: revision)
        case "not-applied", "superseded", "retired":
            guard value.revision == nil else { throw GatewayAvatarReportReviewFailure.invalidResponse }
            outcome =
                value.outcome == "not-applied"
                ? .notApplied : value.outcome == "retired" ? .retired : .superseded
        default: throw GatewayAvatarReportReviewFailure.invalidResponse
        }
        if case .retire = operation, !outcome.isTerminal {
            throw GatewayAvatarReportReviewFailure.invalidResponse
        }
        try checkActivation()
        return .init(intent: intent, outcome: outcome)
    }
    private func perform(_ operation: GatewayAvatarReportReviewOperation, token: GatewaySecret) async throws
        -> (
            GatewayAvatarReportReviewHTTPResponse, AvatarReportReviewStamp, AvatarReportReviewStamp
        )
    {
        try checkActivation()
        guard reportReviewToken(token.value) else { throw GatewayAvatarReportReviewFailure.invalidInput }
        let started = try stamp()
        if case .inspect(let item) = operation,
            item.createdAtMilliseconds > started.milliseconds
                || item.expiresAtMilliseconds <= started.milliseconds
        {
            throw GatewayAvatarReportReviewFailure.stale
        }
        if case .decide(let intent) = operation {
            try intent.receipt.validate(origin: origin, token: token, stamp: started)
        }
        var request = URLRequest(
            url: configuration.origin.appendingPathComponent(
                "/v1/moderation/avatar-reports/" + operation.action),
            cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = try operation.wire()
        for (name, value) in [
            "Content-Type": "application/json; charset=utf-8", "Accept": operation.acceptType,
            "Accept-Encoding": "identity", "Cache-Control": "no-store",
            "Authorization": "Bearer " + token.value,
            "Content-Length": String(request.httpBody!.count),
        ] { request.setValue(value, forHTTPHeaderField: name) }
        let response: GatewayAvatarReportReviewHTTPResponse
        do { response = try await transport.send(request, operation: operation) } catch {
            try checkActivation()
            if error is CancellationError || (error as? GatewayFailure) == .cancelled {
                throw GatewayFailure.cancelled
            }
            throw (error as? GatewayAvatarReportReviewFailure) ?? .unavailable
        }
        try checkActivation()
        let now = try stamp()
        guard now.milliseconds >= started.milliseconds, now.uptime >= started.uptime,
            now.milliseconds - started.milliseconds < 15_000, (now.uptime - started.uptime) * 1000 < 15_000
        else { throw GatewayAvatarReportReviewFailure.stale }
        let boundary = try AvatarReportReviewResponseBoundary(
            status: response.status, headers: response.headers, operation: operation)
        try boundary.validate(response.body)
        if response.status != 200 {
            throw try avatarReportReviewServerFailure(response, headers: boundary.headers)
        }
        return (response, started, now)
    }
    private func checkActivation() throws {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isEnabled() else { throw GatewayAvatarReportReviewFailure.unavailable }
    }
    private func stamp() throws -> AvatarReportReviewStamp { try .init(date: date(), uptime: uptime()) }
}
private struct AvatarReportReviewWireItem: Decodable {
    let reportID: String, createdAt: Int, expiresAt: Int
    func item(now: Int) throws -> GatewayAvatarReportReviewItem {
        guard reportReviewDates(created: createdAt, expires: expiresAt, lifetime: 2_592_000_000, now: now),
            let result = try? GatewayAvatarReportReviewItem(
                reportID: reportID, createdAtMilliseconds: createdAt, expiresAtMilliseconds: expiresAt)
        else { throw GatewayAvatarReportReviewFailure.invalidResponse }
        return result
    }
}
func avatarReportReviewObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
    guard !data.isEmpty, data.count <= 12288, String(data: data, encoding: .utf8) != nil,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == keys
    else { throw GatewayAvatarReportReviewFailure.invalidResponse }
    return object
}
private func avatarReportReviewServerFailure(
    _ response: GatewayAvatarReportReviewHTTPResponse, headers: [String: String]
)
    throws -> GatewayAvatarReportReviewFailure
{
    _ = try avatarReportReviewObject(response.body, keys: ["protocolVersion", "error"])
    struct Wire: Decodable {
        let protocolVersion: Int
        let error: String
    }
    guard let value = try? JSONDecoder().decode(Wire.self, from: response.body), value.protocolVersion == 1,
        avatarReportReviewErrorStatuses[value.error] == response.status
    else { throw GatewayAvatarReportReviewFailure.invalidResponse }
    let retry = headers["retry-after"].flatMap { raw -> Int? in
        guard (1...6).contains(raw.utf8.count), raw.utf8.allSatisfy({ (48...57).contains($0) }),
            let value = Int(raw), value <= 86400
        else { return nil }
        return value
    }
    switch value.error {
    case "AVATAR_REPORT_REVIEW_INPUT": return .invalidInput
    case "INVALID_SESSION": throw GatewayFailure.signInRequired
    case "AVATAR_REPORT_REVIEW_SCOPE", "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS": return .denied
    case "AVATAR_REPORT_REVIEW_STALE": return .stale
    case "AVATAR_REPORT_REVIEW_CAPACITY", "RATE_LIMITED": return .limited(retryAfterSeconds: retry)
    default: return .unavailable
    }
}
let avatarReportReviewErrorStatuses = [
    "AVATAR_REPORT_REVIEW_INPUT": 400, "AVATAR_REPORT_REVIEW_SCOPE": 403, "AVATAR_REPORT_REVIEW_STALE": 409,
    "AVATAR_REPORT_REVIEW_CAPACITY": 429, "AVATAR_REPORT_REVIEW_RESPONSE": 503,
    "AVATAR_REPORT_REVIEW_UNAVAILABLE": 503,
    "INVALID_REQUEST": 400,
    "HTTPS_REQUIRED": 400, "NOT_FOUND": 404, "METHOD_NOT_ALLOWED": 405, "ORIGIN_NOT_ALLOWED": 403,
    "INVALID_SESSION": 401,
    "ACCOUNT_DISABLED": 403, "DELETION_IN_PROGRESS": 403, "FEATURE_DISABLED": 503, "GATEWAY_DISABLED": 503,
    "RATE_LIMITED": 429,
    "CAPACITY_LIMITED": 503, "LIMIT_UNAVAILABLE": 503, "UNAVAILABLE": 503,
]
