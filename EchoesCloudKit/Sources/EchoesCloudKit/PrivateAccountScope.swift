import CloudKit
import CryptoKit
import Foundation

/// Construct from a verified gateway account and the current native iCloud identity, never IDFV.
public struct PrivateAccountScope: Equatable, Sendable {
    public let configuration: CloudKitConfiguration
    public let accountID: String
    public let cloudKitAccountHash: String
    public let digest: String
    public init(configuration: CloudKitConfiguration, accountID: String, cloudKitRecordName: String) throws {
        guard gatewayUUID(accountID), !cloudKitRecordName.isEmpty,
            cloudKitRecordName != CKCurrentUserDefaultName, cloudKitRecordName.utf8.count <= 512
        else { throw GatewayFailure.invalidInput }
        self.configuration = configuration
        self.accountID = accountID
        cloudKitAccountHash = Self.hash(cloudKitRecordName)
        digest = Self.hash(
            "echoes/private-scope/v1\0" + configuration.containerIdentifier + "\0"
                + configuration.environment.rawValue + "\0" + cloudKitAccountHash + "\0" + accountID)
    }
    public var zoneID: CKRecordZone.ID {
        .init(zoneName: "echoes.private.v1." + digest, ownerName: CKCurrentUserDefaultName)
    }
    public var profileID: CKRecord.ID { .init(recordName: "profile.v1", zoneID: zoneID) }
    var guardID: CKRecord.ID { .init(recordName: "scope-guard.v1", zoneID: zoneID) }
    func matchesCloudKitRecordName(_ name: String) -> Bool {
        !name.isEmpty && Self.hash(name) == cloudKitAccountHash
    }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum PrivateDataFailure: Error, LocalizedError, Equatable {
    case accountDeleted, invalidScope, atomicZoneRequired, malformedGuard, legacyDataRequiresMigration,
        invalidCursor
    public var errorDescription: String? {
        switch self {
        case .accountDeleted: "Rozpoczęto usuwanie tego konta. Zapis prywatnych danych jest zablokowany."
        case .invalidScope: "Konto iCloud lub konto Echoes zmieniło się. Sprawdź logowanie ponownie."
        case .atomicZoneRequired: "Prywatna baza nie obsługuje wymaganego bezpiecznego zapisu."
        case .malformedGuard: "Nie udało się potwierdzić stanu prywatnych danych."
        case .legacyDataRequiresMigration:
            "Wykryto starsze prywatne dane. Wymagają przeniesienia przed zakończeniem usuwania."
        case .invalidCursor: "Nie udało się wznowić prywatnego czyszczenia. Rozpocznij ponowne sprawdzanie."
        }
    }
}

public struct PrivateCleanupCursor: Equatable, Sendable, Codable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    let scopeDigest: String
    let deletionID: String
    let token: Data
    init(scope: PrivateAccountScope, deletionID: String, opaqueToken: Data) throws {
        guard gatewayUUID(deletionID), !opaqueToken.isEmpty, opaqueToken.count <= 16_384 else {
            throw PrivateDataFailure.invalidCursor
        }
        scopeDigest = scope.digest
        self.deletionID = deletionID
        token = opaqueToken
    }
    public var description: String { "<private-cleanup-cursor>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct PrivateCleanupStep: Sendable {
    public let scope: PrivateAccountScope
    public let cursor: PrivateCleanupCursor?
    public let contentDeleted: Bool
    public let deletedRecords: Int
}
