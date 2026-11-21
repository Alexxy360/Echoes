import CryptoKit
import Foundation

public enum GatewayAvatarReportReviewFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidInput, invalidResponse, unavailable, busy, denied, stale
    case limited(retryAfterSeconds: Int?)
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Nie udało się przygotować żądania moderacji zgłoszenia."
        case .invalidResponse, .unavailable:
            "Nie udało się potwierdzić wyniku. Sprawdź zapisaną decyzję przed podjęciem kolejnej."
        case .busy: "Poczekaj na zakończenie bieżącej operacji moderacji."
        case .denied: "To konto nie ma teraz dostępu do zgłoszonych zdjęć."
        case .stale: "Inspekcja wygasła lub materiał się zmienił. Otwórz go ponownie."
        case .limited: "Odczekaj chwilę przed kolejną operacją moderacji."
        }
    }
}

func avatarReportReviewID(_ value: String) -> Bool {
    value.hasPrefix("community-v1-avatarreport-") && value.utf8.count == 90
        && value.dropFirst(26).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
public struct GatewayAvatarReportReviewCursor: Equatable, Sendable, CustomStringConvertible, CustomReflectable
{
    public let value: String
    public init(_ value: String) throws {
        guard avatarReportReviewID(value) else { throw GatewayAvatarReportReviewFailure.invalidInput }
        self.value = value
    }
    public var description: String { "GatewayAvatarReportReviewCursor(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReportReviewItem: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let reportID: String
    public let createdAtMilliseconds: Int, expiresAtMilliseconds: Int
    public init(reportID: String, createdAtMilliseconds: Int, expiresAtMilliseconds: Int) throws {
        guard avatarReportReviewID(reportID), (0...9_007_199_254_740_991).contains(createdAtMilliseconds),
            (0...9_007_199_254_740_991).contains(expiresAtMilliseconds),
            expiresAtMilliseconds >= createdAtMilliseconds,
            expiresAtMilliseconds - createdAtMilliseconds == 2_592_000_000
        else { throw GatewayAvatarReportReviewFailure.invalidInput }
        self.reportID = reportID
        self.createdAtMilliseconds = createdAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }
    public var description: String { "GatewayAvatarReportReviewItem(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReportReviewPage: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let items: [GatewayAvatarReportReviewItem]
    public let next: GatewayAvatarReportReviewCursor?
    public var description: String { "GatewayAvatarReportReviewPage(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
/// Validated target retained locally for a future presentation fence. Never sent in recovery JSON.
public struct GatewayAvatarReportReviewPhotoTarget: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let ownerID: String, versionID: String
    public let publicationGeneration: Int
    public init(ownerID: String, versionID: String, publicationGeneration: Int) throws {
        guard gatewayUUID(ownerID), gatewayUUID(versionID),
            (1..<9_007_199_254_740_991).contains(publicationGeneration)
        else { throw GatewayAvatarReportReviewFailure.invalidInput }
        self.ownerID = ownerID
        self.versionID = versionID
        self.publicationGeneration = publicationGeneration
    }
    public var description: String { "GatewayAvatarReportReviewPhotoTarget(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Server inspection receipt, not proof of human viewing. The host must fence account/foreground scope.
public struct GatewayAvatarReportReviewReceipt: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let item: GatewayAvatarReportReviewItem
    public let inspectionID: String, contentHash: String
    public let expiresAtMilliseconds: Int
    let origin: String, sessionFingerprint: String
    let observed: AvatarReportReviewStamp
    public let photoTarget: GatewayAvatarReportReviewPhotoTarget?
    static func fingerprint(_ token: GatewaySecret) -> String {
        SHA256.hash(data: Data(token.value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func validate(origin: String, token: GatewaySecret, stamp: AvatarReportReviewStamp) throws {
        guard self.origin == origin, sessionFingerprint == Self.fingerprint(token) else {
            throw GatewayAvatarReportReviewFailure.invalidInput
        }
        try validateTime(stamp)
    }
    func validateTime(_ stamp: AvatarReportReviewStamp) throws {
        guard expiresAtMilliseconds > observed.milliseconds,
            expiresAtMilliseconds - observed.milliseconds <= 90_000,
            stamp.milliseconds >= observed.milliseconds, stamp.uptime >= observed.uptime,
            stamp.milliseconds < expiresAtMilliseconds,
            (stamp.uptime - observed.uptime) * 1000 < Double(expiresAtMilliseconds - observed.milliseconds)
        else { throw GatewayAvatarReportReviewFailure.stale }
    }
    public var description: String { "GatewayAvatarReportReviewReceipt(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReportReviewInspection: Sendable, CustomStringConvertible, CustomReflectable {
    public let receipt: GatewayAvatarReportReviewReceipt
    public let reason: String
    public let avatar: ValidatedAvatar?
    public var description: String { "GatewayAvatarReportReviewInspection(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayAvatarReportReviewVerdict: String, Sendable, Equatable {
    case dismiss
    case hidePhoto = "hide_photo"
}

/// Persist this exact decision in the account-scoped journal before dispatch; never renew its ID on timeout.
public struct GatewayAvatarReportReviewDecisionIntent: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let receipt: GatewayAvatarReportReviewReceipt
    public let decisionID: String
    public let verdict: GatewayAvatarReportReviewVerdict
    public init(
        receipt: GatewayAvatarReportReviewReceipt, decisionID: String,
        verdict: GatewayAvatarReportReviewVerdict
    )
        throws
    {
        guard gatewayUUID(decisionID), verdict != .hidePhoto || receipt.photoTarget != nil else {
            throw GatewayAvatarReportReviewFailure.invalidInput
        }
        self.receipt = receipt
        self.decisionID = decisionID
        self.verdict = verdict
    }
    public var description: String { "GatewayAvatarReportReviewDecisionIntent(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReportReviewDecisionResult: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let intent: GatewayAvatarReportReviewDecisionIntent
    public let revision: String
    public var description: String { "GatewayAvatarReportReviewDecisionResult(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
/// Metadata-only outcome query. Works after receipt/session expiry; it cannot authorize a mutation.
public struct GatewayAvatarReportReviewRecoveryIntent: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let reportID: String, decisionID: String, contentHash: String
    public let verdict: GatewayAvatarReportReviewVerdict
    public init(
        reportID: String, decisionID: String, verdict: GatewayAvatarReportReviewVerdict, contentHash: String
    ) throws {
        guard avatarReportReviewID(reportID), gatewayUUID(decisionID), reportReviewHash(contentHash) else {
            throw GatewayAvatarReportReviewFailure.invalidInput
        }
        self.reportID = reportID
        self.decisionID = decisionID
        self.verdict = verdict
        self.contentHash = contentHash
    }
    public init(decision: GatewayAvatarReportReviewDecisionIntent) {
        reportID = decision.receipt.item.reportID
        decisionID = decision.decisionID
        verdict = decision.verdict
        contentHash = decision.receipt.contentHash
    }
    public var description: String { "GatewayAvatarReportReviewRecoveryIntent(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayAvatarReportReviewOutcome: Equatable, Sendable, CustomStringConvertible, CustomReflectable
{
    case confirmed(revision: String)
    case notApplied, superseded, retired
    public var isTerminal: Bool {
        switch self {
        case .notApplied: false
        case .confirmed, .superseded, .retired: true
        }
    }
    public var description: String { "GatewayAvatarReportReviewOutcome(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReportReviewRecoveryResult: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let intent: GatewayAvatarReportReviewRecoveryIntent
    public let outcome: GatewayAvatarReportReviewOutcome
    public var description: String { "GatewayAvatarReportReviewRecoveryResult(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayAvatarReportReviewOperation: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    case queue(after: GatewayAvatarReportReviewCursor?)
    case inspect(GatewayAvatarReportReviewItem)
    case decide(GatewayAvatarReportReviewDecisionIntent)
    case recover(GatewayAvatarReportReviewRecoveryIntent)
    case retire(GatewayAvatarReportReviewRecoveryIntent)
    var action: String {
        switch self {
        case .queue: "queue"
        case .inspect: "inspect"
        case .decide: "decide"
        case .recover: "recover"
        case .retire: "retire"
        }
    }
    var acceptType: String { action == "inspect" ? avatarReportReviewInspectionType : "application/json" }
    var maximumResponseBytes: Int {
        switch self {
        case .queue: 8192
        case .inspect: 268292
        case .decide, .recover, .retire: 2048
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
        case .recover(let intent), .retire(let intent):
            fields = [
                "reportID": intent.reportID, "decisionID": intent.decisionID,
                "verdict": intent.verdict.rawValue, "contentHash": intent.contentHash,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard data.count <= 512 else { throw GatewayAvatarReportReviewFailure.invalidInput }
        return data
    }
    public var description: String { "GatewayAvatarReportReviewOperation(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReportReviewHTTPResponse: Sendable, CustomStringConvertible, CustomReflectable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
    public var description: String { "GatewayAvatarReportReviewHTTPResponse(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
struct AvatarReportReviewStamp: Equatable, Sendable {
    let milliseconds: Int
    let uptime: TimeInterval
    init(date: Date, uptime: TimeInterval) throws {
        let raw = date.timeIntervalSince1970 * 1000
        guard raw.isFinite, raw >= 0, raw < 9_007_199_254_650_991, uptime.isFinite, uptime >= 0 else {
            throw GatewayAvatarReportReviewFailure.stale
        }
        milliseconds = Int(raw.rounded(.down))
        self.uptime = uptime
    }
}
