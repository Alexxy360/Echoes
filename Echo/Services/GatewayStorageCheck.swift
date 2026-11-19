#if DEBUG
    import CryptoKit
    import EchoesCloudKit
    import EchoesCore
    import Foundation
    import Security

    /// Isolated local diagnostic: no Apple identity, CloudKit, Firebase or HTTP requests.
    @MainActor enum GatewayStorageCheck {
        static func run() async -> String {
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
            let communityReport = await checkCommunity(configuration: config, cloudKit: cloudKit)
            let reportReview = await checkReportReview(configuration: config, cloudKit: cloudKit)
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
            if communityReport != "passed" { report = communityReport }
            if reportReview != "passed" { report = reportReview }
            // Fixed outcomes only; no synthetic token, encoded payload, attributes or native IDs.
            print("ECHOES_GATEWAY_DELETION_STORAGE_CHECK result=" + deletionReport)
            print("ECHOES_GATEWAY_COMMUNITY_STORAGE_CHECK result=" + communityReport)
            print("ECHOES_GATEWAY_STORAGE_CHECK result=" + report)
            return report
        }
        private static func checkCommunity(
            configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration
        ) async -> String {
            let storage = KeychainGatewayCommunityJournalStorage()
            var scopes: [GatewayCommunityScope] = []
            var result = "passed"
            do {
                let source = try CommunityStorageAuthorization()
                let api = CommunityStorageAPI(origin: configuration.origin.absoluteString)
                func makeClient() throws -> GatewayCommunityClient {
                    try .init(
                        api: api, configuration: configuration, cloudKit: cloudKit, authorization: source,
                        storage: storage,
                        coordinate: { .init(latitude: 0, longitude: 0) })
                }
                func scope() throws -> GatewayCommunityScope {
                    let identity = source.communityAuthorization!.identity
                    return try .init(
                        configuration: configuration, cloudKit: cloudKit, accountID: identity.accountID,
                        binding: identity.binding)
                }
                let a = try scope()
                scopes.append(a)
                let first = try makeClient()
                _ = try await first.connect()
                var unknown = false
                do {
                    _ = try await first.send(
                        text: "Syntetyczna próba A", name: "Kontrola",
                        coordinate: .init(latitude: 0, longitude: 0), requestID: UUID().uuidString)
                } catch GatewayCommunityFailure.unavailable { unknown = true }
                guard unknown, let original = try first.pendingMessage() else {
                    throw GatewayFailure.invalidResponse
                }
                let restored = try makeClient()
                _ = try await restored.connect()
                guard let pending = try restored.pendingMessage(), pending.requestID == original.requestID,
                    pending.text == original.text, pending.recoveryID != original.recoveryID
                else { throw GatewayFailure.invalidResponse }
                let originalBytes = try storage.read(scope: a)
                var rejected = false
                do {
                    try storage.write(Data(repeating: 65, count: 32_769), scope: a)
                } catch GatewayCommunityFailure.storage { rejected = true }
                guard rejected, try storage.read(scope: a) == originalBytes else {
                    throw GatewayFailure.invalidResponse
                }
                try source.selectAnotherAccount()
                let b = try scope()
                scopes.append(b)
                let other = try makeClient()
                _ = try await other.connect()
                do {
                    _ = try await other.send(
                        text: "Syntetyczna próba B", name: "Kontrola",
                        coordinate: .init(latitude: 0, longitude: 0), requestID: UUID().uuidString)
                } catch GatewayCommunityFailure.unavailable {}
                guard try other.pendingMessage()?.text == "Syntetyczna próba B" else {
                    throw GatewayFailure.invalidResponse
                }
                for item in scopes {
                    try verifyAttributes([
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: "mpvEcho.Echo.gateway.community.v1",
                        kSecAttrAccount as String: item.digest,
                        kSecAttrSynchronizable as String: false,
                        kSecUseDataProtectionKeychain as String: true,
                    ])
                }
                try restored.eraseJournal(scope: a)
                guard try storage.read(scope: a) == nil,
                    try other.pendingMessage()?.text == "Syntetyczna próba B"
                else { throw GatewayFailure.invalidResponse }
                try storage.write(Data(repeating: 65, count: 32_768), scope: b)
                guard try storage.read(scope: b)?.count == 32_768 else {
                    throw GatewayFailure.invalidResponse
                }
            } catch { result = "storage-failed" }
            for scope in scopes {
                do {
                    try storage.remove(scope: scope)
                    guard try storage.read(scope: scope) == nil else { throw GatewayFailure.invalidResponse }
                } catch { result = "cleanup-failed" }
            }
            return result
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

    @MainActor private final class CommunityStorageAuthorization: GatewayCommunityAuthorizationSource {
        private let binding: GatewayIdentityBinding
        var communityAuthorization: GatewayCommunityAuthorization?
        init() throws {
            binding = try .init(
                appleUserID: "synthetic-" + UUID().uuidString,
                cloudKitRecordName: "synthetic-" + UUID().uuidString)
            try selectAnotherAccount()
        }
        func selectAnotherAccount() throws {
            communityAuthorization = try .init(
                accountID: UUID().uuidString.lowercased(), binding: binding, revision: UUID())
        }
        func communityAccessToken(for expected: GatewayCommunityAuthorization) async throws -> GatewaySecret {
            guard communityAuthorization == expected else { throw GatewayFailure.superseded }
            return try GatewaySecret(UUID().uuidString.lowercased() + "." + String(repeating: "a", count: 43))
        }
        func rejectCommunityAccess(for expected: GatewayCommunityAuthorization) async {}
    }
    private actor CommunityStorageAPI: GatewayCommunityAPI {
        nonisolated let origin: String
        init(origin: String) { self.origin = origin }
        func perform(_ operation: GatewayCommunityOperation, token: GatewaySecret) async throws
            -> GatewayCommunityReply
        {
            // A deliberate unknown result with no network; the real journal must survive it.
            throw GatewayCommunityFailure.unavailable
        }
    }
#endif
