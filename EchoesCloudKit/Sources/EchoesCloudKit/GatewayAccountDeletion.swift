import Foundation
import Security

/// A narrow status/private-ACK capability, never a login token. Persist in its own Keychain item
/// before the first deletion request. Do not log encoded payloads or attach them to diagnostics.
public struct GatewayDeletionTicket: Codable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let deletionID: String
    public let statusToken: GatewaySecret
    public init(deletionID: String, statusToken: GatewaySecret) throws {
        let value = statusToken.value
        guard gatewayUUID(deletionID), value.utf8.count == 80,
            value.hasPrefix(deletionID + ".")
        else { throw GatewayFailure.invalidInput }
        let encoded = String(value.dropFirst(37))
        let base64 =
            encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard
            encoded.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                    || $0 == 95
            }), let bytes = Data(base64Encoded: base64), bytes.count == 32,
            bytes.base64EncodedString() == base64
        else { throw GatewayFailure.invalidInput }
        self.deletionID = deletionID
        self.statusToken = statusToken
    }
    public static func create() throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw GatewayFailure.storageUnavailable
        }
        let encoded = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let id = UUID().uuidString.lowercased()
        return try .init(deletionID: id, statusToken: .init(id + "." + encoded))
    }
    private enum CodingKeys: String, CodingKey { case deletionID, statusToken }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            deletionID: container.decode(String.self, forKey: .deletionID),
            statusToken: container.decode(GatewaySecret.self, forKey: .statusToken))
    }
    public var description: String { "<deletion-ticket>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Construct only from a fresh purpose-bound native Apple flow. expectedAccountID checks an owned
/// account; it never chooses the subject/job. Native identity binding is the caller's responsibility.
public struct GatewayDeletionProof: Sendable {
    public let challengeID: String
    public let identityToken: GatewaySecret
    public let expectedAccountID: String?
    public init(challengeID: String, identityToken: GatewaySecret, expectedAccountID: String?) throws {
        guard gatewayUUID(challengeID), identityToken.value.utf8.count <= 12_288,
            expectedAccountID == nil || gatewayUUID(expectedAccountID!)
        else { throw GatewayFailure.invalidInput }
        self.challengeID = challengeID
        self.identityToken = identityToken
        self.expectedAccountID = expectedAccountID
    }
    var fields: [String: String] {
        var result = ["challengeID": challengeID, "identityToken": identityToken.value]
        if let expectedAccountID { result["expectedAccountID"] = expectedAccountID }
        return result
    }
}

public struct GatewayDeletionStatus: Codable, Equatable, Sendable {
    public enum PublicData: String, Codable, Sendable { case pending, draining, deleted }
    public enum PrivateData: String, Codable, Sendable {
        case awaitingDevice = "awaiting-device"
        case deviceAcknowledged = "device-acknowledged"
    }
    public enum AppleAuthorization: String, Codable, Sendable {
        case pending
        case retainedTokensProcessed = "retained-tokens-processed"
        case manualRequired = "manual-required"
    }
    public enum LocalAccount: String, Codable, Sendable { case blocked, removed }
    let protocolVersion: Int
    public let deletionID: String
    public let accountID: String
    public let publicData: PublicData
    /// A device claim, not provider verification or confirmation that this device was cleaned.
    public let privateData: PrivateData
    public let appleAuthorization: AppleAuthorization
    public let localAccount: LocalAccount
    public let attentionRequired: Bool
    public let completed: Bool
    func validate(deletionID expectedDeletionID: String? = nil, accountID expectedAccountID: String? = nil)
        throws
    {
        guard protocolVersion == 1, gatewayUUID(deletionID), gatewayUUID(accountID),
            expectedDeletionID == nil || deletionID == expectedDeletionID,
            expectedAccountID == nil || accountID == expectedAccountID,
            completed == (localAccount == .removed),
            !completed
                || (publicData == .deleted && privateData == .deviceAcknowledged
                    && appleAuthorization != .pending),
            !attentionRequired || publicData != .deleted
        else { throw GatewayFailure.invalidResponse }
    }
}

public struct GatewayRecoveredDeletion: Sendable {
    public let ticket: GatewayDeletionTicket
    public let status: GatewayDeletionStatus
}

/// Separate from access/renewal APIs so erasure can continue after ban, session loss or Apple revoke.
/// This API alone does not authorize or perform native iCloud deletion or acknowledge local cleanup.
public protocol GatewayAccountDeletionAPI: Sendable {
    var origin: String { get }
    func deletionChallenge(recovering: Bool) async throws -> GatewayChallenge
    func requestDeletion(ticket: GatewayDeletionTicket, proof: GatewayDeletionProof?) async throws
        -> GatewayDeletionStatus
    func recoverDeletion(proof: GatewayDeletionProof) async throws -> GatewayRecoveredDeletion
    func deletionStatus(ticket: GatewayDeletionTicket) async throws -> GatewayDeletionStatus
    func acknowledgePrivateCleanup(ticket: GatewayDeletionTicket) async throws -> GatewayDeletionStatus
}
