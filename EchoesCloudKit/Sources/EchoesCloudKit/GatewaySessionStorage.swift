import CryptoKit
import Foundation
import Security

/// Synchronous writes are intentional: the session actor must not yield between its revision check
/// and the atomic replacement of both tokens. Implementations must never persist partial pairs.
public protocol GatewaySessionStorage: Sendable {
    func read() throws -> Data?
    func write(_ value: Data) throws
}

public struct KeychainGatewaySessionStorage: GatewaySessionStorage {
    private let account: String
    public init(configuration: GatewayConfiguration) {
        account = SHA256.hash(data: Data(configuration.origin.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "mpvEcho.Echo.gateway.development.v1",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
    public func read() throws -> Data? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 8_192 else {
            throw GatewayFailure.storageUnavailable
        }
        return data
    }
    public func write(_ value: Data) throws {
        guard value.count <= 8_192 else { throw GatewayFailure.storageUnavailable }
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

struct StoredGatewaySession: Codable {
    enum State: String, Codable { case ready, renewalPending, signedOut }
    let version: Int
    let origin: String
    let binding: GatewayIdentityBinding?
    let state: State
    let pair: GatewaySessionPair?
}
