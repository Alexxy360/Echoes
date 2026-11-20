#if DEBUG
    import EchoesCloudKit
    import Foundation
    import Observation

    struct AvatarReportPreviewStorage: GatewayAvatarReportJournalStorage {
        nonisolated let root: URL
        nonisolated private func file(_ scope: GatewayAvatarReportScope) -> URL {
            root.appendingPathComponent(scope.ownerStorageIdentifier).appendingPathComponent(
                scope.storageIdentifier + ".json")
        }
        nonisolated func read(scope: GatewayAvatarReportScope) throws -> Data? {
            let path = file(scope)
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            let value = try Data(contentsOf: path)
            guard value.count <= 4096 else { throw GatewayAvatarReportJournalFailure.unavailable }
            return value
        }
        nonisolated func write(_ data: Data, scope: GatewayAvatarReportScope) throws {
            guard data.count <= 4096 else { throw GatewayAvatarReportJournalFailure.unavailable }
            let path = file(scope)
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path, options: [.atomic, .completeFileProtection])
        }
        nonisolated func erase(owner: PrivateAccountScope) throws {
            let path = root.appendingPathComponent(owner.digest)
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
        }
    }
    @MainActor @Observable final class AvatarReportPreviewStats {
        var submits = 0
        var cancels = 0
        var cleaned = false
    }
    /// Owned synthetic provider metadata only. No credentials, reason, location, image or network.
    actor AvatarReportPreviewTransport: GatewayAvatarReportTransport {
        private let root: URL, mode: String, stats: AvatarReportPreviewStats
        private var records: [String: String] = [:]
        private var submits = 0, cancels = 0
        private var loaded = false
        init(root: URL, mode: String, stats: AvatarReportPreviewStats) {
            self.root = root
            self.mode = mode
            self.stats = stats
        }
        private func restore() throws {
            guard !loaded else { return }
            let path = root.appendingPathComponent("provider.json")
            if FileManager.default.fileExists(atPath: path.path) {
                let bytes = try Data(contentsOf: path)
                guard bytes.count <= 16384,
                    let data = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                    let stored = data["records"] as? [String: String], stored.count <= 20,
                    let sent = data["submits"] as? Int, let cancelled = data["cancels"] as? Int,
                    (0...100).contains(sent), (0...100).contains(cancelled),
                    stored.keys.allSatisfy({ $0.hasPrefix("community-v1-avatarreport-") }),
                    stored.values.allSatisfy({ ["accepted", "cancelled"].contains($0) })
                else { throw GatewayAvatarReportFailure.invalidResponse }
                records = stored
                submits = sent
                cancels = cancelled
            }
            loaded = true
        }
        private func save() throws {
            guard records.count <= 20, submits <= 100, cancels <= 100 else {
                throw GatewayAvatarReportFailure.unavailable
            }
            let bytes = try JSONSerialization.data(withJSONObject: [
                "records": records, "submits": submits, "cancels": cancels,
            ])
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try bytes.write(
                to: root.appendingPathComponent("provider.json"), options: [.atomic, .completeFileProtection])
        }
        func send(_ request: URLRequest, operation: GatewayAvatarReportOperation) async throws
            -> GatewayAvatarReportHTTPResponse
        {
            try restore()
            let identity: GatewayAvatarReportIdentity
            let outcome: String
            switch operation {
            case .submit(let value):
                identity = value.identity
                submits += 1
                if mode != "avatar-report-unknown" { records[identity.reportID] = "accepted" }
                try save()
                let count = submits
                await MainActor.run { stats.submits = count }
                if submits == 1, mode != "avatar-report" { throw GatewayAvatarReportFailure.unavailable }
                outcome = "accepted"
            case .cancel(let value):
                identity = value
                cancels += 1
                records[identity.reportID] = "cancelled"
                try save()
                let count = cancels
                await MainActor.run { stats.cancels = count }
                if mode == "avatar-report-cancel-lost", cancels == 1 {
                    throw GatewayAvatarReportFailure.unavailable
                }
                outcome = "cancelled"
            case .recover(let value):
                identity = value
                outcome = records[identity.reportID] ?? "unconfirmed"
                let sent = submits
                let cancelled = cancels
                await MainActor.run {
                    stats.submits = sent
                    stats.cancels = cancelled
                }
            }
            return .init(
                status: 200,
                headers: [
                    "Content-Type": "application/json", "Cache-Control": "no-store",
                    "X-Content-Type-Options": "nosniff",
                ],
                body: try JSONSerialization.data(withJSONObject: [
                    "protocolVersion": 1, "schemaVersion": 1,
                    "requestID": identity.requestID, "reportID": identity.reportID, "outcome": outcome,
                ]))
        }
    }
    @MainActor final class AvatarReportPreviewFixture {
        let presenter: GatewayAvatarReportPresenter
        let stats = AvatarReportPreviewStats()
        private let root: URL
        init(mode: String, source: any GatewayAvatarAuthorizationSource, cloudKit: CloudKitConfiguration)
            throws
        {
            let rawID =
                ProcessInfo.processInfo.environment["ECHOES_AVATAR_REPORT_UI_RUN_ID"]
                ?? UUID().uuidString.lowercased()
            guard UUID(uuidString: rawID)?.uuidString.lowercased() == rawID else {
                throw GatewayFailure.configuration
            }
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "Echoes-avatar-report-preview-" + rawID)
            let configuration = try GatewayConfiguration(
                origin: URL(string: "https://community-preview.example.invalid")!)
            let transport = AvatarReportPreviewTransport(root: root, mode: mode, stats: stats)
            presenter = GatewayAvatarReportPresenter(
                host: try GatewayAvatarReportHost(
                    api: GatewayAvatarReportHTTPClient(
                        configuration: configuration, transport: transport, isEnabled: { true }),
                    configuration: configuration, cloudKit: cloudKit, authorization: source,
                    journal: .init(storage: AvatarReportPreviewStorage(root: root)), isEnabled: { true },
                    canCancel: { true }))
        }
        func cleanup() throws {
            presenter.invalidate()
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            stats.cleaned = !FileManager.default.fileExists(atPath: root.path)
        }
    }
#endif
