#if DEBUG
    import EchoesCloudKit
    import Foundation
    import Security

    extension GatewayStorageCheck {
        /// App-hosted local Keychain check. Every owner/identity/intent is synthetic and random.
        /// The only API is a read-only canned transport: no URLSession, CloudKit or native identity.
        /// The namespace is new and used only by this test until the application host is connected.
        static func checkAvatarReport(configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration)
            async -> String
        {
            let storage = KeychainGatewayAvatarReportJournalStorage()
            var scopes: [GatewayAvatarReportScope] = []
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
                let a = try GatewayAvatarReportScope(
                    configuration: configuration, owner: owner, binding: binding)
                let alternate = try GatewayAvatarReportScope(
                    configuration: otherOrigin, owner: owner, binding: binding)
                let b = try GatewayAvatarReportScope(
                    configuration: configuration, owner: otherOwner, binding: binding)
                scopes = [a, alternate, b]
                let intent = try GatewayAvatarReportIdentity(
                    accountID: owner.accountID, requestID: UUID().uuidString.lowercased())
                let journal = GatewayAvatarReportJournal(storage: storage)
                phase = "prepare"
                guard try await journal.peek(scope: a) == nil else {
                    throw GatewayAvatarReportFailure.invalidResponse
                }
                let lease = try await journal.open(scope: a)
                let prepared = try await journal.prepare(intent, lease: lease)
                let dispatched = try await journal.dispatched(prepared, lease: lease)
                phase = "reopen"
                let restored = GatewayAvatarReportJournal(storage: storage)
                let replacement = try await restored.open(scope: a)
                guard try await restored.pending(lease: replacement) == dispatched else {
                    throw GatewayAvatarReportFailure.invalidResponse
                }
                let alternateLease = try await restored.open(scope: alternate)
                _ = try await restored.prepare(intent, lease: alternateLease)
                let otherLease = try await restored.open(scope: b)
                let otherIntent = try GatewayAvatarReportIdentity(
                    accountID: otherOwner.accountID, requestID: UUID().uuidString.lowercased())
                let otherEntry = try await restored.prepare(otherIntent, lease: otherLease)
                phase = "recovery"
                let current = try await restored.open(scope: a)
                let client = GatewayAvatarReportHTTPClient(
                    configuration: configuration, transport: PhotoReportJournalCheckAPI(), isEnabled: { true }
                )
                let bearer = try GatewaySecret(
                    UUID().uuidString.lowercased() + "." + String(repeating: "a", count: 43))
                let recovery = try await client.recover(intent, token: bearer)
                let resolved = try await restored.resolve(dispatched, result: recovery, lease: current)
                guard resolved.phase == .resolved else { throw GatewayAvatarReportFailure.invalidResponse }
                phase = "attributes"
                for scope in scopes {
                    let valid = await Task.detached {
                        var query = photoReportJournalQuery(scope)
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
                    guard valid else { throw GatewayAvatarReportFailure.invalidResponse }
                }
                phase = "oversize"
                let rejected = try await Task.detached {
                    let original = try storage.read(scope: a)
                    do {
                        try storage.write(Data(repeating: 65, count: 4097), scope: a)
                        return false
                    } catch GatewayAvatarReportJournalFailure.unavailable {
                        return try storage.read(scope: a) == original
                    }
                }.value
                guard rejected else { throw GatewayAvatarReportFailure.invalidResponse }
                phase = "capacity"
                // Current service contains three synthetic test scopes. Fill only this newly
                // introduced namespace, then erase every scope of our two random owners.
                for n in 0..<(32 - scopes.count) {
                    let origin = try GatewayConfiguration(
                        origin: URL(
                            string: "https://photo-cap-" + String(n) + "-" + UUID().uuidString.lowercased()
                                + ".example.invalid")!)
                    let scope = try GatewayAvatarReportScope(
                        configuration: origin, owner: owner, binding: binding)
                    scopes.append(scope)
                    try await Task.detached {
                        try storage.write(Data("synthetic-capacity".utf8), scope: scope)
                    }.value
                }
                let overflow = try GatewayAvatarReportScope(
                    configuration: .init(
                        origin: URL(
                            string: "https://overflow-" + UUID().uuidString.lowercased() + ".example.invalid")!
                    ), owner: owner, binding: binding)
                scopes.append(overflow)
                let capacityRejected = try await Task.detached {
                    let original = try storage.read(scope: b)
                    try storage.write(original!, scope: b)  // Updates remain allowed when full.
                    do {
                        try storage.write(Data("synthetic-overflow".utf8), scope: overflow)
                        return false
                    } catch GatewayAvatarReportJournalFailure.unavailable {
                        return try storage.read(scope: overflow) == nil && storage.read(scope: b) == original
                    }
                }.value
                guard capacityRejected else { throw GatewayAvatarReportFailure.invalidResponse }
                phase = "owner-erasure"
                try await restored.erase(owner: owner)
                let absent = try await Task.detached {
                    try storage.read(scope: a) == nil && storage.read(scope: alternate) == nil
                        && storage.read(scope: b) != nil
                }.value
                guard absent, try await restored.pending(lease: restored.open(scope: b)) == otherEntry else {
                    throw GatewayAvatarReportFailure.invalidResponse
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
            print("ECHOES_AVATAR_REPORT_JOURNAL_CHECK result=" + result)
            return result
        }
    }

    extension GatewayStorageCheck {
        /// Process-restart proof for a scope derived exclusively from a random test UUID.
        /// No user identity can be supplied; both native identifiers have fixed synthetic prefixes.
        static func checkAvatarReportRestartIfRequested() async -> String? {
            let env = ProcessInfo.processInfo.environment
            guard let testID = env["ECHOES_PHOTO_REPORT_RESTART_ID"] else { return nil }
            guard UUID(uuidString: testID)?.uuidString.lowercased() == testID,
                let phase = env["ECHOES_PHOTO_REPORT_RESTART_PHASE"],
                ["prepare", "recover", "cancel-prepare", "cancel-recover", "cleanup"].contains(phase)
            else { return "restart-configuration-failed" }
            let storage = KeychainGatewayAvatarReportJournalStorage()
            do {
                let config = try GatewayConfiguration(
                    origin: URL(string: "https://photo-restart.example.invalid")!)
                let cloudKit = try CloudKitConfiguration(
                    containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
                let cloud = "synthetic-photo-restart-cloud-" + testID
                let owner = try PrivateAccountScope(
                    configuration: cloudKit, accountID: testID, cloudKitRecordName: cloud)
                let binding = try GatewayIdentityBinding(
                    appleUserID: "synthetic-photo-restart-apple-" + testID, cloudKitRecordName: cloud)
                let scope = try GatewayAvatarReportScope(
                    configuration: config, owner: owner, binding: binding)
                if phase == "cleanup" {
                    try await Task.detached { try storage.erase(owner: owner) }.value
                    let absent = try await Task.detached { try storage.read(scope: scope) == nil }.value
                    guard absent else {
                        throw GatewayAvatarReportFailure.invalidResponse
                    }
                } else {
                    let identity = try GatewayAvatarReportIdentity(accountID: testID, requestID: testID)
                    let journal = GatewayAvatarReportJournal(storage: storage)
                    if phase == "prepare" || phase == "cancel-prepare" {
                        guard try await journal.peek(scope: scope) == nil else {
                            throw GatewayAvatarReportFailure.invalidResponse
                        }
                        let lease = try await journal.open(scope: scope)
                        let entry = try await journal.dispatched(
                            journal.prepare(identity, lease: lease), lease: lease)
                        let saved =
                            phase == "cancel-prepare"
                            ? try await journal.cancelling(entry, lease: lease) : entry
                        guard saved.intent == identity,
                            saved.phase == (phase == "cancel-prepare" ? .cancelling : .dispatched)
                        else {
                            throw GatewayAvatarReportFailure.invalidResponse
                        }
                    } else {
                        let lease = try await journal.open(scope: scope)
                        guard let entry = try await journal.pending(lease: lease), entry.intent == identity,
                            entry.phase == (phase == "cancel-recover" ? .cancelling : .dispatched)
                        else { throw GatewayAvatarReportFailure.invalidResponse }
                        let client = GatewayAvatarReportHTTPClient(
                            configuration: config,
                            transport: PhotoReportJournalCheckAPI(
                                outcome: phase == "cancel-recover" ? "cancelled" : "accepted"),
                            isEnabled: { true })
                        let token = try GatewaySecret(testID + "." + String(repeating: "a", count: 43))
                        let outcome = try await client.recover(identity, token: token)
                        let resolved = try await journal.resolve(entry, result: outcome, lease: lease)
                        try await journal.acknowledge(resolved, lease: lease)
                        try await journal.erase(owner: owner)
                        let absent = try await Task.detached { try storage.read(scope: scope) == nil }.value
                        guard absent else {
                            throw GatewayAvatarReportFailure.invalidResponse
                        }
                    }
                }
                print("ECHOES_AVATAR_REPORT_RESTART phase=" + phase + " result=passed")
                return "passed"
            } catch {
                print("ECHOES_AVATAR_REPORT_RESTART phase=" + phase + " result=failed")
                return "restart-" + phase + "-failed"
            }
        }
    }

    private nonisolated func photoReportJournalQuery(_ scope: GatewayAvatarReportScope) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "mpvEcho.Echo.gateway.avatar-report.v1",
            kSecAttrAccount as String: scope.storageIdentifier,
            kSecAttrGeneric as String: Data(scope.ownerStorageIdentifier.utf8),
            kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true,
        ]
    }
    private actor PhotoReportJournalCheckAPI: GatewayAvatarReportTransport {
        let outcome: String
        init(outcome: String = "accepted") { self.outcome = outcome }
        func send(_ request: URLRequest, operation: GatewayAvatarReportOperation) async throws
            -> GatewayAvatarReportHTTPResponse
        {
            guard case .recover(let intent) = operation else { throw GatewayAvatarReportFailure.invalidInput }
            let body: [String: Any] = [
                "protocolVersion": 1, "schemaVersion": 1,
                "requestID": intent.requestID, "reportID": intent.reportID, "outcome": outcome,
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
