#if DEBUG
    import CryptoKit
    import EchoesCloudKit
    import Foundation
    import Security

    extension GatewayStorageCheck {
        /// App-hosted local Keychain check. Every owner/identity/intent is synthetic and random.
        /// The only API is a canned inspect/recover/retire transport: no URLSession, CloudKit or native identity.
        static func checkAvatarReportReview(
            configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration
        )
            async -> String
        {
            let storage = KeychainGatewayAvatarReportReviewJournalStorage()
            var scopes: [GatewayAvatarReportReviewScope] = []
            var owners: [PrivateAccountScope] = []
            var phase = "configuration"
            var result = "passed"
            do {
                let cloud = "synthetic-report-" + UUID().uuidString.lowercased()
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
                        string: "https://report-" + UUID().uuidString.lowercased() + ".example.invalid")!)
                let a = try GatewayAvatarReportReviewScope(
                    configuration: configuration, owner: owner, binding: binding)
                let alternate = try GatewayAvatarReportReviewScope(
                    configuration: otherOrigin, owner: owner, binding: binding)
                let b = try GatewayAvatarReportReviewScope(
                    configuration: configuration, owner: otherOwner, binding: binding)
                scopes = [a, alternate, b]
                let api = try await ReportedPhotoJournalCheckAPI.make()
                let client = GatewayAvatarReportReviewHTTPClient(
                    configuration: configuration, transport: api, isEnabled: { true })
                let bearer = try GatewaySecret(
                    UUID().uuidString.lowercased() + "." + String(repeating: "a", count: 43))
                let inspection = try await client.inspect(api.item, token: bearer)
                let intent = try GatewayAvatarReportReviewSavedIntent(
                    decision: .init(
                        receipt: inspection.receipt, decisionID: UUID().uuidString.lowercased(),
                        verdict: .hidePhoto))
                guard intent.photoTarget != nil else {
                    throw GatewayAvatarReportReviewFailure.invalidResponse
                }
                let journal = GatewayAvatarReportReviewJournal(storage: storage)
                phase = "prepare"
                guard try await journal.peek(scope: a) == nil else {
                    throw GatewayAvatarReportReviewFailure.invalidResponse
                }
                let lease = try await journal.open(scope: a)
                let prepared = try await journal.prepare(intent, lease: lease)
                let dispatched = try await journal.dispatched(prepared, lease: lease)
                phase = "reopen"
                let restored = GatewayAvatarReportReviewJournal(storage: storage)
                let replacement = try await restored.open(scope: a)
                guard try await restored.pending(lease: replacement) == dispatched else {
                    throw GatewayAvatarReportReviewFailure.invalidResponse
                }
                let alternateLease = try await restored.open(scope: alternate)
                _ = try await restored.prepare(intent, lease: alternateLease)
                let otherLease = try await restored.open(scope: b)
                let otherEntry = try await restored.prepare(intent, lease: otherLease)
                phase = "recovery"
                let current = try await restored.open(scope: a)
                let recovery = try await client.recover(intent.recovery, token: bearer)
                let observed = try await restored.resolve(dispatched, result: recovery, lease: current)
                guard observed.phase == .dispatched else {
                    throw GatewayAvatarReportReviewFailure.invalidResponse
                }
                phase = "retiring-reopen"
                let retiring = try await restored.retiring(observed, lease: current)
                let restarted = GatewayAvatarReportReviewJournal(storage: storage)
                let fresh = try await restarted.open(scope: a)
                guard try await restarted.pending(lease: fresh) == retiring else {
                    throw GatewayAvatarReportReviewFailure.invalidResponse
                }
                let closed = try await client.retire(intent.recovery, token: bearer)
                let resolved = try await restarted.resolve(retiring, result: closed, lease: fresh)
                guard resolved.phase == .resolved, closed.outcome == .retired else {
                    throw GatewayAvatarReportReviewFailure.invalidResponse
                }
                phase = "attributes"
                for scope in scopes {
                    let valid = await Task.detached {
                        var query = reportedPhotoJournalQuery(scope)
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
                    guard valid else { throw GatewayAvatarReportReviewFailure.invalidResponse }
                }
                if ProcessInfo.processInfo.environment["ECHOES_GATEWAY_REPORTED_PHOTO_STORAGE_FAULT"] == "1" {
                    phase = "injected-bound"
                    try await Task.detached { try storage.write(Data(repeating: 65, count: 4097), scope: a) }
                        .value
                    throw GatewayAvatarReportReviewFailure.invalidResponse
                }
                phase = "oversize"
                let rejected = try await Task.detached {
                    let original = try storage.read(scope: a)
                    do {
                        try storage.write(Data(repeating: 65, count: 4097), scope: a)
                        return false
                    } catch GatewayAvatarReportReviewJournalFailure.unavailable {
                        return try storage.read(scope: a) == original
                    }
                }.value
                guard rejected else { throw GatewayAvatarReportReviewFailure.invalidResponse }
                phase = "terminal-ack"
                try await restarted.acknowledge(resolved, lease: fresh)
                let afterACK = GatewayAvatarReportReviewJournal(storage: storage)
                let afterLease = try await afterACK.open(scope: a)
                guard try await afterACK.pending(lease: afterLease) == nil else {
                    throw GatewayAvatarReportReviewFailure.invalidResponse
                }
                phase = "binding-fence"
                try restored.fenceForAccountDeletion(binding: binding, accountID: nil)
                for scopedOwner in [alternate, b] {
                    do {
                        _ = try await restored.open(scope: scopedOwner)
                        throw GatewayAvatarReportReviewFailure.invalidResponse
                    } catch GatewayAvatarReportReviewJournalFailure.inactive {}
                }
                phase = "owner-erasure"
                try await restored.erase(owner: owner)
                let absent = try await Task.detached {
                    try storage.read(scope: a) == nil && storage.read(scope: alternate) == nil
                        && storage.read(scope: b) != nil
                }.value
                let otherJournal = GatewayAvatarReportReviewJournal(storage: storage)
                guard absent, try await otherJournal.pending(lease: otherJournal.open(scope: b)) == otherEntry
                else {
                    throw GatewayAvatarReportReviewFailure.invalidResponse
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
            print("ECHOES_REPORTED_PHOTO_REVIEW_JOURNAL_CHECK result=" + result)
            return result
        }
    }

    private nonisolated func reportedPhotoJournalQuery(_ scope: GatewayAvatarReportReviewScope) -> [String:
        Any]
    {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "mpvEcho.Echo.gateway.avatar-report-review.v1",
            kSecAttrAccount as String: scope.storageIdentifier,
            kSecAttrGeneric as String: Data(scope.ownerStorageIdentifier.utf8),
            kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true,
        ]
    }
    private actor ReportedPhotoJournalCheckAPI: GatewayAvatarReportReviewTransport {
        nonisolated let item: GatewayAvatarReportReviewItem
        private let manifest: AvatarManifest, bytes: Data
        private let owner = UUID().uuidString.lowercased(), version = UUID().uuidString.lowercased()
        init(item: GatewayAvatarReportReviewItem, manifest: AvatarManifest, bytes: Data) {
            self.item = item
            self.manifest = manifest
            self.bytes = bytes
        }
        @MainActor static func make() async throws -> ReportedPhotoJournalCheckAPI {
            let api = CommunityAvatarPreviewAPI.make(mode: "normal")
            let query = try GatewayAvatarQuery(
                reference: .init(
                    ownerID: CommunityAvatarPreviewData.ownerA,
                    versionID: CommunityAvatarPreviewData.version), variant: .image)
            guard
                case .downloaded(let manifest, let bytes) = try await api.read(
                    query, token: GatewaySecret("synthetic-preview"))
            else {
                throw GatewayAvatarReportReviewFailure.invalidResponse
            }
            let now = Int(Date().timeIntervalSince1970 * 1000) - 5000
            let hash = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }
                .joined()
            return try .init(
                item: .init(
                    reportID: "community-v1-avatarreport-" + hash,
                    createdAtMilliseconds: now, expiresAtMilliseconds: now + 2_592_000_000),
                manifest: manifest, bytes: bytes)
        }
        func send(_ request: URLRequest, operation: GatewayAvatarReportReviewOperation) async throws
            -> GatewayAvatarReportReviewHTTPResponse
        {
            let intent: GatewayAvatarReportReviewRecoveryIntent
            let outcome: String
            switch operation {
            case .inspect(let requested):
                guard requested == item else { throw GatewayAvatarReportReviewFailure.invalidInput }
                let hash = SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }
                    .joined()
                let metadata = try JSONSerialization.data(withJSONObject: [
                    "protocolVersion": 1, "schemaVersion": 1,
                    "inspectionID": UUID().uuidString.lowercased(),
                    "inspectionExpiresAt": Int(Date().timeIntervalSince1970 * 1000) + 90_000,
                    "contentHash": hash, "reportID": item.reportID,
                    "createdAt": item.createdAtMilliseconds, "expiresAt": item.expiresAtMilliseconds,
                    "reason": "Syntetyczny test lokalnego Keychain.",
                    "photo": [
                        "ownerID": owner, "versionID": version, "publicationGeneration": 1,
                        "manifest": [
                            "schemaVersion": 1, "ownerID": owner, "versionID": version,
                            "variant": "image", "byteCount": manifest.byteCount,
                            "width": manifest.width, "height": manifest.height,
                            "sha256": manifest.sha256,
                        ],
                    ],
                ])
                let n = metadata.count
                guard (1...12288).contains(n), bytes.count <= 256_000 else {
                    throw GatewayAvatarReportReviewFailure.invalidResponse
                }
                var frame = Data([
                    UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255),
                ])
                frame.append(metadata)
                frame.append(bytes)
                return .init(
                    status: 200,
                    headers: [
                        "Content-Type": "application/vnd.echoes.avatar-report-inspection.v1",
                        "Cache-Control": "private, no-store", "Pragma": "no-cache",
                        "X-Content-Type-Options": "nosniff", "Content-Length": String(frame.count),
                    ], body: frame)
            case .recover(let value):
                intent = value
                outcome = "not-applied"
            case .retire(let value):
                intent = value
                outcome = "retired"
            default: throw GatewayAvatarReportReviewFailure.invalidInput
            }
            let body: [String: Any] = [
                "protocolVersion": 1, "schemaVersion": 1, "reportID": intent.reportID,
                "decisionID": intent.decisionID, "verdict": intent.verdict.rawValue,
                "contentHash": intent.contentHash, "outcome": outcome, "revision": NSNull(),
            ]
            return .init(
                status: 200,
                headers: [
                    "Content-Type": "application/json", "Cache-Control": "no-store",
                    "X-Content-Type-Options": "nosniff",
                ],
                body: try JSONSerialization.data(withJSONObject: body))
        }
    }
#endif
