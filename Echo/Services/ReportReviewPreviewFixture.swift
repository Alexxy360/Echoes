#if DEBUG
    import CryptoKit
    import EchoesCloudKit
    import Foundation
    import Observation

    /// Synthetic metadata only, isolated per UI run. Production uses its separate Keychain adapter.
    struct ReportReviewPreviewStorage: GatewayReportReviewJournalStorage {
        nonisolated let root: URL
        nonisolated private func file(_ scope: GatewayReportReviewScope) -> URL {
            root.appendingPathComponent(scope.ownerStorageIdentifier).appendingPathComponent(
                scope.storageIdentifier + ".json")
        }
        nonisolated func read(scope: GatewayReportReviewScope) throws -> Data? {
            let path = file(scope)
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            let data = try Data(contentsOf: path)
            guard data.count <= 4096 else { throw GatewayReportReviewJournalFailure.unavailable }
            return data
        }
        nonisolated func write(_ data: Data, scope: GatewayReportReviewScope) throws {
            guard data.count <= 4096 else { throw GatewayReportReviewJournalFailure.unavailable }
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
    @MainActor @Observable final class ReportReviewPreviewStats { var decisions = 0 }

    /// All HTTP replies are local wire fixtures. No URLSession/CloudKit/credentials are used.
    actor ReportReviewPreviewTransport: GatewayReportReviewTransport {
        nonisolated let origin = "https://report-review-preview.example.invalid"
        private let root: URL, mode: String, stats: ReportReviewPreviewStats
        private var createdAt = Int(Date().timeIntervalSince1970 * 1000) - 5000
        private var decisions = 0, applied: [String: [String: String]] = [:]
        private var loaded = false, released = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        init(root: URL, mode: String, stats: ReportReviewPreviewStats) {
            self.root = root
            self.mode = mode
            self.stats = stats
        }
        private func report(_ index: Int) -> String {
            "community-v1-report-" + String(format: "%064x", index)
        }
        private func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        func restore() async throws {
            guard !loaded else { return }
            let path = root.appendingPathComponent("provider.json")
            if FileManager.default.fileExists(atPath: path.path) {
                let bytes = try Data(contentsOf: path)
                guard bytes.count <= 32768,
                    let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                    let date = value["createdAt"] as? Int, let count = value["decisions"] as? Int,
                    let entries = value["applied"] as? [String: [String: String]], count >= 0, count <= 100,
                    entries.count <= 41
                else { throw GatewayReportReviewFailure.invalidResponse }
                createdAt = date
                decisions = count
                applied = entries
            }
            loaded = true
            await publishStats()
        }
        private func save() throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "createdAt": createdAt, "decisions": decisions, "applied": applied,
            ])
            guard data.count <= 32768 else { throw GatewayReportReviewFailure.invalidResponse }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(
                to: root.appendingPathComponent("provider.json"), options: [.atomic, .completeFileProtection])
        }
        private func publishStats() async {
            let count = decisions
            await MainActor.run { stats.decisions = count }
        }
        func release() {
            released = true
            let old = waiting
            waiting = []
            for item in old { item.resume() }
        }
        private func json(_ fields: [String: Any], status: Int = 200) throws
            -> GatewayReportReviewHTTPResponse
        {
            .init(
                status: status,
                headers: [
                    "Content-Type": "application/json", "Cache-Control": "no-store", "Pragma": "no-cache",
                    "X-Content-Type-Options": "nosniff",
                ], body: try JSONSerialization.data(withJSONObject: fields))
        }
        func send(_ request: URLRequest, operation: GatewayReportReviewOperation) async throws
            -> GatewayReportReviewHTTPResponse
        {
            try await restore()
            if mode == "denied" {
                return try json(["protocolVersion": 1, "error": "REPORT_REVIEW_SCOPE"], status: 403)
            }
            if mode == "unavailable" {
                return try json(["protocolVersion": 1, "error": "REPORT_REVIEW_UNAVAILABLE"], status: 503)
            }
            switch operation {
            case .queue(let after):
                let indices: [Int]
                let next: Any
                if mode == "empty" {
                    indices = []
                    next = NSNull()
                } else if mode == "pages" {
                    if after == nil {
                        indices = Array(1...20)
                        next = report(20)
                    } else if after?.value == report(20) {
                        indices = []
                        next = report(40)
                    } else {
                        indices = [41]
                        next = NSNull()
                    }
                } else {
                    indices = applied[report(1)] == nil ? [1] : []
                    next = NSNull()
                }
                return try json([
                    "protocolVersion": 1, "schemaVersion": 1,
                    "items": indices.map {
                        [
                            "reportID": report($0), "createdAt": createdAt,
                            "expiresAt": createdAt + 2_592_000_000,
                        ] as [String: Any]
                    }, "after": next,
                ])
            case .inspect(let item):
                let long = mode == "long"
                let reason =
                    long
                    ? String(
                        String(repeating: "Powód zgłoszenia wymaga uważnego sprawdzenia. ", count: 12).prefix(
                            499)
                    ) + "!"
                    : "Treść może naruszać zasady społeczności."
                let text =
                    long
                    ? String(
                        String(
                            repeating: "To syntetyczna wiadomość do oceny w długim zgłoszeniu. ", count: 12
                        ).prefix(499)
                    ) + "!"
                    : "Syntetyczna wiadomość przeznaczona wyłącznie do testowania moderacji."
                let message: Any =
                    mode == "missing"
                    ? NSNull()
                    : [
                        "authorID": "6d000000-0000-4000-8000-000000000001", "name": "Autor testowy",
                        "text": text, "createdAt": createdAt, "expiresAt": createdAt + 7_200_000,
                    ]
                let reply = try json([
                    "protocolVersion": 1, "schemaVersion": 1, "inspectionID": UUID().uuidString.lowercased(),
                    "inspectionExpiresAt": Int(Date().timeIntervalSince1970 * 1000)
                        + (mode == "expiry" ? 12_000 : 90_000),
                    "contentHash": digest("synthetic-material/" + item.reportID), "reportID": item.reportID,
                    "createdAt": item.createdAtMilliseconds, "expiresAt": item.expiresAtMilliseconds,
                    "reason": reason,
                    "messageID": "community-v1-message-" + String(repeating: "a", count: 64),
                    "message": message,
                ])
                if mode == "delayed", !released { await withCheckedContinuation { waiting.append($0) } }
                return reply
            case .decide(let intent):
                let id = intent.receipt.item.reportID
                decisions += 1
                if !["not-applied", "superseded"].contains(mode) {
                    applied[id] = [
                        "id": intent.decisionID, "verdict": intent.verdict.rawValue,
                        "hash": intent.receipt.contentHash, "revision": UUID().uuidString.lowercased(),
                    ]
                }
                try save()
                await publishStats()
                if ["lost", "not-applied", "superseded"].contains(mode) {
                    throw GatewayReportReviewFailure.unavailable
                }
                return try json([
                    "protocolVersion": 1, "schemaVersion": 1, "reportID": id,
                    "inspectionID": intent.receipt.inspectionID, "decisionID": intent.decisionID,
                    "verdict": intent.verdict.rawValue, "contentHash": intent.receipt.contentHash,
                    "revision": applied[id]!["revision"]!,
                ])
            case .recover(let intent):
                let entry = applied[intent.reportID]
                let confirmed =
                    entry?["id"] == intent.decisionID && entry?["verdict"] == intent.verdict.rawValue
                    && entry?["hash"] == intent.contentHash
                return try json([
                    "protocolVersion": 1, "schemaVersion": 1, "reportID": intent.reportID,
                    "decisionID": intent.decisionID, "verdict": intent.verdict.rawValue,
                    "contentHash": intent.contentHash,
                    "outcome": confirmed ? "confirmed" : mode == "superseded" ? "superseded" : "not-applied",
                    "revision": confirmed ? entry!["revision"]! : NSNull(),
                ])
            }
        }
    }
    @MainActor final class ReportReviewPreviewFixture {
        let source: AvatarReviewPreviewSource, stats: ReportReviewPreviewStats
        let transport: ReportReviewPreviewTransport
        let host: GatewayReportReviewHost
        init(mode: String, root: URL) throws {
            source = try .init()
            stats = .init()
            transport = .init(root: root, mode: mode, stats: stats)
            let config = try GatewayConfiguration(origin: URL(string: transport.origin)!)
            host = try .init(
                api: GatewayReportReviewHTTPClient(
                    configuration: config, transport: transport, isEnabled: { true }),
                configuration: config,
                cloudKit: .init(containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development),
                authorization: source,
                journal: GatewayReportReviewJournal(storage: ReportReviewPreviewStorage(root: root)),
                isEnabled: { true })
        }
        static func make(mode: String, runID: String) async throws -> ReportReviewPreviewFixture {
            guard UUID(uuidString: runID)?.uuidString.lowercased() == runID,
                [
                    "normal", "long", "lost", "not-applied", "superseded", "expiry", "delayed", "denied",
                    "empty", "missing", "pages", "unavailable",
                ].contains(mode)
            else { throw GatewayFailure.invalidInput }
            let cache = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let value = try ReportReviewPreviewFixture(
                mode: mode,
                root: cache.appendingPathComponent("EchoesReportReviewUIPreview").appendingPathComponent(
                    runID))
            try await value.transport.restore()
            return value
        }
    }
#endif
