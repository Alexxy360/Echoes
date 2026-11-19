import Foundation

public protocol GatewayReportReviewAPI: Sendable {
    var origin: String { get }
    func queue(after: GatewayReportReviewCursor?, token: GatewaySecret) async throws
        -> GatewayReportReviewPage
    func inspect(_ item: GatewayReportReviewItem, token: GatewaySecret) async throws
        -> GatewayReportReviewInspection
    func decide(_ intent: GatewayReportReviewDecisionIntent, token: GatewaySecret) async throws
        -> GatewayReportReviewDecisionResult
    func recover(_ intent: GatewayReportReviewRecoveryIntent, token: GatewaySecret) async throws
        -> GatewayReportReviewRecoveryResult
}
public protocol GatewayReportReviewTransport: Sendable {
    func send(_ request: URLRequest, operation: GatewayReportReviewOperation) async throws
        -> GatewayReportReviewHTTPResponse
}

/// Disabled by default. A host must fence native/private/session scope, actual display and durable decisions.
public struct GatewayReportReviewHTTPClient: GatewayReportReviewAPI {
    private let configuration: GatewayConfiguration
    private let transport: any GatewayReportReviewTransport
    private let isEnabled: @Sendable () -> Bool
    private let date: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    public var origin: String { configuration.origin.absoluteString }
    public init(
        configuration: GatewayConfiguration, transport: (any GatewayReportReviewTransport)? = nil,
        isEnabled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.init(
            configuration: configuration,
            transport: transport ?? NativeGatewayReportReviewTransport(configuration: configuration),
            isEnabled: isEnabled, date: { Date() }, uptime: { ProcessInfo.processInfo.systemUptime })
    }
    init(
        configuration: GatewayConfiguration, transport: any GatewayReportReviewTransport,
        isEnabled: @escaping @Sendable () -> Bool = { true }, date: @escaping @Sendable () -> Date,
        uptime: @escaping @Sendable () -> TimeInterval
    ) {
        self.configuration = configuration
        self.transport = transport
        self.isEnabled = isEnabled
        self.date = date
        self.uptime = uptime
    }
    public func queue(after: GatewayReportReviewCursor?, token: GatewaySecret) async throws
        -> GatewayReportReviewPage
    {
        let (response, _) = try await perform(.queue(after: after), token: token)
        let root = try reportReviewObject(
            response.body, keys: ["protocolVersion", "schemaVersion", "items", "after"])
        struct Wire: Decodable {
            let protocolVersion: Int, schemaVersion: Int
            let items: [ReportReviewWireItem]
            let after: String?
        }
        guard let value = try? JSONDecoder().decode(Wire.self, from: response.body),
            value.protocolVersion == 1, value.schemaVersion == 1,
            let rows = root["items"] as? [[String: Any]], rows.count == value.items.count, rows.count <= 20
        else { throw GatewayReportReviewFailure.invalidResponse }
        let now = try stamp()
        var previous = after?.value ?? ""
        let items = try zip(rows, value.items).map { row, wire in
            guard Set(row.keys) == ["reportID", "createdAt", "expiresAt"] else {
                throw GatewayReportReviewFailure.invalidResponse
            }
            let item = try wire.item(now: now.milliseconds)
            guard item.reportID > previous else { throw GatewayReportReviewFailure.invalidResponse }
            previous = item.reportID
            return item
        }
        let next: GatewayReportReviewCursor?
        if let marker = value.after {
            guard let cursor = try? GatewayReportReviewCursor(marker), marker >= previous,
                marker > (after?.value ?? "")
            else { throw GatewayReportReviewFailure.invalidResponse }
            next = cursor
        } else {
            next = nil
        }
        try checkActivation()
        return .init(items: items, next: next)
    }
    public func inspect(_ item: GatewayReportReviewItem, token: GatewaySecret) async throws
        -> GatewayReportReviewInspection
    {
        let (response, observed) = try await perform(.inspect(item), token: token)
        let root = try reportReviewObject(
            response.body,
            keys: [
                "protocolVersion", "schemaVersion", "inspectionID", "inspectionExpiresAt", "contentHash",
                "reportID", "createdAt", "expiresAt", "reason", "messageID", "message",
            ])
        struct Wire: Decodable {
            let protocolVersion: Int, schemaVersion: Int, inspectionExpiresAt: Int, createdAt: Int,
                expiresAt: Int
            let inspectionID: String, contentHash: String, reportID: String, reason: String, messageID: String
            let message: Message?
            struct Message: Decodable {
                let authorID: String, name: String, text: String
                let createdAt: Int, expiresAt: Int
            }
        }
        let now = try stamp()
        guard let value = try? JSONDecoder().decode(Wire.self, from: response.body),
            value.protocolVersion == 1, value.schemaVersion == 1,
            value.reportID == item.reportID, value.createdAt == item.createdAtMilliseconds,
            value.expiresAt == item.expiresAtMilliseconds,
            gatewayUUID(value.inspectionID), reportReviewHash(value.contentHash),
            reportReviewMessageID(value.messageID),
            reportReviewText(value.reason, maximum: 500), value.createdAt <= now.milliseconds,
            value.expiresAt > now.milliseconds,
            value.inspectionExpiresAt > now.milliseconds,
            value.inspectionExpiresAt <= now.milliseconds + 90_000,
            value.inspectionExpiresAt <= value.expiresAt
        else { throw GatewayReportReviewFailure.invalidResponse }
        let message: GatewayReportReviewMessage?
        if let wire = value.message {
            guard let fields = root["message"] as? [String: Any],
                Set(fields.keys) == ["authorID", "name", "text", "createdAt", "expiresAt"],
                gatewayUUID(wire.authorID), reportReviewText(wire.name, maximum: 40),
                reportReviewText(wire.text, maximum: 500),
                reportReviewDates(
                    created: wire.createdAt, expires: wire.expiresAt, lifetime: 7_200_000,
                    now: now.milliseconds)
            else { throw GatewayReportReviewFailure.invalidResponse }
            message = .init(
                authorID: wire.authorID, name: wire.name, text: wire.text,
                createdAtMilliseconds: wire.createdAt, expiresAtMilliseconds: wire.expiresAt)
        } else {
            guard root["message"] is NSNull else { throw GatewayReportReviewFailure.invalidResponse }
            message = nil
        }
        let receipt = GatewayReportReviewReceipt(
            item: item, inspectionID: value.inspectionID, contentHash: value.contentHash,
            expiresAtMilliseconds: min(
                value.inspectionExpiresAt, observed.milliseconds + 90_000,
                message?.expiresAtMilliseconds ?? value.expiresAt),
            origin: origin, sessionFingerprint: GatewayReportReviewReceipt.fingerprint(token),
            observed: observed, messageAvailable: message != nil)
        try checkActivation()
        try receipt.validate(origin: origin, token: token, stamp: now)
        return .init(receipt: receipt, reason: value.reason, messageID: value.messageID, message: message)
    }
    public func decide(_ intent: GatewayReportReviewDecisionIntent, token: GatewaySecret) async throws
        -> GatewayReportReviewDecisionResult
    {
        let (response, _) = try await perform(.decide(intent), token: token)
        _ = try reportReviewObject(
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
        else { throw GatewayReportReviewFailure.invalidResponse }
        try checkActivation()
        try intent.receipt.validate(origin: origin, token: token, stamp: stamp())
        return .init(intent: intent, revision: value.revision)
    }
    public func recover(_ intent: GatewayReportReviewRecoveryIntent, token: GatewaySecret) async throws
        -> GatewayReportReviewRecoveryResult
    {
        let (response, _) = try await perform(.recover(intent), token: token)
        _ = try reportReviewObject(
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
        else { throw GatewayReportReviewFailure.invalidResponse }
        let outcome: GatewayReportReviewOutcome
        switch value.outcome {
        case "confirmed":
            guard let revision = value.revision, gatewayUUID(revision) else {
                throw GatewayReportReviewFailure.invalidResponse
            }
            outcome = .confirmed(revision: revision)
        case "not-applied", "superseded":
            guard value.revision == nil else { throw GatewayReportReviewFailure.invalidResponse }
            outcome = value.outcome == "not-applied" ? .notApplied : .superseded
        default: throw GatewayReportReviewFailure.invalidResponse
        }
        try checkActivation()
        return .init(intent: intent, outcome: outcome)
    }
    private func perform(_ operation: GatewayReportReviewOperation, token: GatewaySecret) async throws -> (
        GatewayReportReviewHTTPResponse, ReportReviewStamp
    ) {
        try checkActivation()
        guard reportReviewToken(token.value) else { throw GatewayReportReviewFailure.invalidInput }
        let started = try stamp()
        if case .inspect(let item) = operation,
            item.createdAtMilliseconds > started.milliseconds
                || item.expiresAtMilliseconds <= started.milliseconds
        {
            throw GatewayReportReviewFailure.stale
        }
        if case .decide(let intent) = operation {
            try intent.receipt.validate(origin: origin, token: token, stamp: started)
        }
        var request = URLRequest(
            url: configuration.origin.appendingPathComponent("/v1/moderation/reports/" + operation.action),
            cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = try operation.wire()
        for (name, value) in [
            "Content-Type": "application/json; charset=utf-8", "Accept": "application/json",
            "Accept-Encoding": "identity", "Cache-Control": "no-store",
            "Authorization": "Bearer " + token.value,
            "Content-Length": String(request.httpBody!.count),
        ] { request.setValue(value, forHTTPHeaderField: name) }
        let response: GatewayReportReviewHTTPResponse
        do { response = try await transport.send(request, operation: operation) } catch {
            try checkActivation()
            if error is CancellationError || (error as? GatewayFailure) == .cancelled {
                throw GatewayFailure.cancelled
            }
            throw (error as? GatewayReportReviewFailure) ?? .unavailable
        }
        try checkActivation()
        let now = try stamp()
        guard now.milliseconds >= started.milliseconds, now.uptime >= started.uptime,
            now.milliseconds - started.milliseconds < 15_000, (now.uptime - started.uptime) * 1000 < 15_000
        else { throw GatewayReportReviewFailure.stale }
        let boundary = try ReportReviewResponseBoundary(
            status: response.status, headers: response.headers, operation: operation)
        try boundary.validate(response.body)
        if response.status != 200 { throw try reportReviewServerFailure(response, headers: boundary.headers) }
        return (response, started)
    }
    private func checkActivation() throws {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isEnabled() else { throw GatewayReportReviewFailure.unavailable }
    }
    private func stamp() throws -> ReportReviewStamp { try .init(date: date(), uptime: uptime()) }
}
private struct ReportReviewWireItem: Decodable {
    let reportID: String, createdAt: Int, expiresAt: Int
    func item(now: Int) throws -> GatewayReportReviewItem {
        guard reportReviewDates(created: createdAt, expires: expiresAt, lifetime: 2_592_000_000, now: now),
            let result = try? GatewayReportReviewItem(
                reportID: reportID, createdAtMilliseconds: createdAt, expiresAtMilliseconds: expiresAt)
        else { throw GatewayReportReviewFailure.invalidResponse }
        return result
    }
}
func reportReviewObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
    guard !data.isEmpty, data.count <= 12288, String(data: data, encoding: .utf8) != nil,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == keys
    else { throw GatewayReportReviewFailure.invalidResponse }
    return object
}
func reportReviewDates(created: Int, expires: Int, lifetime: Int, now: Int) -> Bool {
    (0...9_007_199_254_740_991).contains(created) && (0...9_007_199_254_740_991).contains(expires)
        && created <= now && expires > now && expires - created == lifetime
}
func reportReviewToken(_ token: String) -> Bool {
    token.utf8.count == 80 && gatewayUUID(String(token.prefix(36))) && token.dropFirst(36).first == "."
        && token.suffix(43).utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                || $0 == 95
        }
}
func reportReviewText(_ text: String, maximum: Int) -> Bool {
    let white: (UInt32) -> Bool = { value in
        [9, 10, 11, 12, 13, 32, 160, 5760, 8232, 8233, 8239, 8287, 12288, 65279].contains(value)
            || (8192...8202).contains(value)
    }
    guard !text.isEmpty, text.utf16.count <= maximum,
        text.utf8.elementsEqual(text.precomposedStringWithCanonicalMapping.utf8),
        let first = text.unicodeScalars.first, let last = text.unicodeScalars.last, !white(first.value),
        !white(last.value)
    else { return false }
    return !text.unicodeScalars.contains { scalar in
        let v = scalar.value
        return v <= 8 || (11...31).contains(v) || v == 127 || (8234...8238).contains(v)
            || (8294...8297).contains(v)
    }
}
private func reportReviewServerFailure(_ response: GatewayReportReviewHTTPResponse, headers: [String: String])
    throws -> GatewayReportReviewFailure
{
    _ = try reportReviewObject(response.body, keys: ["protocolVersion", "error"])
    struct Wire: Decodable {
        let protocolVersion: Int
        let error: String
    }
    guard let value = try? JSONDecoder().decode(Wire.self, from: response.body), value.protocolVersion == 1,
        reportReviewErrorStatuses[value.error] == response.status
    else { throw GatewayReportReviewFailure.invalidResponse }
    let retry = headers["retry-after"].flatMap { raw -> Int? in
        guard (1...6).contains(raw.utf8.count), raw.utf8.allSatisfy({ (48...57).contains($0) }),
            let value = Int(raw), value <= 86400
        else { return nil }
        return value
    }
    switch value.error {
    case "REPORT_REVIEW_INPUT": return .invalidInput
    case "INVALID_SESSION": throw GatewayFailure.signInRequired
    case "REPORT_REVIEW_SCOPE", "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS": return .denied
    case "REPORT_REVIEW_STALE": return .stale
    case "REPORT_REVIEW_CAPACITY", "RATE_LIMITED": return .limited(retryAfterSeconds: retry)
    default: return .unavailable
    }
}
let reportReviewErrorStatuses = [
    "REPORT_REVIEW_INPUT": 400, "REPORT_REVIEW_SCOPE": 403, "REPORT_REVIEW_STALE": 409,
    "REPORT_REVIEW_CAPACITY": 429, "REPORT_REVIEW_RESPONSE": 503, "REPORT_REVIEW_UNAVAILABLE": 503,
    "INVALID_REQUEST": 400,
    "HTTPS_REQUIRED": 400, "NOT_FOUND": 404, "METHOD_NOT_ALLOWED": 405, "ORIGIN_NOT_ALLOWED": 403,
    "INVALID_SESSION": 401,
    "ACCOUNT_DISABLED": 403, "DELETION_IN_PROGRESS": 403, "FEATURE_DISABLED": 503, "GATEWAY_DISABLED": 503,
    "RATE_LIMITED": 429,
    "CAPACITY_LIMITED": 503, "LIMIT_UNAVAILABLE": 503, "UNAVAILABLE": 503,
]
