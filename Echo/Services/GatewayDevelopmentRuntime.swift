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
        weak var avatarOwner: GatewayAvatarOwnerController?
        func clearServices() {
            avatarOwner?.invalidate()
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
        let avatars: GatewayCommunityAvatarHost
        private(set) var communityServices: AppServices?
        private(set) var communityPresentationID: UUID?
        private let relay: GatewayCommunityInvalidationRelay
        private let profileConfiguration: CloudKitConfiguration

        @discardableResult func openCommunity() throws -> UUID {
            let auth = authentication
            let configuration = profileConfiguration
            guard let native = auth.communityAuthorization,
                let scope = auth.privateDataScope(configuration: configuration)
            else { throw GatewayFailure.signInRequired }
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
                avatarBinding = try avatars.bind(session: presentation.domain.session, isCurrent: current)
            } catch {
                community.invalidate()
                throw error
            }
            let services = AppServices(
                nativeSession: presentation.domain.session,
                privateProfile: profile, avatars: avatarBinding, isCurrent: current)
            relay.services = services
            communityServices = services
            communityPresentationID = id
            return id
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
                authorization: auth, journal: avatarUploads, isEnabled: { activation.isActive() })
            relay.avatarOwner = avatarOwner
            avatars = try GatewayCommunityAvatarHost(
                api: GatewayAvatarHTTPClient(
                    configuration: activation.configuration, isEnabled: { activation.isActive() }),
                configuration: activation.configuration, cloudKit: activation.cloudKit,
                authorization: auth, cache: avatarCache, isEnabled: { activation.isActive() })
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
                            let journalScope = try GatewayCommunityScope(
                                configuration: activation.configuration, privateScope: scope, binding: binding
                            )
                            try communityStorage.remove(scope: journalScope)
                        })
                }, isEnabled: { activation.isActive() })
        }
    }
#endif
