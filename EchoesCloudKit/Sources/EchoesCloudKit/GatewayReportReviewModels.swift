import CryptoKit
import Foundation

public enum GatewayReportReviewFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidInput, invalidResponse, unavailable, busy, denied, stale
    case limited(retryAfterSeconds: Int?)
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Nie udało się przygotować żądania moderacji zgłoszenia."
        case .invalidResponse, .unavailable:
            "Nie udało się potwierdzić wyniku. Sprawdź zapisaną decyzję przed podjęciem kolejnej."
        case .busy: "Poczekaj na zakończenie bieżącej operacji moderacji."
        case .denied: "To konto nie ma teraz dostępu do zgłoszeń."
        case .stale: "Inspekcja wygasła lub materiał się zmienił. Otwórz go ponownie."
        case .limited: "Odczekaj chwilę przed kolejną operacją moderacji."
        }
    }
}

func reportReviewID(_ value: String) -> Bool {
    value.hasPrefix("community-v1-report-") && value.utf8.count == 84
        && value.dropFirst(20).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
func reportReviewMessageID(_ value: String) -> Bool {
    value.hasPrefix("community-v1-message-") && value.utf8.count == 85
        && value.dropFirst(21).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
func reportReviewHash(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

public struct GatewayReportReviewCursor: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let value: String
    public init(_ value: String) throws {
        guard reportReviewID(value) else { throw GatewayReportReviewFailure.invalidInput }
        self.value = value
    }
    public var description: String { "GatewayReportReviewCursor(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayReportReviewItem: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let reportID: String
    public let createdAtMilliseconds: Int, expiresAtMilliseconds: Int
    public init(reportID: String, createdAtMilliseconds: Int, expiresAtMilliseconds: Int) throws {
        guard reportReviewID(reportID), (0...9_007_199_254_740_991).contains(createdAtMilliseconds),
            (0...9_007_199_254_740_991).contains(expiresAtMilliseconds),
            expiresAtMilliseconds >= createdAtMilliseconds,
            expiresAtMilliseconds - createdAtMilliseconds == 2_592_000_000
        else { throw GatewayReportReviewFailure.invalidInput }
        self.reportID = reportID
        self.createdAtMilliseconds = createdAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }
    public var description: String { "GatewayReportReviewItem(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayReportReviewPage: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let items: [GatewayReportReviewItem]
    public let next: GatewayReportReviewCursor?
    public var description: String { "GatewayReportReviewPage(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayReportReviewMessage: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let authorID: String, name: String, text: String
    public let createdAtMilliseconds: Int, expiresAtMilliseconds: Int
    public var description: String { "GatewayReportReviewMessage(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Server inspection receipt, not proof of human viewing. The host must fence account/foreground scope.
public struct GatewayReportReviewReceipt: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let item: GatewayReportReviewItem
    public let inspectionID: String, contentHash: String
    public let expiresAtMilliseconds: Int
    let origin: String, sessionFingerprint: String
    let observed: ReportReviewStamp
    let messageAvailable: Bool
    static func fingerprint(_ token: GatewaySecret) -> String {
        SHA256.hash(data: Data(token.value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func validate(origin: String, token: GatewaySecret, stamp: ReportReviewStamp) throws {
        guard self.origin == origin, sessionFingerprint == Self.fingerprint(token) else {
            throw GatewayReportReviewFailure.invalidInput
        }
        try validateTime(stamp)
    }
    func validateTime(_ stamp: ReportReviewStamp) throws {
        guard expiresAtMilliseconds > observed.milliseconds,
            expiresAtMilliseconds - observed.milliseconds <= 90_000,
            stamp.milliseconds >= observed.milliseconds, stamp.uptime >= observed.uptime,
            stamp.milliseconds < expiresAtMilliseconds,
            (stamp.uptime - observed.uptime) * 1000 < Double(expiresAtMilliseconds - observed.milliseconds)
        else { throw GatewayReportReviewFailure.stale }
    }
    public var description: String { "GatewayReportReviewReceipt(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayReportReviewInspection: Sendable, CustomStringConvertible, CustomReflectable {
    public let receipt: GatewayReportReviewReceipt
    public let reason: String, messageID: String
    public let message: GatewayReportReviewMessage?
    public var description: String { "GatewayReportReviewInspection(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayReportReviewVerdict: String, Sendable, Equatable {
    case dismiss
    case hideMessage = "hide_message"
}

/// Persist this exact decision in the account-scoped journal before dispatch; never renew its ID on timeout.
public struct GatewayReportReviewDecisionIntent: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let receipt: GatewayReportReviewReceipt
    public let decisionID: String
    public let verdict: GatewayReportReviewVerdict
    public init(receipt: GatewayReportReviewReceipt, decisionID: String, verdict: GatewayReportReviewVerdict)
        throws
    {
        guard gatewayUUID(decisionID), verdict != .hideMessage || receipt.messageAvailable else {
            throw GatewayReportReviewFailure.invalidInput
        }
        self.receipt = receipt
        self.decisionID = decisionID
        self.verdict = verdict
    }
    public var description: String { "GatewayReportReviewDecisionIntent(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayReportReviewDecisionResult: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let intent: GatewayReportReviewDecisionIntent
    public let revision: String
    public var description: String { "GatewayReportReviewDecisionResult(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
/// Metadata-only outcome query. Works after receipt/session expiry; it cannot authorize a mutation.
public struct GatewayReportReviewRecoveryIntent: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let reportID: String, decisionID: String, contentHash: String
    public let verdict: GatewayReportReviewVerdict
    public init(
        reportID: String, decisionID: String, verdict: GatewayReportReviewVerdict, contentHash: String
    ) throws {
        guard reportReviewID(reportID), gatewayUUID(decisionID), reportReviewHash(contentHash) else {
            throw GatewayReportReviewFailure.invalidInput
        }
        self.reportID = reportID
        self.decisionID = decisionID
        self.verdict = verdict
        self.contentHash = contentHash
    }
    public init(decision: GatewayReportReviewDecisionIntent) {
        reportID = decision.receipt.item.reportID
        decisionID = decision.decisionID
        verdict = decision.verdict
        contentHash = decision.receipt.contentHash
    }
    public var description: String { "GatewayReportReviewRecoveryIntent(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayReportReviewOutcome: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    case confirmed(revision: String)
    case notApplied, superseded
    public var description: String { "GatewayReportReviewOutcome(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayReportReviewRecoveryResult: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let intent: GatewayReportReviewRecoveryIntent
    public let outcome: GatewayReportReviewOutcome
    public var description: String { "GatewayReportReviewRecoveryResult(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayReportReviewOperation: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    case queue(after: GatewayReportReviewCursor?)
    case inspect(GatewayReportReviewItem)
    case decide(GatewayReportReviewDecisionIntent)
    case recover(GatewayReportReviewRecoveryIntent)
    var action: String {
        switch self {
        case .queue: "queue"
        case .inspect: "inspect"
        case .decide: "decide"
        case .recover: "recover"
        }
    }
    var maximumResponseBytes: Int {
        switch self {
        case .queue: 8192
        case .inspect: 12288
        case .decide, .recover: 2048
        }
    }
    func wire() throws -> Data {
        let fields: [String: Any]
        switch self {
        case .queue(let cursor): fields = ["after": cursor?.value as Any? ?? NSNull()]
        case .inspect(let item): fields = ["reportID": item.reportID]
        case .decide(let intent):
            fields = [
                "inspectionID": intent.receipt.inspectionID, "decisionID": intent.decisionID,
                "verdict": intent.verdict.rawValue,
            ]
        case .recover(let intent):
            fields = [
                "reportID": intent.reportID, "decisionID": intent.decisionID,
                "verdict": intent.verdict.rawValue, "contentHash": intent.contentHash,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard data.count <= 512 else { throw GatewayReportReviewFailure.invalidInput }
        return data
    }
    public var description: String { "GatewayReportReviewOperation(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayReportReviewHTTPResponse: Sendable, CustomStringConvertible, CustomReflectable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
    public var description: String { "GatewayReportReviewHTTPResponse(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
struct ReportReviewStamp: Equatable, Sendable {
    let milliseconds: Int
    let uptime: TimeInterval
    init(date: Date, uptime: TimeInterval) throws {
        let raw = date.timeIntervalSince1970 * 1000
        guard raw.isFinite, raw >= 0, raw < 9_007_199_254_650_991, uptime.isFinite, uptime >= 0 else {
            throw GatewayReportReviewFailure.stale
        }
        milliseconds = Int(raw.rounded(.down))
        self.uptime = uptime
    }
}
