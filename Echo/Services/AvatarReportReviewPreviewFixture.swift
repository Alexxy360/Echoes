#if DEBUG
    import CryptoKit
    import EchoesCloudKit
    import Foundation
    import Observation

    /// Synthetic metadata only, isolated per UI run. Production uses its separate Keychain adapter.
    struct AvatarReportReviewPreviewStorage: GatewayAvatarReportReviewJournalStorage {
        nonisolated let root: URL
        nonisolated private func file(_ scope: GatewayAvatarReportReviewScope) -> URL {
            root.appendingPathComponent(scope.ownerStorageIdentifier).appendingPathComponent(
                scope.storageIdentifier + ".json")
        }
        nonisolated func read(scope: GatewayAvatarReportReviewScope) throws -> Data? {
            let path = file(scope)
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            let data = try Data(contentsOf: path)
            guard data.count <= 4096 else { throw GatewayAvatarReportReviewJournalFailure.unavailable }
            return data
        }
        nonisolated func write(_ data: Data, scope: GatewayAvatarReportReviewScope) throws {
            guard data.count <= 4096 else { throw GatewayAvatarReportReviewJournalFailure.unavailable }
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
    @MainActor @Observable final class AvatarReportReviewPreviewStats {
        var decisions = 0
        var retirements = 0
    }

    /// All HTTP replies are local wire fixtures. No URLSession/CloudKit/credentials are used.
    actor AvatarReportReviewPreviewTransport: GatewayAvatarReportReviewTransport {
        nonisolated let origin = "https://avatar-report-review-preview.example.invalid"
        private let root: URL, mode: String, stats: AvatarReportReviewPreviewStats
        private let bytes: Data, manifest: AvatarManifest
        private var createdAt = Int(Date().timeIntervalSince1970 * 1000) - 5000
        private var decisions = 0, applied: [String: [String: String]] = [:]
        private var retirements = 0, retired: [String: [String: String]] = [:]
        private var loaded = false, released = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        init(
            root: URL, mode: String, stats: AvatarReportReviewPreviewStats, bytes: Data,
            manifest: AvatarManifest
        ) {
            self.bytes = bytes
            self.manifest = manifest
            self.root = root
            self.mode = mode
            self.stats = stats
        }
        private func report(_ index: Int) -> String {
            "community-v1-avatarreport-" + String(format: "%064x", index)
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
                else { throw GatewayAvatarReportReviewFailure.invalidResponse }
                createdAt = date
                decisions = count
                applied = entries
                let fences = value["retired"] as? [String: [String: String]] ?? [:]
                let requests = value["retirements"] as? Int ?? 0
                guard fences.count <= 41, requests >= 0, requests <= 100 else {
                    throw GatewayAvatarReportReviewFailure.invalidResponse
                }
                retired = fences
                retirements = requests
            }
            loaded = true
            await publishStats()
        }
        private func save() throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "createdAt": createdAt, "decisions": decisions, "applied": applied, "retired": retired,
                "retirements": retirements,
            ])
            guard data.count <= 32768 else { throw GatewayAvatarReportReviewFailure.invalidResponse }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(
                to: root.appendingPathComponent("provider.json"), options: [.atomic, .completeFileProtection])
        }
        private func publishStats() async {
            let count = decisions
            let closed = retirements
            await MainActor.run {
                stats.decisions = count
                stats.retirements = closed
            }
        }
        func release() {
            released = true
            let old = waiting
            waiting = []
            for item in old { item.resume() }
        }
        private func json(_ fields: [String: Any], status: Int = 200) throws
            -> GatewayAvatarReportReviewHTTPResponse
        {
            .init(
                status: status,
                headers: [
                    "Content-Type": "application/json", "Cache-Control": "no-store", "Pragma": "no-cache",
                    "X-Content-Type-Options": "nosniff",
                ], body: try JSONSerialization.data(withJSONObject: fields))
        }
        func send(_ request: URLRequest, operation: GatewayAvatarReportReviewOperation) async throws
            -> GatewayAvatarReportReviewHTTPResponse
        {
            try await restore()
            if mode == "denied" {
                return try json(["protocolVersion": 1, "error": "AVATAR_REPORT_REVIEW_SCOPE"], status: 403)
            }
            if mode == "unavailable" {
                return try json(
                    ["protocolVersion": 1, "error": "AVATAR_REPORT_REVIEW_UNAVAILABLE"], status: 503)
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
                let photo: Any =
                    mode == "missing"
                    ? NSNull()
                    : [
                        "ownerID": manifest.reference.ownerID, "versionID": manifest.reference.versionID,
                        "publicationGeneration": 1,
                        "manifest": [
                            "schemaVersion": 1, "ownerID": manifest.reference.ownerID,
                            "versionID": manifest.reference.versionID, "variant": "image",
                            "byteCount": manifest.byteCount, "width": manifest.width,
                            "height": manifest.height, "sha256": manifest.sha256,
                        ] as [String: Any],
                    ] as [String: Any]
                let metadata = try JSONSerialization.data(withJSONObject: [
                    "protocolVersion": 1, "schemaVersion": 1,
                    "inspectionID": UUID().uuidString.lowercased(),
                    "inspectionExpiresAt": Int(Date().timeIntervalSince1970 * 1000)
                        + (mode == "expiry" ? 12_000 : 90_000),
                    "contentHash": digest("synthetic-photo-material/" + item.reportID),
                    "reportID": item.reportID, "createdAt": item.createdAtMilliseconds,
                    "expiresAt": item.expiresAtMilliseconds, "reason": reason, "photo": photo,
                ])
                guard (1...12288).contains(metadata.count) else {
                    throw GatewayAvatarReportReviewFailure.invalidResponse
                }
                let n = metadata.count
                var frame = Data([
                    UInt8((n >> 24) & 255), UInt8((n >> 16) & 255),
                    UInt8((n >> 8) & 255), UInt8(n & 255),
                ])
                frame.append(metadata)
                if mode != "missing" { frame.append(bytes) }
                if mode == "damaged", frame.count > 4 + n + 2 { frame[frame.count - 3] ^= 1 }
                let reply = GatewayAvatarReportReviewHTTPResponse(
                    status: 200,
                    headers: [
                        "Content-Type": "application/vnd.echoes.avatar-report-inspection.v1",
                        "Cache-Control": "private, no-store", "Pragma": "no-cache",
                        "X-Content-Type-Options": "nosniff", "Content-Length": String(frame.count),
                    ],
                    body: frame)
                if mode == "delayed", !released { await withCheckedContinuation { waiting.append($0) } }
                return reply
            case .decide(let intent):
                let id = intent.receipt.item.reportID
                if retired[intent.decisionID] != nil {
                    return try json(
                        ["protocolVersion": 1, "error": "AVATAR_REPORT_REVIEW_STALE"], status: 409)
                }
                decisions += 1
                if !["not-applied", "superseded", "retire-lost"].contains(mode) {
                    applied[id] = [
                        "id": intent.decisionID, "verdict": intent.verdict.rawValue,
                        "hash": intent.receipt.contentHash, "revision": UUID().uuidString.lowercased(),
                    ]
                }
                try save()
                await publishStats()
                if ["lost", "not-applied", "superseded", "retire-lost"].contains(mode) {
                    throw GatewayAvatarReportReviewFailure.unavailable
                }
                return try json([
                    "protocolVersion": 1, "schemaVersion": 1, "reportID": id,
                    "inspectionID": intent.receipt.inspectionID, "decisionID": intent.decisionID,
                    "verdict": intent.verdict.rawValue, "contentHash": intent.receipt.contentHash,
                    "revision": applied[id]!["revision"]!,
                ])
            case .recover(let intent), .retire(let intent):
                let entry = applied[intent.reportID]
                let confirmed =
                    entry?["id"] == intent.decisionID && entry?["verdict"] == intent.verdict.rawValue
                    && entry?["hash"] == intent.contentHash
                let closing: Bool
                if case .retire = operation { closing = true } else { closing = false }
                let freshFence = retired[intent.decisionID] == nil
                if closing {
                    retirements += 1
                    if !confirmed && mode != "superseded" {
                        retired[intent.decisionID] = [
                            "reportID": intent.reportID, "verdict": intent.verdict.rawValue,
                            "hash": intent.contentHash,
                        ]
                    }
                    try save()
                    await publishStats()
                    if mode == "retire-lost" && freshFence {
                        throw GatewayAvatarReportReviewFailure.unavailable
                    }
                }
                let fence = retired[intent.decisionID]
                let sealed =
                    fence?["reportID"] == intent.reportID && fence?["verdict"] == intent.verdict.rawValue
                    && fence?["hash"] == intent.contentHash
                return try json([
                    "protocolVersion": 1, "schemaVersion": 1, "reportID": intent.reportID,
                    "decisionID": intent.decisionID, "verdict": intent.verdict.rawValue,
                    "contentHash": intent.contentHash,
                    "outcome": confirmed
                        ? "confirmed"
                        : sealed ? "retired" : mode == "superseded" ? "superseded" : "not-applied",
                    "revision": confirmed ? entry!["revision"]! : NSNull(),
                ])
            }
        }
    }
    @MainActor final class AvatarReportReviewPreviewFixture {
        let source: AvatarReviewPreviewSource, stats: AvatarReportReviewPreviewStats
        let transport: AvatarReportReviewPreviewTransport
        let host: GatewayAvatarReportReviewHost
        init(mode: String, root: URL, bytes: Data, manifest: AvatarManifest) throws {
            source = try .init()
            stats = .init()
            transport = .init(root: root, mode: mode, stats: stats, bytes: bytes, manifest: manifest)
            let config = try GatewayConfiguration(origin: URL(string: transport.origin)!)
            host = try .init(
                api: GatewayAvatarReportReviewHTTPClient(
                    configuration: config, transport: transport, isEnabled: { true }),
                configuration: config,
                cloudKit: .init(containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development),
                authorization: source,
                journal: GatewayAvatarReportReviewJournal(
                    storage: AvatarReportReviewPreviewStorage(root: root)),
                isEnabled: { true })
        }
        static func make(mode: String, runID: String) async throws -> AvatarReportReviewPreviewFixture {
            guard UUID(uuidString: runID)?.uuidString.lowercased() == runID,
                [
                    "normal", "long", "lost", "not-applied", "superseded", "expiry", "delayed", "denied",
                    "empty", "missing", "pages", "unavailable", "retire-lost", "damaged",
                ].contains(mode)
            else { throw GatewayFailure.invalidInput }
            let api = CommunityAvatarPreviewAPI.make(mode: "normal")
            let query = try GatewayAvatarQuery(
                reference: .init(
                    ownerID: CommunityAvatarPreviewData.ownerA,
                    versionID: CommunityAvatarPreviewData.version), variant: .image)
            guard
                case .downloaded(let manifest, let bytes) = try await api.read(
                    query, token: GatewaySecret("synthetic-preview"))
            else { throw GatewayAvatarReportReviewFailure.invalidResponse }
            let cache = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let value = try AvatarReportReviewPreviewFixture(
                mode: mode,
                root: cache.appendingPathComponent("EchoesAvatarReportReviewUIPreview")
                    .appendingPathComponent(
                        runID), bytes: bytes, manifest: manifest)
            try await value.transport.restore()
            return value
        }
    }
#endif
