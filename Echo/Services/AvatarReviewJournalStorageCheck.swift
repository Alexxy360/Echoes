#if DEBUG
    import EchoesCloudKit
    import Foundation
    import Security

    extension GatewayStorageCheck {
        /// App-hosted local Keychain check. Every owner/identity/intent is synthetic and random.
        /// The only API uses canned responses: no URLSession, CloudKit or native identity.
        static func checkAvatarReview(configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration)
            async -> String
        {
            let storage = KeychainGatewayAvatarReviewJournalStorage()
            var scopes: [GatewayAvatarReviewScope] = []
            var owners: [PrivateAccountScope] = []
            var phase = "configuration"
            var result = "passed"
            do {
                let cloud = "synthetic-upload-review-" + UUID().uuidString.lowercased()
                let binding = try GatewayIdentityBinding(
                    appleUserID: "synthetic-" + UUID().uuidString.lowercased(), cloudKitRecordName: cloud)
                let owner = try PrivateAccountScope(
                    configuration: cloudKit, accountID: UUID().uuidString.lowercased(),
                    cloudKitRecordName: cloud)
                let otherOwner = try PrivateAccountScope(
                    configuration: cloudKit, accountID: UUID().uuidString.lowercased(),
                    cloudKitRecordName: cloud)
                owners = [owner, otherOwner]
                let otherOrigin = try GatewayConfiguration(
                    origin: URL(
                        string: "https://upload-review-" + UUID().uuidString.lowercased() + ".example.invalid"
                    )!)
                let a = try GatewayAvatarReviewScope(
                    configuration: configuration, owner: owner, binding: binding)
                let alternate = try GatewayAvatarReviewScope(
                    configuration: otherOrigin, owner: owner, binding: binding)
                let b = try GatewayAvatarReviewScope(
                    configuration: configuration, owner: otherOwner, binding: binding)
                scopes = [a, alternate, b]
                let intent = try GatewayAvatarReviewRecoveryIntent(
                    item: .init(
                        accountID: UUID().uuidString.lowercased(), requestID: UUID().uuidString.lowercased(),
                        versionID: UUID().uuidString.lowercased(), generation: 1,
                        reviewRevision: UUID().uuidString.lowercased()),
                    decisionID: UUID().uuidString.lowercased(), verdict: .rejected)
                let journal = GatewayAvatarReviewJournal(storage: storage)
                phase = "prepare"
                guard try await journal.peek(scope: a) == nil else {
                    throw GatewayAvatarReviewFailure.invalidResponse
                }
                let lease = try await journal.open(scope: a)
                let prepared = try await journal.prepare(intent, lease: lease)
                let dispatched = try await journal.dispatched(prepared, lease: lease)
                phase = "reopen"
                let restored = GatewayAvatarReviewJournal(storage: storage)
                let replacement = try await restored.open(scope: a)
                guard try await restored.pending(lease: replacement) == dispatched else {
                    throw GatewayAvatarReviewFailure.invalidResponse
                }
                let alternateLease = try await restored.open(scope: alternate)
                _ = try await restored.prepare(intent, lease: alternateLease)
                let otherLease = try await restored.open(scope: b)
                let otherEntry = try await restored.prepare(intent, lease: otherLease)
                phase = "recovery"
                let current = try await restored.open(scope: a)
                let client = GatewayAvatarReviewHTTPClient(
                    configuration: configuration, transport: AvatarReviewJournalCheckAPI(),
                    isEnabled: { true })
                let bearer = try GatewaySecret(
                    UUID().uuidString.lowercased() + "." + String(repeating: "a", count: 43))
                let recovery = try await client.recover(intent, token: bearer)
                let observed = try await restored.resolve(dispatched, result: recovery, lease: current)
                guard observed.phase == .dispatched else { throw GatewayAvatarReviewFailure.invalidResponse }
                phase = "retiring-reopen"
                let retiring = try await restored.retiring(observed, lease: current)
                let restarted = GatewayAvatarReviewJournal(storage: storage)
                let fresh = try await restarted.open(scope: a)
                guard try await restarted.pending(lease: fresh) == retiring else {
                    throw GatewayAvatarReviewFailure.invalidResponse
                }
                let closed = try await client.retire(intent, token: bearer)
                let resolved = try await restarted.resolve(retiring, result: closed, lease: fresh)
                guard resolved.phase == .resolved, closed.outcome == .retired else {
                    throw GatewayAvatarReviewFailure.invalidResponse
                }
                phase = "attributes"
                for scope in scopes {
                    let valid = await Task.detached {
                        var query = avatarReviewJournalQuery(scope)
                        query[kSecReturnAttributes as String] = true
                        query[kSecMatchLimit as String] = kSecMatchLimitOne
                        var value: CFTypeRef?
                        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
                            let attributes = value as? [String: Any]
                        else { return false }
                        return attributes[kSecAttrAccessible as String] as? String
                            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
                            && (attributes[kSecAttrSynchronizable as String] as? Bool) != true
                    }.value
                    guard valid else { throw GatewayAvatarReviewFailure.invalidResponse }
                }
                phase = "oversize"
                let rejected = try await Task.detached {
                    let original = try storage.read(scope: a)
                    do {
                        try storage.write(Data(repeating: 65, count: 4097), scope: a)
                        return false
                    } catch GatewayAvatarReviewJournalFailure.unavailable {
                        return try storage.read(scope: a) == original
                    }
                }.value
                guard rejected else { throw GatewayAvatarReviewFailure.invalidResponse }
                phase = "owner-erasure"
                try await restored.erase(owner: owner)
                let absent = try await Task.detached {
                    try storage.read(scope: a) == nil && storage.read(scope: alternate) == nil
                        && storage.read(scope: b) != nil
                }.value
                guard absent, try await restored.pending(lease: restored.open(scope: b)) == otherEntry else {
                    throw GatewayAvatarReviewFailure.invalidResponse
                }
            } catch { result = phase + "-failed" }
            for owner in owners {
                do { try await Task.detached { try storage.erase(owner: owner) }.value } catch {
                    result = "cleanup-failed"
                }
            }
            for scope in scopes {
                do {
                    let absent = try await Task.detached { try storage.read(scope: scope) == nil }.value
                    if !absent { result = "cleanup-failed" }
                } catch { result = "cleanup-failed" }
            }
            print("ECHOES_AVATAR_REVIEW_JOURNAL_CHECK result=" + result)
            return result
        }
    }

    private nonisolated func avatarReviewJournalQuery(_ scope: GatewayAvatarReviewScope) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "mpvEcho.Echo.gateway.avatar-review.v1",
            kSecAttrAccount as String: scope.storageIdentifier,
            kSecAttrGeneric as String: Data(scope.ownerStorageIdentifier.utf8),
            kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true,
        ]
    }
    private actor AvatarReviewJournalCheckAPI: GatewayAvatarReviewTransport {
        func send(_ request: URLRequest, operation: GatewayAvatarReviewOperation) async throws
            -> GatewayAvatarHTTPResponse
        {
            let intent: GatewayAvatarReviewRecoveryIntent
            let outcome: String
            switch operation {
            case .recover(let value):
                intent = value
                outcome = "not-applied"
            case .retire(let value):
                intent = value
                outcome = "retired"
            default: throw GatewayAvatarReviewFailure.invalidInput
            }
            let body: [String: Any] = [
                "protocolVersion": 1, "schemaVersion": 1, "accountID": intent.item.accountID,
                "requestID": intent.item.requestID,
                "versionID": intent.item.versionID, "generation": intent.item.generation,
                "reviewRevision": intent.item.reviewRevision,
                "decisionID": intent.decisionID, "verdict": intent.verdict.rawValue,
                "outcome": outcome, "revision": NSNull(),
            ]
            return .init(
                status: 200,
                headers: [
                    "Content-Type": "application/json", "Cache-Control": "no-store",
                    "X-Content-Type-Options": "nosniff",
                ], body: try JSONSerialization.data(withJSONObject: body))
        }
    }
#endif
