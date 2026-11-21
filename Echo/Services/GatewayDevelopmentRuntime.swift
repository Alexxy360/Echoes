#if DEBUG
    import EchoesCloudKit
    import Foundation
    import Observation
    import UIKit

    /// Native composition for the isolated Development screen. Missing activation throws before
    /// native identity sources are constructed. Ordinary AppServices still uses its current adapter.
    @MainActor private final class GatewayCommunityInvalidationRelay {
        weak var host: GatewayCommunityHost?
        weak var services: AppServices?
        weak var avatarEditor: GatewayAvatarEditorHost?
        weak var avatars: GatewayCommunityAvatarHost?
        weak var avatarReviews: GatewayAvatarReviewHost?
        weak var reportReviews: GatewayReportReviewHost?
        weak var avatarReports: GatewayAvatarReportPresenter?
        weak var avatarReportReviews: GatewayAvatarReportReviewHost?
        weak var bootstrap: GatewayCommunityBootstrap?
        func clearServices() {
            bootstrap?.invalidate()
            avatarReportReviews?.invalidate()
            avatarEditor?.invalidate()
            avatarReviews?.invalidate()
            reportReviews?.invalidate()
            avatarReports?.invalidate()
            services?.invalidateNativePresentation()
        }
    }

    @MainActor @Observable final class GatewayDevelopmentRuntime {
        let authentication: GatewaySignInHost
        let deletion: GatewayDeletionHost
        let community: GatewayCommunityHost
        let avatarCache: GatewayAvatarCache
        let avatarUploads: GatewayAvatarUploadJournal
        let avatarOwner: GatewayAvatarOwnerController
        let avatarEditor: GatewayAvatarEditorHost
        let avatars: GatewayCommunityAvatarHost
        let avatarReviewJournal: GatewayAvatarReviewJournal
        let avatarReviews: GatewayAvatarReviewHost
        let reportReviewJournal: GatewayReportReviewJournal
        let reportReviews: GatewayReportReviewHost
        let avatarReportJournal: GatewayAvatarReportJournal
        let avatarReports: GatewayAvatarReportPresenter
        let avatarReportReviewJournal: GatewayAvatarReportReviewJournal
        let avatarReportReviews: GatewayAvatarReportReviewHost
        private let communityBootstrap: GatewayCommunityBootstrap
        private(set) var communityServices: AppServices?
        private(set) var communityPresentationID: UUID?
        var openingCommunity: Bool { communityBootstrap.isOpening }
        private let relay: GatewayCommunityInvalidationRelay
        private let profileConfiguration: CloudKitConfiguration
        private let gatewayConfiguration: GatewayConfiguration

        /// Close the old community domain synchronously before the report panel starts a new lease.
        func prepareReportReview() {
            community.invalidate()
            communityServices = nil
            communityPresentationID = nil
            avatarReviews.setForeground(false)
            avatarReports.invalidate()
        }

        func invalidateCommunityOpening() { communityBootstrap.invalidate() }

        @discardableResult func openCommunity(
            isCurrent isCurrentScreen: @escaping @MainActor () -> Bool = { true }
        ) async throws -> UUID {
            guard !openingCommunity else { throw GatewayAvatarReviewFailure.busy }
            // Close every old presentation before the first journal await, even if a peek fails.
            community.invalidate()
            communityServices = nil
            communityPresentationID = nil
            avatarReports.invalidate()
            avatarReviews.setForeground(false)
            reportReviews.setForeground(false)
            avatarReportReviews.setForeground(false)
            let auth = authentication
            let configuration = profileConfiguration
            guard let native = auth.communityAuthorization,
                let scope = auth.privateDataScope(configuration: configuration)
            else { throw GatewayFailure.signInRequired }
            let bootstrap = communityBootstrap
            let pending = try await bootstrap.load(
                configuration: gatewayConfiguration, owner: scope, binding: native.identity.binding,
                isCurrent: {
                    isCurrentScreen() && auth.communityAuthorization == native
                        && auth.privateDataScope(configuration: configuration) == scope
                })
            guard isCurrentScreen(), auth.communityAuthorization == native,
                auth.privateDataScope(configuration: configuration) == scope, bootstrap.isCurrent(pending)
            else { throw GatewayFailure.signInRequired }
            try Task.checkCancellation()
            let presentation = try community.open()
            let id = presentation.id
            let current: @MainActor () -> Bool = { [weak community, weak auth] in
                community?.isCurrent(id) == true && auth?.communityAuthorization == native
                    && auth?.privateDataScope(configuration: configuration) == scope
            }
            let authorize: @MainActor (PrivateAccountScope) async throws -> Void = { requested in
                guard current(), requested == scope else { throw PrivateDataFailure.invalidScope }
                try await auth.authorizePrivateWrite(requested)
                guard current() else { throw PrivateDataFailure.invalidScope }
            }
            let database = NativePrivateProfileDatabase(
                configuration: configuration,
                account: auth.cloudKitAccount, authorizeWrite: authorize)
            let profile = PrivateProfileStore(
                account: auth.cloudKitAccount,
                scope: { current() ? scope : nil }, database: database, authorizeRead: authorize)
            let avatarBinding: GatewayCommunityAvatarBinding
            do {
                // The new domain owns presentation lifetime after this synchronous handoff.
                guard bootstrap.isCurrent(pending), isCurrentScreen() else {
                    throw GatewayCommunityFailure.superseded
                }
                avatarBinding = try avatars.bind(
                    session: presentation.domain.session,
                    pendingModeration: pending.upload, pendingReportedPhotoModeration: pending.reportedPhoto,
                    isCurrent: current)
            } catch {
                community.invalidate()
                throw error
            }
            let services = AppServices(
                nativeSession: presentation.domain.session,
                privateProfile: profile, avatars: avatarBinding, avatarEditorHost: avatarEditor,
                avatarReports: avatarReports,
                isCurrent: current)
            relay.services = services
            communityServices = services
            communityPresentationID = id
            return id
        }
        /// The parent may disappear between async return and its navigation handoff.
        func discardCommunity(_ id: UUID) {
            guard communityPresentationID == id else { return }
            community.invalidate()
            communityServices = nil
            communityPresentationID = nil
        }
        func closeCommunity(_ id: UUID) async {
            await community.close(id)
            if communityPresentationID == id {
                communityServices = nil
                communityPresentationID = nil
            }
        }
        init(anchor: @escaping @MainActor () -> UIWindow?) throws {
            let activation = try GatewayDevelopmentActivation(
                infoDictionary: Bundle.main.infoDictionary ?? [:],
                bundleIdentifier: Bundle.main.bundleIdentifier)
            profileConfiguration = activation.cloudKit
            gatewayConfiguration = activation.configuration
            let client = GatewayHTTPClient(configuration: activation.configuration)
            let authenticationAPI = try ActivatedGatewayAuthenticationAPI(api: client, activation: activation)
            let deletionAPI = try ActivatedGatewayAccountDeletionAPI(api: client, activation: activation)
            let session = GatewaySessionController(
                api: authenticationAPI,
                storage: KeychainGatewaySessionStorage(configuration: activation.configuration))
            let relay = GatewayCommunityInvalidationRelay()
            self.relay = relay
            let auth = GatewaySignInHost(
                api: authenticationAPI, session: session,
                cloudKitAccount: .init(
                    source: NativeCloudKitAccountSource(configuration: activation.cloudKit)),
                apple: NativeAppleGatewayIdentitySource(),
                authorizer: NativeAppleGatewayAuthorizer(anchor: anchor),
                isEnabled: { activation.isActive() }, clearDomainState: { relay.host?.invalidate() })
            authentication = auth
            let account = CloudKitAccountSession(
                source: NativeCloudKitAccountSource(configuration: activation.cloudKit))
            let storage = KeychainGatewayDeletionStorage(
                configuration: activation.configuration, cloudKit: activation.cloudKit)
            let cachesRoot = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let local = try GatewayLocalAccountData(root: cachesRoot)
            let avatarCache = try GatewayAvatarCache(root: cachesRoot)
            self.avatarCache = avatarCache
            let supportRoot = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let avatarUploads = try GatewayAvatarUploadJournal(root: supportRoot)
            self.avatarUploads = avatarUploads
            avatarOwner = try GatewayAvatarOwnerController(
                api: GatewayAvatarMutationHTTPClient(
                    configuration: activation.configuration, isEnabled: { activation.isActive() }),
                configuration: activation.configuration, cloudKit: activation.cloudKit,
                authorization: auth, journal: avatarUploads, isEnabled: { activation.isActive() },
                presentationChanged: { relay.avatars?.observeOwner($0, snapshot: $1) })
            avatarEditor = try GatewayAvatarEditorHost(
                controller: avatarOwner, cloudKit: activation.cloudKit, authorization: auth,
                ownerPreview: GatewayAvatarOwnerPreviewHost(
                    api: GatewayAvatarOwnerPreviewHTTPClient(
                        configuration: activation.configuration, isEnabled: { activation.isActive() }),
                    configuration: activation.configuration, cloudKit: activation.cloudKit,
                    authorization: auth,
                    isEnabled: { activation.isActive() }),
                isEnabled: { activation.isActive() })
            relay.avatarEditor = avatarEditor
            avatars = try GatewayCommunityAvatarHost(
                api: GatewayAvatarHTTPClient(
                    configuration: activation.configuration, isEnabled: { activation.isActive() }),
                configuration: activation.configuration, cloudKit: activation.cloudKit,
                authorization: auth, cache: avatarCache, isEnabled: { activation.isActive() })
            relay.avatars = avatars
            let reviewJournal = GatewayAvatarReviewJournal(
                storage: KeychainGatewayAvatarReviewJournalStorage())
            avatarReviewJournal = reviewJournal
            let reviews = try GatewayAvatarReviewHost(
                api: GatewayAvatarReviewHTTPClient(
                    configuration: activation.configuration, isEnabled: { activation.isActive() }),
                configuration: activation.configuration, cloudKit: activation.cloudKit,
                authorization: auth, journal: reviewJournal, isEnabled: { activation.isActive() },
                publicationChanged: { [weak avatars = self.avatars] in avatars?.observeModeration($0) })
            avatarReviews = reviews
            relay.avatarReviews = reviews
            let reportJournal = GatewayReportReviewJournal(
                storage: KeychainGatewayReportReviewJournalStorage())
            reportReviewJournal = reportJournal
            let reports = try GatewayReportReviewHost(
                api: GatewayReportReviewHTTPClient(
                    configuration: activation.configuration, isEnabled: { activation.isActive() }),
                configuration: activation.configuration, cloudKit: activation.cloudKit,
                authorization: auth, journal: reportJournal, isEnabled: { activation.isActive() })
            reportReviews = reports
            relay.reportReviews = reports
            let photoReviewJournal = GatewayAvatarReportReviewJournal(
                storage: KeychainGatewayAvatarReportReviewJournalStorage())
            avatarReportReviewJournal = photoReviewJournal
            let photoReviews = try GatewayAvatarReportReviewHost(
                api: GatewayAvatarReportReviewHTTPClient(
                    configuration: activation.configuration, isEnabled: { activation.isActive() }),
                configuration: activation.configuration, cloudKit: activation.cloudKit,
                authorization: auth, journal: photoReviewJournal, isEnabled: { activation.isActive() },
                publicationChanged: { [weak avatars = self.avatars] in avatars?.observeModeration($0) })
            avatarReportReviews = photoReviews
            relay.avatarReportReviews = photoReviews
            let bootstrap = GatewayCommunityBootstrap(
                upload: reviewJournal, reportedPhoto: photoReviewJournal)
            communityBootstrap = bootstrap
            relay.bootstrap = bootstrap
            let photoJournal = GatewayAvatarReportJournal(
                storage: KeychainGatewayAvatarReportJournalStorage())
            avatarReportJournal = photoJournal
            let photoReports = GatewayAvatarReportPresenter(
                host: try GatewayAvatarReportHost(
                    api: GatewayAvatarReportHTTPClient(
                        configuration: activation.configuration, isEnabled: { activation.isActive() }),
                    configuration: activation.configuration, cloudKit: activation.cloudKit,
                    authorization: auth, journal: photoJournal, isEnabled: { activation.isActive() },
                    canCancel: { activation.isActive() }))
            avatarReports = photoReports
            relay.avatarReports = photoReports
            let communityStorage = KeychainGatewayCommunityJournalStorage()
            let communityAPI = try ActivatedGatewayCommunityAPI(
                api: GatewayCommunityHTTPClient(configuration: activation.configuration),
                activation: activation)
            community = GatewayCommunityHost(
                api: communityAPI, configuration: activation.configuration, cloudKit: activation.cloudKit,
                authorization: auth, storage: communityStorage, isEnabled: { activation.isActive() },
                clearLocalState: { relay.clearServices() })
            relay.host = community
            deletion = GatewayDeletionHost(
                api: deletionAPI, cloudKitAccount: account,
                apple: NativeAppleGatewayIdentitySource(),
                authorizer: NativeAppleGatewayAuthorizer(anchor: anchor),
                currentAuthentication: { auth.authenticatedIdentity },
                resumeBindings: { name in
                    try GatewayDeletionController.resumeBindings(
                        configuration: activation.cloudKit, origin: deletionAPI.origin,
                        storage: storage, cloudKitRecordName: name)
                },
                makeController: { binding in
                    // Erasure-only dependency.
                    let database = NativePrivateProfileDatabase(
                        configuration: activation.cloudKit, account: account,
                        authorizeWrite: { _ in throw PrivateDataFailure.accountDeleted })
                    return GatewayDeletionController(
                        configuration: activation.cloudKit, binding: binding,
                        api: deletionAPI, storage: storage, account: account, cleanup: database,
                        isEnabled: { activation.isActive() },
                        fenceLocalAccess: { binding, accountID in
                            reviews.invalidate()
                            reports.invalidate()
                            photoReports.invalidate()
                            photoReviews.invalidate()
                            bootstrap.invalidate()
                            try photoReviewJournal.fenceForAccountDeletion(
                                binding: binding, accountID: accountID)
                            try reviewJournal.fenceForAccountDeletion(binding: binding, accountID: accountID)
                            try reportJournal.fenceForAccountDeletion(binding: binding, accountID: accountID)
                            try photoJournal.fenceForAccountDeletion(binding: binding, accountID: accountID)
                            do {
                                try await auth.prepareForAccountDeletion(
                                    binding: binding, accountID: accountID)
                            } catch {
                                await local.fence(binding: binding, accountID: accountID)
                                await avatarCache.fence(binding: binding, accountID: accountID)
                                try await avatarUploads.fenceForAccountDeletion(
                                    binding: binding, accountID: accountID)
                                throw error
                            }
                            await local.fence(binding: binding, accountID: accountID)
                            await avatarCache.fence(binding: binding, accountID: accountID)
                            try await avatarUploads.fenceForAccountDeletion(
                                binding: binding, accountID: accountID)
                        },
                        clearLocalData: { scope in
                            try await local.erase(scope: scope)
                            try await avatarCache.erase(scope: scope)
                            try await avatarUploads.erase(scope: scope)
                            try await reviewJournal.erase(owner: scope)
                            try await reportJournal.erase(owner: scope)
                            try await photoJournal.erase(owner: scope)
                            try await photoReviewJournal.erase(owner: scope)
                            let journalScope = try GatewayCommunityScope(
                                configuration: activation.configuration, privateScope: scope, binding: binding
                            )
                            try communityStorage.remove(scope: journalScope)
                        })
                }, isEnabled: { activation.isActive() })
        }
    }
#endif
