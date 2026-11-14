#if DEBUG
    import CryptoKit
    import EchoesCloudKit
    import Foundation
    import Security

    /// Isolated local diagnostic: no Apple identity, CloudKit, Firebase or HTTP requests.
    enum GatewayStorageCheck {
        static func run() -> String {
            guard
                let origin = URL(
                    string: "https://keychain-" + UUID().uuidString.lowercased() + ".example.invalid"),
                let config = try? GatewayConfiguration(origin: origin)
            else { return "configuration-failed" }
            let storage = KeychainGatewaySessionStorage(configuration: config)
            let account = SHA256.hash(data: Data(config.origin.absoluteString.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "mpvEcho.Echo.gateway.development.v1",
                kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true,
            ]
            var report = "passed"
            do {
                guard try storage.read() == nil else { throw GatewayFailure.invalidResponse }
                try storage.write(Data("synthetic-old-pair".utf8))
                try storage.write(Data("synthetic-new-pair".utf8))
                guard try storage.read() == Data("synthetic-new-pair".utf8) else {
                    throw GatewayFailure.invalidResponse
                }
                var attributesQuery = query
                attributesQuery[kSecReturnAttributes as String] = true
                attributesQuery[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(attributesQuery as CFDictionary, &result)
                guard status == errSecSuccess, let attributes = result as? [String: Any],
                    attributes[kSecAttrAccessible as String] as? String
                        == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                    (attributes[kSecAttrSynchronizable as String] as? Bool) != true
                else { throw GatewayFailure.invalidResponse }
            } catch { report = "storage-failed" }
            let cleanup = SecItemDelete(query as CFDictionary)
            if cleanup != errSecSuccess && cleanup != errSecItemNotFound { report = "cleanup-failed" }
            // Only a fixed outcome; never the synthetic value, attributes, user IDs or tokens.
            print("ECHOES_GATEWAY_STORAGE_CHECK result=" + report)
            return report
        }
    }
#endif
