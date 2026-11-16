#if DEBUG
    import CloudKit
    import CryptoKit
    import EchoesCloudKit
    import EchoesCore
    import Observation
    import SwiftUI

    /// Explicit UI fixture using the native adapter/domain/host, with synthetic API and identity.
    struct GatewayCommunityPreviewView: View {
        let mode: String
        @Environment(\.scenePhase) private var scenePhase
        @State private var fixture: CommunityPreviewFixture?
        @State private var failed = false
        @State private var path: [Destination] = []
        private enum Destination: Hashable { case account }
        var body: some View {
            NavigationStack(path: $path) {
                Group {
                    if let fixture, let presentation = fixture.host.presentation,
                        fixture.host.isCurrent(presentation.id), let services = fixture.services
                    {
                        ContentView(
                            services: services, usesNavigationStack: false,
                            presentationNotice: "Podgląd UI • dane syntetyczne • bez logowania i backendu",
                            openNativeAccount: {
                                guard fixture.host.isCurrent(presentation.id) else { return }
                                path = [.account]
                                Task { await fixture.close(presentation.id) }
                            }
                        ).id(presentation.id)
                    } else if let fixture {
                        ContentUnavailableView {
                            Label("Sesja testowa zamknięta", systemImage: "lock")
                        } actions: {
                            Button("Otwórz nową sesję testową") { Task { await fixture.open() } }
                        }.accessibilityIdentifier("community.preview.closed")
                    } else if failed {
                        ContentUnavailableView("Podgląd niedostępny", systemImage: "exclamationmark.triangle")
                    } else {
                        ProgressView("Przygotowanie podglądu…")
                    }
                }
                .navigationDestination(for: Destination.self) { _ in
                    if let fixture { GatewayAccountDeletionView(host: fixture.deletion, isPreview: true) }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu("Test", systemImage: "testtube.2") {
                            Button("Zmień konto testowe") { Task { await fixture?.changeAccount() } }
                            Button("Zamknij sesję testową") { fixture?.invalidate() }
                            Button("Zakończ opóźniony odczyt") { fixture?.releaseProfileRead() }
                        }.accessibilityIdentifier("community.preview.actions")
                    }
                }
            }
            .task {
                guard fixture == nil, !failed else { return }
                do {
                    let current = try CommunityPreviewFixture(mode: mode)
                    fixture = current
                    await current.open()
                } catch { failed = true }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    fixture?.invalidate()
                    path = []
                }
            }
        }
    }

    @MainActor @Observable private final class CommunityPreviewFixture {
        let source: CommunityPreviewAuthorization
        let host: GatewayCommunityHost
        let deletion: GatewayDeletionHost
        private let mode: String
        private let api: CommunityPreviewAPI
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
                ].contains(mode)
            else { throw GatewayFailure.configuration }
            self.mode = mode
            source = try CommunityPreviewAuthorization()
            api = CommunityPreviewAPI()
            profileConfiguration = try .init(
                containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
            profileAccount = CloudKitAccountSession(source: cloud)
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
                    .init(
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
        func releaseProfileRead() { profileDatabase.release() }
        func close(_ id: UUID) async {
            services?.invalidateNativePresentation()
            await host.close(id)
        }
        func invalidate() {
            host.invalidate()
            services?.invalidateNativePresentation()
            services = nil
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
    @MainActor private final class CommunityPreviewAuthorization: GatewayCommunityAuthorizationSource {
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
                        lastSong: "Echoes — Pink Floyd", appleMusicID: "", expiresAt: time + 600000)
                ])
            case .messages:
                result = .messages(
                    .init(messages: entries.values.sorted { $0.timestamp < $1.timestamp }, nextCursor: nil))
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
