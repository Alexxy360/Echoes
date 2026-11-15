#if DEBUG
    import EchoesCloudKit
    import Foundation
    import UIKit

    /// Native composition for the isolated Development screen. Missing activation throws before
    /// native identity sources are constructed. Ordinary AppServices still uses its current adapter.
    @MainActor final class GatewayDevelopmentRuntime {
        let authentication: GatewaySignInHost
        let deletion: GatewayDeletionHost
        init(anchor: @escaping @MainActor () -> UIWindow?) throws {
            let activation = try GatewayDevelopmentActivation(
                infoDictionary: Bundle.main.infoDictionary ?? [:],
                bundleIdentifier: Bundle.main.bundleIdentifier)
            let client = GatewayHTTPClient(configuration: activation.configuration)
            let authenticationAPI = try ActivatedGatewayAuthenticationAPI(api: client, activation: activation)
            let deletionAPI = try ActivatedGatewayAccountDeletionAPI(api: client, activation: activation)
            let session = GatewaySessionController(
                api: authenticationAPI,
                storage: KeychainGatewaySessionStorage(configuration: activation.configuration))
            // No profile/domain view in this isolated screen.
            let auth = GatewaySignInHost(
                api: authenticationAPI, session: session,
                cloudKitAccount: .init(
                    source: NativeCloudKitAccountSource(configuration: activation.cloudKit)),
                apple: NativeAppleGatewayIdentitySource(),
                authorizer: NativeAppleGatewayAuthorizer(anchor: anchor),
                isEnabled: { activation.isActive() }, clearDomainState: {})
            authentication = auth
            let account = CloudKitAccountSession(
                source: NativeCloudKitAccountSource(configuration: activation.cloudKit))
            let storage = KeychainGatewayDeletionStorage(
                configuration: activation.configuration, cloudKit: activation.cloudKit)
            let local = try GatewayLocalAccountData(
                root: FileManager.default.url(
                    for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
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
                                throw error
                            }
                            await local.fence(binding: binding, accountID: accountID)
                        }, clearLocalData: { scope in try await local.erase(scope: scope) })
                }, isEnabled: { activation.isActive() })
        }
    }
#endif
