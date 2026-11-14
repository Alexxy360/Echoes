import CryptoKit
import Foundation

/// Deliberately redacts interpolation, debug output and reflection. Never log encoded requests/storage.
public struct GatewaySecret: Codable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    let value: String
    public init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 16_384,
            value.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw GatewayFailure.invalidInput }
        self.value = value
    }
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
    public var description: String { "<redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum GatewayErrorCode: String, Codable, Sendable {
    case invalidIdentity = "INVALID_IDENTITY"
    case invalidChallenge = "INVALID_CHALLENGE"
    case invalidSession = "INVALID_SESSION"
    case reauthenticationRequired = "REAUTH_REQUIRED"
    case accountDisabled = "ACCOUNT_DISABLED"
    case deletionInProgress = "DELETION_IN_PROGRESS"
    case noAccount = "NO_ACCOUNT"
    case sessionLimited = "SESSION_LIMITED"
    case renewalBusy = "RENEWAL_BUSY"
    case rateLimited = "RATE_LIMITED"
    case issueLimited = "ISSUE_LIMITED"
    case unavailable = "UNAVAILABLE"
    case disabled = "GATEWAY_DISABLED"
    case featureDisabled = "FEATURE_DISABLED"
    case other
}

public enum GatewayFailure: Error, Equatable, Sendable, LocalizedError {
    case configuration, invalidInput, invalidResponse, transport, storageUnavailable
    case signInRequired, operationInProgress, superseded, accountMismatch, cancelled
    case server(GatewayErrorCode, status: Int, retryAfterSeconds: Int?)

    public var errorDescription: String? {
        switch self {
        case .configuration: "Połączenie z nową usługą nie jest skonfigurowane."
        case .invalidInput, .invalidResponse: "Nie udało się bezpiecznie przetworzyć logowania."
        case .transport: "Nie udało się potwierdzić wyniku połączenia. Spróbuj zalogować się ponownie."
        case .storageUnavailable: "Odblokuj urządzenie. Nie udało się bezpiecznie zapisać stanu sesji."
        case .signInRequired: "Zaloguj się ponownie przez Apple."
        case .operationInProgress: "Poczekaj na zakończenie bieżącej operacji."
        case .superseded, .accountMismatch: "Konto lub stan logowania zmieniły się. Zaloguj się ponownie."
        case .cancelled: "Logowanie anulowane."
        case .server(.sessionLimited, _, _): "Osiągnięto limit aktywnych sesji. Wyloguj inne urządzenie."
        case .server(.accountDisabled, _, _): "To konto zostało zablokowane."
        case .server(.deletionInProgress, _, _): "Trwa usuwanie konta."
        case .server(.rateLimited, _, _), .server(.issueLimited, _, _):
            "Wykonano zbyt wiele prób. Odczekaj przed kolejną."
        case .server(.invalidSession, _, _), .server(.reauthenticationRequired, _, _):
            "Zaloguj się ponownie przez Apple."
        case .server: "Usługa logowania jest chwilowo niedostępna."
        }
    }
}

public enum GatewayChallengePurpose: String, Codable, Sendable {
    case login
    case accountDeletion = "account_deletion"
}

public struct GatewayChallenge: Decodable, Sendable {
    let protocolVersion: Int
    public let challengeID: String
    let nonce: GatewaySecret
    public let expiresAt: Int

    /// Hash the UTF-8 nonce string; do not decode its base64url representation.
    public var appleNonce: String {
        SHA256.hash(data: Data(nonce.value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func validate(now: Date) throws {
        guard protocolVersion == 1, gatewayUUID(challengeID), nonce.value.utf8.count == 43,
            nonce.value.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
            }),
            Double(expiresAt) > now.timeIntervalSince1970,
            Double(expiresAt) <= now.timeIntervalSince1970 + 330
        else { throw GatewayFailure.invalidResponse }
    }
}

public struct GatewaySessionPair: Codable, Equatable, Sendable {
    let protocolVersion: Int
    public let accountID: String
    public let sessionToken: GatewaySecret
    public let expiresAt: Int
    public let renewalToken: GatewaySecret
    public let renewalExpiresAt: Int

    func validate(now: Date, allowExpiredAccess: Bool = false) throws {
        guard protocolVersion == 1, gatewayUUID(accountID), sessionToken.value.utf8.count <= 512,
            renewalToken.value.utf8.count <= 120, expiresAt > 0, renewalExpiresAt >= expiresAt,
            Double(renewalExpiresAt) > now.timeIntervalSince1970,
            Double(renewalExpiresAt) <= now.timeIntervalSince1970 + 31 * 86_400,
            Double(expiresAt) <= now.timeIntervalSince1970 + 660,
            allowExpiredAccess || Double(expiresAt) > now.timeIntervalSince1970
        else { throw GatewayFailure.invalidResponse }
    }
}

public struct GatewaySessionStatus: Decodable, Sendable {
    let protocolVersion: Int
    public let accountID: String
    public let expiresAt: Int
}

/// Identifiers from native Apple/CloudKit checks, never interchangeable with the server's account UUID.
public struct GatewayIdentityBinding: Codable, Equatable, Sendable {
    public let appleUserID: String
    public let cloudKitAccountHash: String
    public init(appleUserID: String, cloudKitRecordName: String) throws {
        guard !appleUserID.isEmpty, appleUserID.utf8.count <= 512,
            !cloudKitRecordName.isEmpty, cloudKitRecordName != "__defaultOwner__",
            cloudKitRecordName.utf8.count <= 512
        else { throw GatewayFailure.invalidInput }
        self.appleUserID = appleUserID
        cloudKitAccountHash = SHA256.hash(data: Data(cloudKitRecordName.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public protocol GatewayAuthenticationAPI: Sendable {
    var origin: String { get }
    func challenge(purpose: GatewayChallengePurpose) async throws -> GatewayChallenge
    func login(challengeID: String, identityToken: GatewaySecret, authorizationCode: GatewaySecret)
        async throws -> GatewaySessionPair
    func renew(token: GatewaySecret) async throws -> GatewaySessionPair
    func session(token: GatewaySecret) async throws -> GatewaySessionStatus
    func logout(token: GatewaySecret) async throws
    func logoutAll(token: GatewaySecret) async throws
}

func gatewayUUID(_ value: String) -> Bool {
    value.count == 36 && UUID(uuidString: value)?.uuidString.lowercased() == value
}
