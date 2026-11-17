import CryptoKit
import Foundation

public enum GatewayAvatarReviewFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidInput, invalidResponse, unavailable, busy, denied, stale, pending
    case limited(retryAfterSeconds: Int?)
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Nie udało się przygotować żądania moderacji."
        case .invalidResponse, .unavailable:
            "Nie udało się potwierdzić wyniku moderacji. Nie podejmuj nowej decyzji bez sprawdzenia stanu."
        case .busy: "Poczekaj na zakończenie bieżącej operacji moderacji."
        case .denied: "To konto nie ma teraz dostępu do moderacji."
        case .stale: "Podgląd wygasł lub zdjęcie się zmieniło. Otwórz świeży podgląd."
        case .pending: "Wynik decyzji jest niepewny. Ponów wyłącznie tę samą zapisaną decyzję."
        case .limited: "Odczekaj chwilę przed kolejną operacją moderacji."
        }
    }
}

/// A queue selection is metadata, never permission to inspect or decide.
public struct GatewayAvatarReviewItem: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let accountID: String, requestID: String, versionID: String, reviewRevision: String
    public let generation: Int
    public init(
        accountID: String, requestID: String, versionID: String, generation: Int, reviewRevision: String
    ) throws {
        guard [accountID, requestID, versionID, reviewRevision].allSatisfy(gatewayUUID),
            (1..<9_007_199_254_740_991).contains(generation)
        else { throw GatewayAvatarReviewFailure.invalidInput }
        self.accountID = accountID
        self.requestID = requestID
        self.versionID = versionID
        self.generation = generation
        self.reviewRevision = reviewRevision
    }
    public var description: String { "GatewayAvatarReviewItem(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum GatewayAvatarReviewVerdict: String, Equatable, Sendable { case approved, rejected }

/// Returned only with verified bytes. Bound to the exact bearer/origin and an absolute, nonrenewable
/// expiry. It is not a UI-display acknowledgement or a substitute for host/account fencing.
public struct GatewayAvatarReviewReceipt: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let item: GatewayAvatarReviewItem
    public let inspectionID: String
    public let expiresAtMilliseconds: Int
    let origin: String, sessionFingerprint: String
    let observedAtMilliseconds: Int
    let observedUptime: TimeInterval

    func validate(origin: String, token: GatewaySecret, stamp: AvatarReviewStamp) throws {
        guard self.origin == origin, sessionFingerprint == Self.fingerprint(token) else {
            throw GatewayAvatarReviewFailure.invalidInput
        }
        try validateTime(stamp)
    }
    func validateTime(_ stamp: AvatarReviewStamp) throws {
        guard stamp.milliseconds >= observedAtMilliseconds,
            stamp.milliseconds < expiresAtMilliseconds, stamp.uptime >= observedUptime,
            (stamp.uptime - observedUptime) * 1000
                < Double(min(90_000, expiresAtMilliseconds - observedAtMilliseconds))
        else { throw GatewayAvatarReviewFailure.stale }
    }
    static func fingerprint(_ token: GatewaySecret) -> String {
        SHA256.hash(data: Data(token.value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var description: String { "GatewayAvatarReviewReceipt(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Pixels are decoded off the UI actor. A host must still prove the current image was displayed
/// before accepting a conscious decision, and drop it on scene/account/selection invalidation.
public struct GatewayAvatarReviewInspection: Sendable, CustomStringConvertible, CustomReflectable {
    public let receipt: GatewayAvatarReviewReceipt
    public let avatar: ValidatedAvatar
    public var description: String { "GatewayAvatarReviewInspection(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The caller must persist this exact ID/verdict before dispatch. No automatic retry/new ID.
public struct GatewayAvatarReviewDecisionIntent: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let receipt: GatewayAvatarReviewReceipt
    public let decisionID: String
    public let verdict: GatewayAvatarReviewVerdict
    public init(
        receipt: GatewayAvatarReviewReceipt, decisionID: String, verdict: GatewayAvatarReviewVerdict
    ) throws {
        guard gatewayUUID(decisionID) else { throw GatewayAvatarReviewFailure.invalidInput }
        self.receipt = receipt
        self.decisionID = decisionID
        self.verdict = verdict
    }
    public var description: String { "GatewayAvatarReviewDecisionIntent(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct GatewayAvatarReviewDecisionResult: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let intent: GatewayAvatarReviewDecisionIntent
    public let revision: String
    public var description: String { "GatewayAvatarReviewDecisionResult(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum GatewayAvatarReviewOperation: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    case queue
    case inspect(GatewayAvatarReviewItem)
    case decide(GatewayAvatarReviewDecisionIntent)
    case recover(GatewayAvatarReviewRecoveryIntent)
    var action: String {
        switch self {
        case .queue: "queue"
        case .inspect: "inspect"
        case .decide: "decide"
        case .recover: "recover"
        }
    }
    func wire() throws -> Data {
        let fields: [String: Any]
        switch self {
        case .queue: fields = [:]
        case .inspect(let item): fields = ["accountID": item.accountID, "requestID": item.requestID]
        case .decide(let intent):
            fields = [
                "inspectionID": intent.receipt.inspectionID, "decisionID": intent.decisionID,
                "verdict": intent.verdict.rawValue,
            ]
        case .recover(let intent):
            fields = [
                "accountID": intent.item.accountID, "requestID": intent.item.requestID,
                "versionID": intent.item.versionID, "generation": intent.item.generation,
                "reviewRevision": intent.item.reviewRevision, "decisionID": intent.decisionID,
                "verdict": intent.verdict.rawValue,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard data.count <= 512 else { throw GatewayAvatarReviewFailure.invalidInput }
        return data
    }
    public var description: String { "GatewayAvatarReviewOperation(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

struct AvatarReviewStamp: Sendable {
    let milliseconds: Int
    let uptime: TimeInterval
    init(date: Date, uptime: TimeInterval) throws {
        let raw = date.timeIntervalSince1970 * 1000
        guard raw.isFinite, raw >= 0, raw < 9_007_199_254_650_991,
            uptime.isFinite, uptime >= 0
        else { throw GatewayAvatarReviewFailure.stale }
        milliseconds = Int(raw.rounded(.down))
        self.uptime = uptime
    }
}
