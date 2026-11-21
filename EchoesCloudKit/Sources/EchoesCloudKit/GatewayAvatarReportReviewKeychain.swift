import Foundation
import Security

/// Metadata only. Separate service; unlocked on this device, never synchronized to iCloud Keychain.
public struct KeychainGatewayAvatarReportReviewJournalStorage: GatewayAvatarReportReviewJournalStorage {
    public init() {}
    static let service = "mpvEcho.Echo.gateway.avatar-report-review.v1"
    func ownerQuery(_ owner: PrivateAccountScope) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrGeneric as String: Data(owner.digest.utf8), kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
    func query(_ scope: GatewayAvatarReportReviewScope) -> [String: Any] {
        ownerQuery(scope.owner).merging([kSecAttrAccount as String: scope.digest]) { _, new in new }
    }
    static var accessibility: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
    public func read(scope: GatewayAvatarReportReviewScope) throws -> Data? {
        var request = query(scope)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 4096 else {
            throw GatewayAvatarReportReviewJournalFailure.unavailable
        }
        return data
    }
    public func write(_ data: Data, scope: GatewayAvatarReportReviewScope) throws {
        guard data.count <= 4096 else { throw GatewayAvatarReportReviewJournalFailure.unavailable }
        let request = query(scope)
        let attributes: [String: Any] = [
            kSecValueData as String: data, kSecAttrAccessible as String: Self.accessibility,
        ]
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GatewayAvatarReportReviewJournalFailure.unavailable }
    }
    public func erase(owner: PrivateAccountScope) throws {
        let status = SecItemDelete(ownerQuery(owner) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GatewayAvatarReportReviewJournalFailure.unavailable
        }
    }
}
