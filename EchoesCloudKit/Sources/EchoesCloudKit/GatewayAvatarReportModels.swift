import CryptoKit
import EchoesCore
import Foundation

public enum GatewayAvatarReportFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidInput, invalidResponse, unavailable, busy, denied, notFound, conflict
    case limited(retryAfterSeconds: Int?)
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Nie udało się przygotować zgłoszenia zdjęcia."
        case .busy: "Poczekaj na zakończenie bieżącej operacji zgłoszenia."
        case .limited: "Odczekaj chwilę przed sprawdzeniem wyniku zgłoszenia."
        case .denied: "To konto nie ma teraz dostępu do zgłoszenia."
        case .notFound: "Zdjęcie nie jest teraz dostępne. Sprawdź wynik zapisanego zgłoszenia."
        case .conflict: "Zgłoszenie lub zdjęcie się zmieniło. Sprawdź wynik zapisanej próby."
        case .invalidResponse, .unavailable:
            "Nie udało się potwierdzić wyniku. Sprawdź zapisane zgłoszenie przed kolejną próbą."
        }
    }
}

/// Metadata for one immutable attempt. The host must obtain accountID from its current session.
/// This contains no reason, location, image, target or provider URL and can be used for recovery.
public struct GatewayAvatarReportIdentity: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let accountID: String, requestID: String, reportID: String
    public init(accountID: String, requestID: String) throws {
        guard gatewayUUID(accountID), gatewayUUID(requestID) else {
            throw GatewayAvatarReportFailure.invalidInput
        }
        self.accountID = accountID
        self.requestID = requestID
        let digest: (String) -> String = {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let owner = digest("echoes/public-owner/v1\0" + accountID)
        let logical = digest("echoes/public-logical/v1\0" + requestID)
        reportID =
            "community-v1-avatarreport-"
            + digest("echoes/public-record/v1\0" + owner + "\0avatarreport\0" + logical)
    }
    public var description: String { "GatewayAvatarReportIdentity(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Validated submission data, not proof of display/consent. A foreground host must bind the
/// exact rendered version and persist dispatch metadata before calling the mutation API.
public struct GatewayAvatarReportSubmission: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let identity: GatewayAvatarReportIdentity
    public let reference: AvatarReference
    public let reason: String
    public let coordinate: Coordinate
    public init(
        identity: GatewayAvatarReportIdentity, reference: AvatarReference, reason: String,
        coordinate: Coordinate
    ) throws {
        guard identity.accountID != reference.ownerID, coordinate.isValid, reason.utf8.count <= 4096 else {
            throw GatewayAvatarReportFailure.invalidInput
        }
        let normalized = try Self.normalizeReason(reason)
        self.identity = identity
        self.reference = reference
        self.reason = normalized
        self.coordinate = coordinate
        _ = try GatewayAvatarReportOperation.submit(self).wire()
    }
    public static func normalizeReason(_ reason: String) throws -> String {
        guard reason.utf8.count <= 4096 else { throw GatewayAvatarReportFailure.invalidInput }
        let white = CharacterSet(
            charactersIn:
                "\u{0009}\u{000a}\u{000b}\u{000c}\u{000d}\u{0020}\u{00a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}"
        )
        let normalized = reason.precomposedStringWithCanonicalMapping.trimmingCharacters(in: white)
        guard reportReviewText(normalized, maximum: 500) else {
            throw GatewayAvatarReportFailure.invalidInput
        }
        return normalized
    }
    public var description: String { "GatewayAvatarReportSubmission(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum GatewayAvatarReportOutcome: String, Equatable, Sendable { case accepted, unconfirmed, cancelled }
public struct GatewayAvatarReportResult: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let identity: GatewayAvatarReportIdentity
    public let outcome: GatewayAvatarReportOutcome
    public var description: String { "GatewayAvatarReportResult(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayAvatarReportOperation: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    case submit(GatewayAvatarReportSubmission)
    case recover(GatewayAvatarReportIdentity)
    case cancel(GatewayAvatarReportIdentity)
    var identity: GatewayAvatarReportIdentity {
        switch self {
        case .submit(let value): value.identity
        case .recover(let value), .cancel(let value): value
        }
    }
    var path: String {
        switch self {
        case .submit: "/v1/community/avatar/report"
        case .recover: "/v1/community/avatar/report/recover"
        case .cancel: "/v1/community/avatar/report/cancel"
        }
    }
    var maximumResponseBytes: Int { 2048 }
    func wire() throws -> Data {
        let fields: [String: Any]
        switch self {
        case .submit(let value):
            fields = [
                "requestID": value.identity.requestID, "ownerID": value.reference.ownerID,
                "versionID": value.reference.versionID, "reason": value.reason,
                "coordinate": [
                    "latitude": value.coordinate.latitude, "longitude": value.coordinate.longitude,
                ],
            ]
        case .recover(let value), .cancel(let value): fields = ["requestID": value.requestID]
        }
        let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard body.count <= 4096 else { throw GatewayAvatarReportFailure.invalidInput }
        return body
    }
    public var description: String { "GatewayAvatarReportOperation(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReportHTTPResponse: Sendable, CustomStringConvertible, CustomReflectable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
    public var description: String { "GatewayAvatarReportHTTPResponse(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
