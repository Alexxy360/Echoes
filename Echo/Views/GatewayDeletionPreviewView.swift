#if DEBUG
    import CloudKit
    import EchoesCloudKit
    import Foundation
    import SwiftUI

    /// Explicit UI-only fixture. Never selected as a fallback for missing real activation.
    /// No HTTP transport, native Apple authorizer, system account source, Keychain or user files.
    struct GatewayDeletionPreviewView: View {
        let mode: String
        @State private var host: GatewayDeletionHost?
        @State private var failed = false
        var body: some View {
            NavigationStack {
                Group {
                    if let host {
                        GatewayAccountDeletionView(host: host, isPreview: true)
                    } else if failed {
                        ContentUnavailableView("Podgląd niedostępny", systemImage: "exclamationmark.triangle")
                    } else {
                        ProgressView("Przygotowanie podglądu…")
                    }
                }
            }
            .task {
                guard host == nil, !failed else { return }
                do {
                    host = try GatewayDeletionPreviewFixture.make(mode: mode)
                    print("ECHOES_GATEWAY_DELETION_UI_PREVIEW state=" + mode)
                } catch { failed = true }
            }
        }
    }

    @MainActor enum GatewayDeletionPreviewFixture {
        static func make(mode: String) throws -> GatewayDeletionHost {
            guard ["pending", "completed", "recovery"].contains(mode) else {
                throw GatewayFailure.configuration
            }
            let config = try CloudKitConfiguration(
                containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
            let binding = try GatewayIdentityBinding(
                appleUserID: "synthetic-UI-apple", cloudKitRecordName: "synthetic-UI-cloud")
            let ticket = try GatewayDeletionTicket.create()
            let api = PreviewDeletionAPI(ticket: ticket, completed: mode == "completed")
            let storage = PreviewDeletionStorage()
            let entry: [String: Any] = [
                "journalID": UUID().uuidString.lowercased(), "attemptID": UUID().uuidString.lowercased(),
                "binding": try JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)),
                "phase": mode == "recovery" ? "recoveryPending" : "accepted",
                "ticket": try JSONSerialization.jsonObject(with: JSONEncoder().encode(ticket)),
                "accountID": PreviewDeletionAPI.accountID,
                "status": api.statusFields(), "contentDeleted": mode == "completed",
                "localDataDeleted": mode == "completed", "ownAcknowledgement": mode == "completed",
            ]
            storage.value = try JSONSerialization.data(withJSONObject: [
                "version": 1, "origin": api.origin,
                "container": config.containerIdentifier, "environment": config.environment.rawValue,
                "requests": [entry],
            ])
            let account = CloudKitAccountSession(source: PreviewDeletionAccount())
            let privateModel = NativePrivateProfileDatabase(
                account: account, transport: PreviewDeletionZone(),
                authorizeWrite: { _ in throw PrivateDataFailure.accountDeleted })
            return GatewayDeletionHost(
                api: api, cloudKitAccount: account, apple: PreviewDeletionApple(),
                authorizer: PreviewDeletionAuthorizer(), currentAuthentication: { nil },
                resumeBindings: { name in
                    try GatewayDeletionController.resumeBindings(
                        configuration: config, origin: api.origin, storage: storage, cloudKitRecordName: name)
                },
                makeController: { binding in
                    GatewayDeletionController(
                        configuration: config, binding: binding, api: api, storage: storage,
                        account: account, cleanup: privateModel, isEnabled: { true },
                        fenceLocalAccess: { _, _ in
                            // Synthetic fixture has no session.
                        },
                        clearLocalData: { _ in
                            // Synthetic fixture has no files.
                        })
                }, isEnabled: { true }, notificationCenter: NotificationCenter())
        }
    }
    private final class PreviewDeletionStorage: GatewayDeletionStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Data?
        var value: Data? {
            get { lock.withLock { bytes } }
            set { lock.withLock { bytes = newValue } }
        }
        func read() throws -> Data? { value }
        func write(_ value: Data) throws { self.value = value }
    }
    @MainActor private final class PreviewDeletionAccount: CloudKitAccountSource {
        func availability() async throws -> CloudKitAccountAvailability { .available }
        func userRecordName() async throws -> String { "synthetic-UI-cloud" }
    }
    @MainActor private final class PreviewDeletionApple: AppleGatewayIdentitySource {
        func credentialState(userID: String) async throws -> AppleGatewayCredentialState { .revoked }
    }
    @MainActor private final class PreviewDeletionAuthorizer: AppleGatewayAuthorizer {
        func authorize(challenge: GatewayChallenge) async throws -> AppleGatewayProof {
            throw GatewayFailure.configuration
        }
        func cancel() {}
    }
    @MainActor private final class PreviewDeletionAPI: GatewayAccountDeletionAPI {
        nonisolated let origin = "https://ui-preview.example.invalid"
        static let accountID = "90000000-0000-4000-8000-000000000009"
        let ticket: GatewayDeletionTicket
        var completed: Bool
        init(ticket: GatewayDeletionTicket, completed: Bool) {
            self.ticket = ticket
            self.completed = completed
        }
        func statusFields() -> [String: Any] {
            [
                "protocolVersion": 1, "deletionID": ticket.deletionID, "accountID": Self.accountID,
                "publicData": completed ? "deleted" : "pending",
                "privateData": completed ? "device-acknowledged" : "awaiting-device",
                "appleAuthorization": completed ? "manual-required" : "pending",
                "localAccount": completed ? "removed" : "blocked",
                "attentionRequired": false, "completed": completed,
            ]
        }
        func deletionChallenge(recovering: Bool) async throws -> GatewayChallenge {
            try JSONDecoder().decode(
                GatewayChallenge.self,
                from: JSONSerialization.data(withJSONObject: [
                    "protocolVersion": 1,
                    "challengeID": UUID().uuidString.lowercased(), "nonce": String(repeating: "A", count: 43),
                    "expiresAt": Int(Date().timeIntervalSince1970) + 300,
                ]))
        }
        func requestDeletion(ticket: GatewayDeletionTicket, proof: GatewayDeletionProof?) async throws
            -> GatewayDeletionStatus
        { throw GatewayFailure.configuration }
        func recoverDeletion(proof: GatewayDeletionProof) async throws -> GatewayRecoveredDeletion {
            throw GatewayFailure.configuration
        }
        func deletionStatus(ticket: GatewayDeletionTicket) async throws -> GatewayDeletionStatus {
            guard ticket == self.ticket else { throw GatewayFailure.invalidInput }
            return try JSONDecoder().decode(
                GatewayDeletionStatus.self, from: JSONSerialization.data(withJSONObject: statusFields()))
        }
        func acknowledgePrivateCleanup(ticket: GatewayDeletionTicket) async throws -> GatewayDeletionStatus {
            guard ticket == self.ticket else { throw GatewayFailure.invalidInput }
            completed = true
            return try await deletionStatus(ticket: ticket)
        }
    }
    @MainActor private final class PreviewDeletionZone: PrivateZoneTransport {
        private var records: [CKRecord.ID: CKRecord] = [:]
        func ensureAtomicZone(scope: PrivateAccountScope) async throws {}
        func fetch(_ id: CKRecord.ID, scope: PrivateAccountScope, metadataOnly: Bool) async throws
            -> CKRecord?
        { records[id]?.copy() as? CKRecord }
        func modify(saving: [CKRecord], deleting: [CKRecord.ID], scope: PrivateAccountScope) async throws
            -> [CKRecord.ID: CKRecord]
        {
            var result: [CKRecord.ID: CKRecord] = [:]
            for record in saving {
                records[record.recordID] = record.copy() as? CKRecord
                result[record.recordID] = record.copy() as? CKRecord
            }
            for id in deleting { records.removeValue(forKey: id) }
            return result
        }
        func changes(scope: PrivateAccountScope, token: Data?) async throws -> PrivateZonePage {
            .init(changedIDs: [], token: Data("UI-only-token".utf8), moreComing: false)
        }
    }
#endif
