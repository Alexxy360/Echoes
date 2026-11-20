#if DEBUG
    import CloudKit
    import CryptoKit
    import EchoesCloudKit
    import EchoesCore
    import Foundation
    import Observation

    @MainActor @Observable final class CommunityPreviewFixture {
        private let source: CommunityPreviewAuthorization
        let host: GatewayCommunityHost
        let deletion: GatewayDeletionHost
        private let mode: String
        private let api: CommunityPreviewAPI
        private let avatarAPI: CommunityAvatarPreviewAPI?
        private let avatarHost: GatewayCommunityAvatarHost?
        private let ownerPhotos: AvatarEditorPreviewFixture?
        private let reportPhotos: AvatarReportPreviewFixture?
        private let cloud = CommunityPreviewProfileCloud()
        private let profileDatabase = CommunityPreviewProfileDatabase()
        private let profileConfiguration: CloudKitConfiguration
        private let profileAccount: CloudKitAccountSession
        private var configuredProfileFailure = false
        private(set) var services: AppServices?
        private var first = true
        init(mode: String) throws {
            guard
                [
                    "happy", "pending", "profile-onboarding", "profile-offline", "profile-conflict",
                    "profile-unknown", "profile-delayed", "profile-empty",
                    "avatar-report", "avatar-report-lost", "avatar-report-cancel-lost",
                    "avatar-report-unknown",
                    "avatars", "avatars-denied", "avatars-corrupt", "avatars-delayed",
                    "avatar-owner", "avatar-owner-approved", "avatar-owner-lost", "avatar-owner-delayed",
                    "avatar-owner-no-location", "avatar-owner-publish-lost",
                    "avatar-owner-existing-approved", "avatar-owner-existing-pending", "avatar-owner-expired",
                ].contains(mode)
            else { throw GatewayFailure.configuration }
            self.mode = mode
            source = try CommunityPreviewAuthorization()
            api = CommunityPreviewAPI(avatars: mode.hasPrefix("avatars") || mode.hasPrefix("avatar-report"))
            profileConfiguration = try .init(
                containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
            profileAccount = CloudKitAccountSession(source: cloud)
            ownerPhotos =
                mode.hasPrefix("avatar-owner")
                ? try AvatarEditorPreviewFixture(mode: mode, source: source, cloudKit: profileConfiguration)
                : nil
            reportPhotos =
                mode.hasPrefix("avatar-report")
                ? try AvatarReportPreviewFixture(mode: mode, source: source, cloudKit: profileConfiguration)
                : nil
            if mode.hasPrefix("avatars") || mode.hasPrefix("avatar-report") {
                let photoAPI = CommunityAvatarPreviewAPI.make(mode: mode)
                avatarAPI = photoAPI
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "Echoes-avatar-preview-" + UUID().uuidString)
                avatarHost = try GatewayCommunityAvatarHost(
                    api: photoAPI, configuration: .init(origin: URL(string: photoAPI.origin)!),
                    cloudKit: profileConfiguration, authorization: source,
                    cache: GatewayAvatarCache(root: root), isEnabled: { true })
            } else {
                avatarAPI = nil
                avatarHost = ownerPhotos?.avatars
            }
            if ["profile-onboarding", "profile-offline", "profile-delayed"].contains(mode) {
                let scope = try PrivateAccountScope(
                    configuration: profileConfiguration,
                    accountID: CommunityPreviewAPI.ownerA, cloudKitRecordName: cloud.name)
                profileDatabase.seed(scope, name: "Zapisany pseudonim")
                let other = try PrivateAccountScope(
                    configuration: profileConfiguration,
                    accountID: CommunityPreviewAPI.ownerB, cloudKitRecordName: "synthetic-cloud-B")
                profileDatabase.seed(other, name: "Pseudonim konta B")
            }
            profileDatabase.failRead = mode == "profile-offline"
            profileDatabase.holdRead = mode == "profile-delayed"
            host = GatewayCommunityHost(
                api: api, configuration: try .init(origin: URL(string: api.origin)!),
                cloudKit: try .init(containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development),
                authorization: source, storage: CommunityPreviewStorage(), isEnabled: { true })
            deletion = try GatewayDeletionPreviewFixture.make(mode: "pending")
        }
        func open() async {
            do {
                await api.selectOwner(
                    source.isSecond ? CommunityPreviewAPI.ownerB : CommunityPreviewAPI.ownerA)
                await ownerPhotos?.api.selectOwner(
                    source.isSecond ? CommunityPreviewAPI.ownerB : CommunityPreviewAPI.ownerA)
                cloud.name = source.isSecond ? "synthetic-cloud-B" : "synthetic-cloud-A"
                await profileAccount.refresh()
                guard let native = source.communityAuthorization else { throw GatewayFailure.signInRequired }
                let scope = try PrivateAccountScope(
                    configuration: profileConfiguration,
                    accountID: native.identity.accountID, cloudKitRecordName: cloud.name)
                let presentation = try host.open()
                let id = presentation.id
                let gate: @MainActor () -> Bool = { [weak host, weak source] in
                    host?.isCurrent(id) == true && source?.communityAuthorization == native
                }
                let profile = PrivateProfileStore(
                    account: profileAccount,
                    scope: { gate() ? scope : nil }, database: profileDatabase,
                    authorizeRead: { requested in
                        guard gate(), requested == scope else { throw PrivateDataFailure.invalidScope }
                    })
                let current = AppServices(
                    nativeSession: presentation.domain.session, privateProfile: profile,
                    avatars: try avatarHost?.bind(session: presentation.domain.session, isCurrent: gate),
                    avatarEditorHost: ownerPhotos?.host, avatarReports: reportPhotos?.presenter,
                    avatarPreviewSelection: ownerPhotos?.selection,
                    simulatedCoordinate: PreviewCommunityClient.center, isCurrent: gate)
                services = current
                await current.prepareProfile()
                guard gate() else { return }
                if ["profile-onboarding", "profile-offline", "profile-delayed", "profile-empty"].contains(
                    mode)
                {
                    return
                }
                await current.enter(
                    name: current.savedName.isEmpty
                        ? (source.isSecond ? "Nowe konto" : "Gość") : current.savedName)
                if !configuredProfileFailure {
                    configuredProfileFailure = true
                    profileDatabase.conflict = mode == "profile-conflict"
                    profileDatabase.loseSave = mode == "profile-unknown"
                }
                await current.activate()
                current.session.updateLocation(
                    mode == "avatar-owner-no-location"
                        ? nil
                        : .init(
                            coordinate: PreviewCommunityClient.center, accuracy: 10, measuredAt: Date()))
                if mode == "pending", first {
                    first = false
                    await api.loseNextSend()
                    current.session.draft = "Niepotwierdzona próba"
                    _ = await current.session.sendDraft()
                    current.session.errorMessage = nil
                }
            } catch { invalidate() }
        }
        var hasReports: Bool { reportPhotos != nil }
        var reportSubmits: Int { reportPhotos?.stats.submits ?? 0 }
        var reportCancels: Int { reportPhotos?.stats.cancels ?? 0 }
        var reportCleaned: Bool { reportPhotos?.stats.cleaned == true }
        func cleanupReports() { try? reportPhotos?.cleanup() }
        var hasAvatars: Bool { avatarAPI != nil }
        func clearAvatar() async {
            await api.setPhotoPublished(false)
            await services?.session.refreshUsers()
            await services?.session.refreshMessages()
        }
        func restoreAvatar() async {
            await api.setPhotoPublished(true)
            await services?.session.refreshUsers()
            await services?.session.refreshMessages()
        }
        func repairAvatar() async { await avatarAPI?.repair() }
        func releaseAvatarRead() async { await avatarAPI?.release() }
        func releaseOwnerUpload() async { await ownerPhotos?.api.release() }
        func releaseProfileRead() { profileDatabase.release() }
        func close(_ id: UUID) async {
            services?.invalidateNativePresentation()
            await avatarAPI?.release()
            await host.close(id)
        }
        func invalidate() {
            reportPhotos?.presenter.invalidate()
            ownerPhotos?.host.invalidate()
            host.invalidate()
            services?.invalidateNativePresentation()
            services = nil
            Task { await avatarAPI?.release() }
            Task { await ownerPhotos?.api.release() }
        }
        func changeAccount() async {
            invalidate()
            try? source.changeAccount()
            await open()
        }
    }
    @MainActor private final class CommunityPreviewProfileCloud: CloudKitAccountSource {
        var name = "synthetic-cloud-A"
        func availability() async throws -> CloudKitAccountAvailability { .available }
        func userRecordName() async throws -> String { name }
    }
    @MainActor private final class CommunityPreviewProfileDatabase: PrivateProfileDatabase {
        private struct Row {
            let name: String
            let version: Int
        }
        private var rows: [String: Row] = [:]
        var failRead = false, holdRead = false, conflict = false, loseSave = false
        private var pending: CheckedContinuation<Void, Never>?
        func seed(_ scope: PrivateAccountScope, name: String) {
            rows[scope.digest] = Row(name: name, version: 1)
        }
        func release() {
            pending?.resume()
            pending = nil
        }
        func fetchProfile(scope: PrivateAccountScope) async throws -> CKRecord? {
            if failRead {
                failRead = false
                throw CKError(.networkUnavailable)
            }
            let snapshot: CKRecord?
            if let row = rows[scope.digest] {
                let record = try PrivateProfileRecordCodec.encode(
                    .init(displayName: row.name), updating: nil, scope: scope)
                record["previewRevision"] = row.version as NSNumber
                snapshot = record
            } else {
                snapshot = nil
            }
            if holdRead {
                holdRead = false
                await withCheckedContinuation { pending = $0 }
            }
            return snapshot
        }
        func saveProfile(_ record: CKRecord, scope: PrivateAccountScope) async throws -> CKRecord {
            let profile = try PrivateProfileRecordCodec.decode(record, scope: scope)
            let previous = rows[scope.digest]?.version ?? 0
            if conflict {
                conflict = false
                rows[scope.digest] = Row(name: "Nazwa z drugiego urządzenia", version: previous + 1)
                throw CKError(.serverRecordChanged)
            }
            guard (record["previewRevision"] as? NSNumber)?.intValue ?? 0 == previous else {
                throw CKError(.serverRecordChanged)
            }
            rows[scope.digest] = Row(name: profile.displayName, version: previous + 1)
            record["previewRevision"] = (previous + 1) as NSNumber
            if loseSave {
                loseSave = false
                throw CKError(.networkFailure)
            }
            return record
        }
        func deleteProfile(scope: PrivateAccountScope) async throws { rows[scope.digest] = nil }
    }
    @MainActor private final class CommunityPreviewAuthorization: GatewayAvatarAuthorizationSource {
        var communityAuthorization: GatewayCommunityAuthorization?
        var isSecond = false
        init() throws { try select() }
        func changeAccount() throws {
            isSecond.toggle()
            try select()
        }
        private func select() throws {
            communityAuthorization = try .init(
                accountID: isSecond ? CommunityPreviewAPI.ownerB : CommunityPreviewAPI.ownerA,
                binding: .init(
                    appleUserID: isSecond ? "synthetic-B" : "synthetic-A",
                    cloudKitRecordName: isSecond ? "synthetic-cloud-B" : "synthetic-cloud-A"),
                revision: UUID())
        }
        func communityAccessToken(for expected: GatewayCommunityAuthorization) async throws -> GatewaySecret {
            guard communityAuthorization == expected else { throw GatewayFailure.superseded }
            return try GatewaySecret(expected.identity.accountID + "." + String(repeating: "a", count: 43))
        }
        func privateDataScope(configuration: CloudKitConfiguration) -> PrivateAccountScope? {
            guard let communityAuthorization else { return nil }
            return try? .init(
                configuration: configuration, accountID: communityAuthorization.identity.accountID,
                cloudKitRecordName: isSecond ? "synthetic-cloud-B" : "synthetic-cloud-A")
        }
        func rejectCommunityAccess(for authorization: GatewayCommunityAuthorization) async {
            if communityAuthorization == authorization { communityAuthorization = nil }
        }
    }
    @MainActor private final class CommunityPreviewStorage: GatewayCommunityJournalStorage {
        private var data: [String: Data] = [:]
        func read(scope: GatewayCommunityScope) throws -> Data? { data[scope.digest] }
        func write(_ bytes: Data, scope: GatewayCommunityScope) throws { data[scope.digest] = bytes }
        func remove(scope: GatewayCommunityScope) throws { data[scope.digest] = nil }
    }
    private actor CommunityPreviewAPI: GatewayCommunityAPI {
        static let ownerA = "11111111-1111-4111-8111-111111111111"
        static let ownerB = "22222222-2222-4222-8222-222222222222"
        nonisolated let origin = "https://community-preview.example.invalid"
        private let avatars: Bool
        private var photoPublished = true
        init(avatars: Bool = false) { self.avatars = avatars }
        func setPhotoPublished(_ value: Bool) { photoPublished = value }
        private var visibility: [String: Int] = [:]
        private var entries: [String: ChatMessage] = [:]
        private var loseSend = false
        private var owner = ownerA
        func selectOwner(_ value: String) { owner = value }
        func loseNextSend() { loseSend = true }
        private func record(_ owner: String, _ kind: String, _ id: String) -> String {
            func digest(_ s: String) -> String {
                SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            let owner = digest("echoes/public-owner/v1\0" + owner)
            let logical = digest("echoes/public-logical/v1\0" + id)
            return "community-v1-" + kind + "-"
                + digest("echoes/public-record/v1\0" + owner + "\0" + kind + "\0" + logical)
        }
        func perform(_ op: GatewayCommunityOperation, token: GatewaySecret) async throws
            -> GatewayCommunityReply
        {
            let owner = self.owner
            let now = Date()
            let time = now.timeIntervalSince1970 * 1000
            let result: GatewayCommunityValue
            switch op {
            case .configuration: result = .configuration(supportURL: nil)
            case .visibility: result = .generation(visibility[owner] ?? 0)
            case .stop(_, let generation):
                visibility[owner] = generation + 1
                result = .publication(
                    id: record(owner, "presence", "singleton"), generation: generation + 1, visible: false)
            case .publish(_, _, _, _, _, _, let generation):
                result = .publication(
                    id: record(owner, "presence", "singleton"), generation: generation, visible: true)
            case .nearby:
                result = .nearby([
                    .init(
                        id: owner == Self.ownerA ? Self.ownerB : Self.ownerA,
                        name: "Maja", coordinate: .init(latitude: 51.112, longitude: 17.034),
                        lastSong: "Echoes — Pink Floyd", appleMusicID: "", expiresAt: time + 600000,
                        avatarVersionID: avatars && photoPublished ? CommunityAvatarPreviewData.version : nil)
                ])
            case .messages:
                if avatars {
                    let peer = owner == Self.ownerA ? Self.ownerB : Self.ownerA
                    let key = "seed-" + peer
                    if entries[key] == nil {
                        entries[key] = .init(
                            id: record(peer, "message", "68000000-0000-4000-8000-000000000099"),
                            text: "Zdjęcie w czacie", senderName: "Maja", senderID: peer,
                            timestamp: time, expiresAt: time + 7_200_000)
                    }
                }
                let messages = entries.values.sorted { $0.timestamp < $1.timestamp }.map { value in
                    ChatMessage(
                        id: value.id, text: value.text, senderName: value.senderName,
                        senderID: value.senderID,
                        timestamp: value.timestamp, expiresAt: value.expiresAt,
                        avatarVersionID: avatars && photoPublished ? CommunityAvatarPreviewData.version : nil)
                }
                result = .messages(.init(messages: messages, nextCursor: nil))
            case .send(let id, let name, let text, _):
                let key = owner + id
                let message =
                    entries[key]
                    ?? ChatMessage(
                        id: record(owner, "message", id), text: text,
                        senderName: name, senderID: owner, timestamp: time, expiresAt: time + 7_200_000)
                entries[key] = message
                if loseSend {
                    loseSend = false
                    throw GatewayCommunityFailure.unavailable
                }
                result = .sent(message)
            case .blocked: result = .blocked([])
            case .blockState: result = .blockState(generation: 0, blocked: false)
            case .block(_, let target, _, _): result = .receipt(record(owner, "block", target))
            case .report: result = .accepted
            case .profile: result = .profile(nil)
            case .saveProfile: throw GatewayCommunityFailure.unavailable
            }
            return .init(serverTime: now, value: result)
        }
    }
#endif
