#if DEBUG
    import CryptoKit
    import EchoesCloudKit
    import Foundation
    import Observation

    /// A synthetic disk-backed provider for process-restart UI tests. Never Keychain or a network.
    struct AvatarReviewPreviewStorage: GatewayAvatarReviewJournalStorage {
        nonisolated let root: URL
        nonisolated private func file(_ scope: GatewayAvatarReviewScope) throws -> URL {
            root.appendingPathComponent(scope.ownerStorageIdentifier)
                .appendingPathComponent(scope.storageIdentifier + ".json")
        }
        nonisolated func read(scope: GatewayAvatarReviewScope) throws -> Data? {
            let path = try file(scope)
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            let data = try Data(contentsOf: path)
            guard data.count <= 4096 else { throw GatewayAvatarReviewJournalFailure.unavailable }
            return data
        }
        nonisolated func write(_ data: Data, scope: GatewayAvatarReviewScope) throws {
            guard data.count <= 4096 else { throw GatewayAvatarReviewJournalFailure.unavailable }
            let path = try file(scope)
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
    @MainActor @Observable final class AvatarReviewPreviewSource: GatewayAvatarAuthorizationSource {
        var communityAuthorization: GatewayCommunityAuthorization?
        private var second = false
        private(set) var rejections = 0
        init() throws { try select() }
        func changeAccount() throws {
            second.toggle()
            try select()
        }
        private func select() throws {
            communityAuthorization = try .init(
                accountID: second
                    ? "6e000000-0000-4000-8000-000000000002" : "6e000000-0000-4000-8000-000000000001",
                binding: .init(
                    appleUserID: second ? "synthetic-review-B" : "synthetic-review-A",
                    cloudKitRecordName: second ? "synthetic-review-cloud-B" : "synthetic-review-cloud-A"),
                revision: UUID())
        }
        func privateDataScope(configuration: CloudKitConfiguration) -> PrivateAccountScope? {
            guard let communityAuthorization else { return nil }
            return try? .init(
                configuration: configuration, accountID: communityAuthorization.identity.accountID,
                cloudKitRecordName: second ? "synthetic-review-cloud-B" : "synthetic-review-cloud-A")
        }
        func communityAccessToken(for expected: GatewayCommunityAuthorization) async throws -> GatewaySecret {
            guard expected == communityAuthorization else { throw GatewayFailure.signInRequired }
            return try .init(expected.identity.accountID + "." + String(repeating: "a", count: 43))
        }
        func rejectCommunityAccess(for expected: GatewayCommunityAuthorization) async {
            if expected == communityAuthorization {
                rejections += 1
                communityAuthorization = nil
            }
        }
    }
    @MainActor @Observable final class AvatarReviewPreviewStats {
        var decisions = 0
        var retirements = 0
    }
    actor AvatarReviewPreviewTransport: GatewayAvatarReviewTransport {
        nonisolated let origin = "https://avatar-review-preview.example.invalid"
        private let bytes: Data, root: URL, mode: String
        private let stats: AvatarReviewPreviewStats
        private var decisions = 0, retirements = 0
        private var retired: [String: String] = [:]
        private var appliedID: String?, appliedRevision: String?, appliedVerdict: String?
        private var loaded = false, released = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private let account = "6d000000-0000-4000-8000-000000000001"
        private let requestID = "6d000000-0000-4000-8000-000000000002"
        private let version = "6d000000-0000-4000-8000-000000000003"
        private let reviewRevision = "6d000000-0000-4000-8000-000000000004"
        init(bytes: Data, root: URL, mode: String, stats: AvatarReviewPreviewStats) {
            self.bytes = bytes
            self.root = root
            self.mode = mode
            self.stats = stats
        }
        func restore() async throws {
            guard !loaded else { return }
            let path = root.appendingPathComponent("server.json")
            if FileManager.default.fileExists(atPath: path.path) {
                let data = try Data(contentsOf: path)
                guard data.count <= 2048,
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { throw GatewayAvatarReviewFailure.invalidResponse }
                decisions = object["decisions"] as? Int ?? 0
                appliedID = object["id"] as? String
                appliedRevision = object["revision"] as? String
                appliedVerdict = object["verdict"] as? String
                retired = object["retired"] as? [String: String] ?? [:]
                retirements = object["retirements"] as? Int ?? 0
                guard decisions >= 0, decisions <= 100, retirements >= 0, retirements <= 100,
                    retired.count <= 32
                else { throw GatewayAvatarReviewFailure.invalidResponse }
            }
            loaded = true
            await publishStats()
        }
        private func save() throws {
            var object: [String: Any] = [
                "decisions": decisions, "retired": retired, "retirements": retirements,
            ]
            object["id"] = appliedID
            object["revision"] = appliedRevision
            object["verdict"] = appliedVerdict
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(
                to: root.appendingPathComponent("server.json"), options: [.atomic, .completeFileProtection])
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
        private func json(_ object: [String: Any], status: Int = 200) throws -> GatewayAvatarHTTPResponse {
            .init(
                status: status,
                headers: [
                    "Content-Type": "application/json", "Cache-Control": "no-store", "Pragma": "no-cache",
                    "X-Content-Type-Options": "nosniff",
                ],
                body: try JSONSerialization.data(withJSONObject: object))
        }
        func send(_ request: URLRequest, operation: GatewayAvatarReviewOperation) async throws
            -> GatewayAvatarHTTPResponse
        {
            try await restore()
            if mode == "denied" {
                return try json(["protocolVersion": 1, "error": "AVATAR_REVIEW_SCOPE"], status: 403)
            }
            switch operation {
            case .queue:
                let item: [String: Any] = [
                    "accountID": account, "requestID": requestID, "versionID": version, "generation": 1,
                    "reviewRevision": reviewRevision,
                ]
                return try json([
                    "protocolVersion": 1, "schemaVersion": 1,
                    "items": mode == "empty" || appliedID != nil ? [] : [item],
                ])
            case .inspect:
                let expires = Int(Date().timeIntervalSince1970 * 1000) + (mode == "expiry" ? 12_000 : 90_000)
                let manifest: [String: Any] = [
                    "schemaVersion": 1, "ownerID": account, "versionID": version, "variant": "image",
                    "byteCount": bytes.count, "width": 512, "height": 512,
                    "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                ]
                let proof: [String: Any] = [
                    "schemaVersion": 1, "inspectionID": UUID().uuidString.lowercased(), "expiresAt": expires,
                    "requestID": requestID, "generation": 1, "reviewRevision": reviewRevision,
                ]
                let reply = GatewayAvatarHTTPResponse(
                    status: 200,
                    headers: [
                        "Content-Type": "image/jpeg", "Content-Length": String(bytes.count),
                        "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff",
                        "X-Echoes-Avatar-Manifest": String(
                            data: try JSONSerialization.data(withJSONObject: manifest), encoding: .utf8)!,
                        "X-Echoes-Avatar-Review": String(
                            data: try JSONSerialization.data(withJSONObject: proof), encoding: .utf8)!,
                    ], body: bytes)
                if mode == "delayed", !released { await withCheckedContinuation { waiting.append($0) } }
                return reply
            case .decide(let intent):
                if retired[intent.decisionID] != nil {
                    return try json(["protocolVersion": 1, "error": "AVATAR_REVIEW_STALE"], status: 409)
                }
                decisions += 1
                if !["not-applied", "superseded", "retire-lost"].contains(mode) {
                    appliedID = intent.decisionID
                    appliedRevision = UUID().uuidString.lowercased()
                    appliedVerdict = intent.verdict.rawValue
                }
                try save()
                await publishStats()
                if ["lost", "not-applied", "superseded", "retire-lost"].contains(mode) {
                    throw GatewayAvatarReviewFailure.unavailable
                }
                return try json([
                    "protocolVersion": 1, "schemaVersion": 1, "inspectionID": intent.receipt.inspectionID,
                    "accountID": account, "requestID": requestID,
                    "decisionID": intent.decisionID, "revision": appliedRevision!,
                    "verdict": intent.verdict.rawValue,
                ])
            case .recover(let intent), .retire(let intent):
                let confirmed = appliedID == intent.decisionID && appliedVerdict == intent.verdict.rawValue
                let closing: Bool
                if case .retire = operation { closing = true } else { closing = false }
                let intentHash = SHA256.hash(data: request.httpBody ?? Data()).map {
                    String(format: "%02x", $0)
                }.joined()
                let fresh = retired[intent.decisionID] == nil
                if let old = retired[intent.decisionID], old != intentHash {
                    return try json(["protocolVersion": 1, "error": "AVATAR_REVIEW_STALE"], status: 409)
                }
                if closing {
                    retirements += 1
                    if !confirmed && mode != "superseded" {
                        retired[intent.decisionID] = intentHash
                    }
                    try save()
                    await publishStats()
                    if mode == "retire-lost" && fresh { throw GatewayAvatarReviewFailure.unavailable }
                }
                let sealed = retired[intent.decisionID] == intentHash
                return try json([
                    "protocolVersion": 1, "schemaVersion": 1, "accountID": intent.item.accountID,
                    "requestID": intent.item.requestID, "versionID": intent.item.versionID,
                    "generation": intent.item.generation, "reviewRevision": intent.item.reviewRevision,
                    "decisionID": intent.decisionID, "verdict": intent.verdict.rawValue,
                    "outcome": confirmed
                        ? "confirmed"
                        : sealed ? "retired" : mode == "superseded" ? "superseded" : "not-applied",
                    "revision": confirmed ? appliedRevision! : NSNull(),
                ])
            }
        }
    }
    @MainActor final class AvatarReviewPreviewFixture {
        let source: AvatarReviewPreviewSource, stats: AvatarReviewPreviewStats
        let transport: AvatarReviewPreviewTransport
        let host: GatewayAvatarReviewHost
        init(mode: String, root: URL, bytes: Data) throws {
            source = try .init()
            stats = .init()
            transport = .init(bytes: bytes, root: root, mode: mode, stats: stats)
            let config = try GatewayConfiguration(origin: URL(string: transport.origin)!)
            host = try .init(
                api: GatewayAvatarReviewHTTPClient(
                    configuration: config, transport: transport, isEnabled: { true }),
                configuration: config,
                cloudKit: .init(containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development),
                authorization: source,
                journal: GatewayAvatarReviewJournal(storage: AvatarReviewPreviewStorage(root: root)),
                isEnabled: { true })
        }
        static func make(mode: String, runID: String) async throws -> AvatarReviewPreviewFixture {
            guard UUID(uuidString: runID)?.uuidString.lowercased() == runID,
                [
                    "normal", "lost", "not-applied", "superseded", "expiry", "delayed", "denied", "empty",
                    "retire-lost",
                ]
                .contains(mode)
            else { throw GatewayFailure.invalidInput }
            let api = CommunityAvatarPreviewAPI.make(mode: "normal")
            let query = try GatewayAvatarQuery(
                reference: .init(
                    ownerID: CommunityAvatarPreviewData.ownerA, versionID: CommunityAvatarPreviewData.version),
                variant: .image)
            guard
                case .downloaded(_, let bytes) = try await api.read(
                    query, token: GatewaySecret("synthetic-preview"))
            else { throw GatewayAvatarReviewFailure.invalidResponse }
            let cache = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let value = try AvatarReviewPreviewFixture(
                mode: mode,
                root: cache.appendingPathComponent("EchoesAvatarReviewUIPreview").appendingPathComponent(
                    runID), bytes: bytes)
            try await value.transport.restore()
            return value
        }
    }
#endif
