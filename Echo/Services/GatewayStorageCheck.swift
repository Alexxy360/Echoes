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
                let config = try? GatewayConfiguration(origin: origin),
                let cloudKit = try? CloudKitConfiguration(
                    containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
            else { return "configuration-failed" }
            let storage = KeychainGatewaySessionStorage(configuration: config)
            let deletionStorage = KeychainGatewayDeletionStorage(configuration: config, cloudKit: cloudKit)
            let sessionQuery = query(
                service: "mpvEcho.Echo.gateway.development.v1", seed: config.origin.absoluteString)
            let deletionQuery = query(
                service: "mpvEcho.Echo.gateway.deletions.v1",
                seed: "echoes/deletion-journal/v1\0"
                    + config.origin.absoluteString + "\0" + cloudKit.containerIdentifier + "\0"
                    + cloudKit.environment.rawValue)
            var report = "passed"
            var deletionReport = "passed"
            do {
                guard try storage.read() == nil, try deletionStorage.read() == nil else {
                    throw GatewayFailure.invalidResponse
                }
                try storage.write(Data("synthetic-old-pair".utf8))
                try storage.write(Data("synthetic-new-pair".utf8))
                guard try storage.read() == Data("synthetic-new-pair".utf8) else {
                    throw GatewayFailure.invalidResponse
                }
                try verifyAttributes(sessionQuery)
            } catch { report = "storage-failed" }
            do {
                let ticket = try GatewayDeletionTicket.create()
                let encoded = try JSONEncoder().encode(ticket)
                try deletionStorage.write(encoded)
                guard let stored = try deletionStorage.read(),
                    try JSONDecoder().decode(GatewayDeletionTicket.self, from: stored) == ticket
                else {
                    throw GatewayFailure.invalidResponse
                }
                // Exercise replacement and enough space for a bounded serialized SDK cursor.
                let replacement = Data(repeating: 65, count: 32_768)
                try deletionStorage.write(replacement)
                try storage.write(Data("synthetic-signed-out-tombstone".utf8))
                guard try deletionStorage.read() == replacement else { throw GatewayFailure.invalidResponse }
                var rejectedOversize = false
                do { try deletionStorage.write(Data(repeating: 66, count: 65_537)) } catch GatewayFailure
                    .storageUnavailable
                { rejectedOversize = true }
                guard rejectedOversize, try deletionStorage.read() == replacement else {
                    throw GatewayFailure.invalidResponse
                }
                try verifyAttributes(deletionQuery)
            } catch { deletionReport = "storage-failed" }
            print("ECHOES_GATEWAY_STORAGE_BEFORE_CLEANUP session=" + report + " deletion=" + deletionReport)
            for (index, item) in [sessionQuery, deletionQuery].enumerated() {
                let cleanup = SecItemDelete(item as CFDictionary)
                print("ECHOES_GATEWAY_STORAGE_DELETE slot=" + String(index) + " status=" + String(cleanup))
                if cleanup != errSecSuccess && cleanup != errSecItemNotFound {
                    report = "cleanup-failed"
                    deletionReport = "cleanup-failed"
                }
            }
            for (index, item) in [sessionQuery, deletionQuery].enumerated() {
                var readQuery = item
                readQuery[kSecReturnData as String] = true
                readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
                var value: CFTypeRef?
                let status = SecItemCopyMatching(readQuery as CFDictionary, &value)
                print(
                    "ECHOES_GATEWAY_STORAGE_AFTER_DELETE slot=" + String(index) + " status=" + String(status))
            }
            do {
                guard try storage.read() == nil, try deletionStorage.read() == nil else {
                    throw GatewayFailure.invalidResponse
                }
            } catch {
                report = "cleanup-failed"
                deletionReport = "cleanup-failed"
            }
            if deletionReport != "passed" { report = deletionReport }
            // Fixed outcomes only; no synthetic token, encoded payload, attributes or native IDs.
            print("ECHOES_GATEWAY_DELETION_STORAGE_CHECK result=" + deletionReport)
            print("ECHOES_GATEWAY_STORAGE_CHECK result=" + report)
            return report
        }
        private static func query(service: String, seed: String) -> [String: Any] {
            let account = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
            return [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true,
            ]
        }
        private static func verifyAttributes(_ query: [String: Any]) throws {
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
        }
    }
#endif
