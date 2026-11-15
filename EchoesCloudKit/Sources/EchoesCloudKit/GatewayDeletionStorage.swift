import CryptoKit
import Foundation
import Security

/// One journal per origin/container/environment. The app owns one MainActor deletion coordinator;
/// every replacement is synchronous and atomic, separate from the login session's tombstone.
public protocol GatewayDeletionStorage: Sendable {
    func read() throws -> Data?
    func write(_ value: Data) throws
}

public struct KeychainGatewayDeletionStorage: GatewayDeletionStorage {
    private let account: String
    public init(configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration) {
        account = SHA256.hash(
            data: Data(
                ("echoes/deletion-journal/v1\0" + configuration.origin.absoluteString + "\0"
                    + cloudKit.containerIdentifier + "\0" + cloudKit.environment.rawValue).utf8)
        )
        .map { String(format: "%02x", $0) }.joined()
    }
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "mpvEcho.Echo.gateway.deletions.v1",
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
    public func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 65_536 else {
            throw GatewayFailure.storageUnavailable
        }
        return data
    }
    public func write(_ value: Data) throws {
        guard value.count <= 65_536 else { throw GatewayFailure.storageUnavailable }
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GatewayFailure.storageUnavailable }
    }
}

struct StoredGatewayDeletion: Codable {
    enum Phase: String, Codable { case requestPending, recoveryPending, accepted }
    let journalID: String
    let binding: GatewayIdentityBinding
    var attemptID = UUID().uuidString.lowercased()
    var phase: Phase
    var ticket: GatewayDeletionTicket?
    var accountID: String?
    var status: GatewayDeletionStatus?
    var cursor: PrivateCleanupCursor?
    var contentDeleted = false
    var localDataDeleted = false
    var ownAcknowledgement = false
}
struct StoredGatewayDeletionJournal: Codable {
    let version: Int
    let origin: String
    let container: String
    let environment: String
    var requests: [StoredGatewayDeletion]
}

public enum GatewayDeletionFailure: Error, LocalizedError, Equatable {
    case freshProofRequired, journalFull, missingRequest
    public var errorDescription: String? {
        switch self {
        case .freshProofRequired: "Potwierdź ponownie przez Apple odzyskanie usuwania."
        case .journalFull:
            "Zachowano limit lokalnych potwierdzeń usuwania. Nie nadpisano wcześniejszych danych."
        case .missingRequest: "Nie znaleziono lokalnego biletu tego usuwania."
        }
    }
}

public struct GatewayDeletionProgress: Equatable, Sendable {
    public let journalID: String
    public let accountID: String?
    public let status: GatewayDeletionStatus?
    public let needsFreshProof: Bool
    public let canRetryInitialRequest: Bool
    public let privateContentDeleted: Bool
    public let localDataDeleted: Bool
    public let ownAcknowledgement: Bool
    /// A global server ACK or completed receipt never skips this device's own cleanup.
    public var completed: Bool {
        !needsFreshProof && status?.completed == true && privateContentDeleted && localDataDeleted
            && ownAcknowledgement
    }
}

@MainActor public protocol GatewayPrivateAccountCleanup {
    func step(
        scope: PrivateAccountScope, deletionID: String, cursor: PrivateCleanupCursor?,
        authorizeDeletion: @escaping @MainActor (PrivateAccountScope) async throws -> Void
    ) async throws -> PrivateCleanupStep
}
extension NativePrivateProfileDatabase: GatewayPrivateAccountCleanup {
    public func step(
        scope: PrivateAccountScope, deletionID: String, cursor: PrivateCleanupCursor?,
        authorizeDeletion: @escaping @MainActor (PrivateAccountScope) async throws -> Void
    ) async throws -> PrivateCleanupStep {
        try await eraseAccountContentStep(
            scope: scope, deletionID: deletionID, cursor: cursor, authorizeDeletion: authorizeDeletion)
    }
}

struct GatewayDeletionJournalCodec {
    let origin: String
    let configuration: CloudKitConfiguration
    let storage: any GatewayDeletionStorage
    func read() throws -> StoredGatewayDeletionJournal {
        do {
            guard let bytes = try storage.read() else {
                return .init(
                    version: 1, origin: origin, container: configuration.containerIdentifier,
                    environment: configuration.environment.rawValue, requests: [])
            }
            guard bytes.count <= 65_536 else { throw GatewayFailure.storageUnavailable }
            let journal = try JSONDecoder().decode(StoredGatewayDeletionJournal.self, from: bytes)
            try validate(journal)
            return journal
        } catch { throw GatewayFailure.storageUnavailable }
    }
    func write(_ journal: StoredGatewayDeletionJournal) throws {
        do {
            try validate(journal)
            let bytes = try JSONEncoder().encode(journal)
            guard bytes.count <= 65_536 else { throw GatewayFailure.storageUnavailable }
            try storage.write(bytes)
        } catch let error as GatewayDeletionFailure { throw error } catch {
            throw GatewayFailure.storageUnavailable
        }
    }
    func validate(_ journal: StoredGatewayDeletionJournal) throws {
        guard journal.version == 1, journal.origin == origin,
            journal.container == configuration.containerIdentifier,
            journal.environment == configuration.environment.rawValue, journal.requests.count <= 8,
            Set(journal.requests.map(\.journalID)).count == journal.requests.count
        else { throw GatewayFailure.storageUnavailable }
        for entry in journal.requests {
            guard gatewayUUID(entry.journalID), gatewayUUID(entry.attemptID),
                !entry.binding.appleUserID.isEmpty,
                entry.binding.appleUserID.utf8.count <= 512,
                entry.binding.cloudKitAccountHash.count == 64,
                entry.binding.cloudKitAccountHash.utf8.allSatisfy({
                    (48...57).contains($0) || (97...102).contains($0)
                }),
                entry.accountID == nil || gatewayUUID(entry.accountID!),
                entry.phase != .requestPending || (entry.ticket != nil && entry.status == nil),
                entry.phase != .accepted
                    || (entry.ticket != nil && entry.status != nil && entry.accountID != nil),
                entry.status == nil || (entry.ticket != nil && entry.accountID != nil),
                !entry.contentDeleted || (entry.status != nil && entry.cursor == nil),
                !entry.localDataDeleted || entry.contentDeleted,
                !entry.ownAcknowledgement
                    || (entry.localDataDeleted && entry.status?.privateData == .deviceAcknowledged)
            else { throw GatewayFailure.storageUnavailable }
            if let status = entry.status {
                try status.validate(deletionID: entry.ticket?.deletionID, accountID: entry.accountID)
            }
            if let cursor = entry.cursor {
                guard entry.status != nil, cursor.deletionID == entry.ticket?.deletionID,
                    cursor.scopeDigest.count == 64,
                    cursor.scopeDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                    !cursor.token.isEmpty, cursor.token.count <= 16_384
                else { throw GatewayFailure.storageUnavailable }
            }
        }
    }
}

extension GatewayDeletionController {
    /// Protected local hints only. The native host still checks iCloud, and each operation needs
    /// the original server ticket or fresh Apple proof. Never display/log the raw Apple user ID.
    public static func resumeBindings(
        configuration: CloudKitConfiguration, origin: String,
        storage: any GatewayDeletionStorage, cloudKitRecordName: String
    ) throws -> [GatewayIdentityBinding] {
        let hash = try GatewayIdentityBinding(
            appleUserID: "local-resume-hint", cloudKitRecordName: cloudKitRecordName
        ).cloudKitAccountHash
        let journal = try GatewayDeletionJournalCodec(
            origin: origin, configuration: configuration, storage: storage
        ).read()
        return journal.requests.filter { $0.binding.cloudKitAccountHash == hash }.reduce(into: []) {
            result, entry in
            if !result.contains(entry.binding) { result.append(entry.binding) }
        }
    }
}
