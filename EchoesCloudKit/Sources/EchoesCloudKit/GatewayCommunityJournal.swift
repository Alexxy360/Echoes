import CryptoKit
import Foundation
import Security

/// A native authorization snapshot, never a credential accepted from JSON or a link.
public struct GatewayCommunityAuthorization: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let identity: GatewayAuthenticatedIdentity
    let revision: UUID
    public init(accountID: String, binding: GatewayIdentityBinding, revision: UUID) throws {
        guard gatewayUUID(accountID) else { throw GatewayFailure.invalidInput }
        identity = .init(accountID: accountID, binding: binding)
        self.revision = revision
    }
    public var description: String { "<community-authorization>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
@MainActor public protocol GatewayCommunityAuthorizationSource: AnyObject {
    var communityAuthorization: GatewayCommunityAuthorization? { get }
    func communityAccessToken(for authorization: GatewayCommunityAuthorization) async throws -> GatewaySecret
    func rejectCommunityAccess(for authorization: GatewayCommunityAuthorization) async
}
public struct GatewayCommunityScope: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let digest: String
    public let accountID: String
    public init(
        configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration, accountID: String,
        binding: GatewayIdentityBinding
    ) throws {
        guard cloudKit.containerIdentifier == "iCloud.mpvEcho.Echo", cloudKit.environment == .development,
            gatewayUUID(accountID), !binding.appleUserID.isEmpty, binding.appleUserID.utf8.count <= 512,
            binding.cloudKitAccountHash.utf8.count == 64,
            binding.cloudKitAccountHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw GatewayFailure.invalidInput }
        self.accountID = accountID
        digest = communityDigest(
            "echoes/community-scope/v1\0" + configuration.origin.absoluteString + "\0"
                + cloudKit.containerIdentifier + "\0" + cloudKit.environment.rawValue + "\0" + accountID
                + "\0" + communityDigest(binding.appleUserID) + "\0" + binding.cloudKitAccountHash)
    }
    public var description: String { "<community-scope>" }
    public init(
        configuration: GatewayConfiguration, privateScope: PrivateAccountScope,
        binding: GatewayIdentityBinding
    ) throws {
        guard privateScope.cloudKitAccountHash == binding.cloudKitAccountHash else {
            throw GatewayFailure.accountMismatch
        }
        try self.init(
            configuration: configuration, cloudKit: privateScope.configuration,
            accountID: privateScope.accountID, binding: binding)
    }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// MainActor serialization covers the synchronous read/check/replace boundary. No await during IO.
@MainActor public protocol GatewayCommunityJournalStorage {
    func read(scope: GatewayCommunityScope) throws -> Data?
    func write(_ data: Data, scope: GatewayCommunityScope) throws
    func remove(scope: GatewayCommunityScope) throws
}
@MainActor public struct KeychainGatewayCommunityJournalStorage: GatewayCommunityJournalStorage {
    public init() {}
    private func query(_ scope: GatewayCommunityScope) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "mpvEcho.Echo.gateway.community.v1",
            kSecAttrAccount as String: scope.digest, kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
    public func read(scope: GatewayCommunityScope) throws -> Data? {
        var request = query(scope)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, data.count <= 32_768 else {
            throw GatewayCommunityFailure.storage
        }
        return data
    }
    public func write(_ data: Data, scope: GatewayCommunityScope) throws {
        guard data.count <= 32_768 else { throw GatewayCommunityFailure.storage }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let request = query(scope)
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GatewayCommunityFailure.storage }
    }
    public func remove(scope: GatewayCommunityScope) throws {
        let status = SecItemDelete(query(scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GatewayCommunityFailure.storage
        }
    }
}
func communityDigest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
func communityOwnedRecordName(accountID: String, kind: String, logicalID: String) -> String {
    let owner = communityDigest("echoes/public-owner/v1\0" + accountID)
    let logical = communityDigest("echoes/public-logical/v1\0" + logicalID)
    return "community-v1-" + kind + "-"
        + communityDigest("echoes/public-record/v1\0" + owner + "\0" + kind + "\0" + logical)
}
func communityReportID(scope: GatewayCommunityScope, messageID: String, reason: String) -> String {
    // Custom UUID v8, stable for this owner's exact report content; coordinates are not its identity.
    var bytes = Array(
        SHA256.hash(
            data: Data(("echoes/report-id/v1\0" + scope.digest + "\0" + messageID + "\0" + reason).utf8)
        ).prefix(16))
    bytes[6] = (bytes[6] & 15) | 128
    bytes[8] = (bytes[8] & 63) | 128
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    let offsets = [8, 12, 16, 20]
    return hex.enumerated().map { (offsets.contains($0.offset) ? "-" : "") + String($0.element) }.joined()
}

struct StoredCommunityMutation: Codable, Equatable {
    let key: String
    let operation: GatewayCommunityOperation
}
struct StoredCommunityJournal: Codable {
    let version: Int
    let scope: String
    var lease: String
    var pending: [StoredCommunityMutation]
}
@MainActor final class GatewayCommunityJournal {
    private let storage: any GatewayCommunityJournalStorage
    init(storage: any GatewayCommunityJournalStorage) { self.storage = storage }
    private func load(_ scope: GatewayCommunityScope) throws -> StoredCommunityJournal? {
        do {
            guard let data = try storage.read(scope: scope) else { return nil }
            guard data.count <= 32_768 else { throw GatewayCommunityFailure.storage }
            let value = try JSONDecoder().decode(StoredCommunityJournal.self, from: data)
            guard value.version == 1, value.scope == scope.digest, gatewayUUID(value.lease),
                value.pending.count <= 8,
                Set(value.pending.map(\.key)).count == value.pending.count
            else { throw GatewayCommunityFailure.storage }
            for entry in value.pending {
                _ = try entry.operation.encodedBody()
                guard entry.key != "invalid", entry.key == key(entry.operation) else {
                    throw GatewayCommunityFailure.storage
                }
            }
            return value
        } catch { throw GatewayCommunityFailure.storage }
    }
    private func save(_ value: StoredCommunityJournal, scope: GatewayCommunityScope) throws {
        do {
            guard value.pending.count <= 8 else { throw GatewayCommunityFailure.storage }
            let bytes = try JSONEncoder().encode(value)
            guard bytes.count <= 32_768 else { throw GatewayCommunityFailure.storage }
            try storage.write(bytes, scope: scope)
        } catch { throw GatewayCommunityFailure.storage }
    }
    func open(_ scope: GatewayCommunityScope, lease: String) throws {
        var value = try load(scope) ?? .init(version: 1, scope: scope.digest, lease: lease, pending: [])
        value.lease = lease
        try save(value, scope: scope)
    }
    func current(_ scope: GatewayCommunityScope, lease: String) throws -> StoredCommunityJournal {
        guard let value = try load(scope), value.lease == lease else {
            throw GatewayCommunityFailure.superseded
        }
        return value
    }
    func key(_ operation: GatewayCommunityOperation) -> String {
        switch operation {
        case .publish, .stop: "presence"
        case .send: "message"
        case .report: "report"
        case .block(_, let target, _, _): "block:" + target
        default: "invalid"
        }
    }
    func operation(_ key: String, scope: GatewayCommunityScope, lease: String) throws
        -> GatewayCommunityOperation?
    {
        try current(scope, lease: lease).pending.first { $0.key == key }?.operation
    }
    func put(_ operation: GatewayCommunityOperation, scope: GatewayCommunityScope, lease: String) throws {
        _ = try operation.encodedBody()
        let slot = key(operation)
        guard slot != "invalid" else { throw GatewayCommunityFailure.storage }
        var value = try current(scope, lease: lease)
        value.pending.removeAll { $0.key == slot }
        value.pending.append(.init(key: slot, operation: operation))
        try save(value, scope: scope)
    }
    func remove(_ operation: GatewayCommunityOperation, scope: GatewayCommunityScope, lease: String) throws {
        var value = try current(scope, lease: lease)
        guard let entry = value.pending.first(where: { $0.key == key(operation) }),
            entry.operation == operation
        else { throw GatewayCommunityFailure.superseded }
        value.pending.removeAll { $0.key == entry.key }
        try save(value, scope: scope)
    }
    func erase(_ scope: GatewayCommunityScope) throws { try storage.remove(scope: scope) }
}
