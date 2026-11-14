import AuthenticationServices
import CloudKit
import Foundation
import Testing

@testable import EchoesCloudKit

private let hostNow = Date(timeIntervalSince1970: 1_800_000_000)
private let hostAccountID = "30000000-0000-4000-8000-000000000001"
private func hostPair(_ suffix: String) throws -> GatewaySessionPair {
    .init(
        protocolVersion: 1, accountID: hostAccountID, sessionToken: try GatewaySecret("access-" + suffix),
        expiresAt: Int(hostNow.timeIntervalSince1970) + 600,
        renewalToken: try GatewaySecret("renewal-" + suffix),
        renewalExpiresAt: Int(hostNow.timeIntervalSince1970) + 3_600)
}
private final class HostStorage: GatewaySessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var rejectWrites = false
    func read() throws -> Data? { lock.withLock { value } }
    func write(_ data: Data) throws {
        try lock.withLock {
            if rejectWrites { throw GatewayFailure.storageUnavailable }
            value = data
        }
    }
    func failWrites() { lock.withLock { rejectWrites = true } }
    func savedState() throws -> StoredGatewaySession.State? {
        try read().map { try JSONDecoder().decode(StoredGatewaySession.self, from: $0).state }
    }
}
private final class HostClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = hostNow
    func now() -> Date { lock.withLock { value } }
    func advance(_ interval: Double) { lock.withLock { value += interval } }
}
private actor HostAPI: GatewayAuthenticationAPI {
    nonisolated let origin = "https://host.example.invalid"
    var challenges = 0, logins = 0, statuses = 0, renewals = 0
    var purposes: [GatewayChallengePurpose] = []
    var resets: [String] = []
    var loginLimited = false
    var resetFailure: GatewayFailure?
    var holdNextReset = false
    var resetWaiter: CheckedContinuation<Void, Never>?
    func setLoginLimited(_ limited: Bool = true) { loginLimited = limited }
    func setResetFailure(_ failure: GatewayFailure?) { resetFailure = failure }
    func holdReset() { holdNextReset = true }
    func waitingForReset() -> Bool { resetWaiter != nil }
    func resumeReset() {
        resetWaiter?.resume()
        resetWaiter = nil
    }
    var loggedOut: [GatewaySecret] = []
    var holdNextLogin = false
    var holdNextLogout = false
    var logoutWaiter: CheckedContinuation<Void, Never>?
    var loginWaiter: (CheckedContinuation<GatewaySessionPair, any Error>, GatewaySessionPair)?
    func holdLogin() { holdNextLogin = true }
    func holdLogout() { holdNextLogout = true }
    func waitingForLogout() -> Bool { logoutWaiter != nil }
    func resumeLogout() {
        logoutWaiter?.resume()
        logoutWaiter = nil
    }
    func waitingForLogin() -> Bool { loginWaiter != nil }
    func resumeLogin() {
        loginWaiter?.0.resume(returning: loginWaiter!.1)
        loginWaiter = nil
    }
    func challenge(purpose: GatewayChallengePurpose) async throws -> GatewayChallenge {
        challenges += 1
        purposes.append(purpose)
        return .init(
            protocolVersion: 1, challengeID: UUID().uuidString.lowercased(),
            nonce: try GatewaySecret(String(repeating: "b", count: 43)),
            expiresAt: Int(hostNow.timeIntervalSince1970) + 300)
    }
    func login(challengeID: String, identityToken: GatewaySecret, authorizationCode: GatewaySecret)
        async throws -> GatewaySessionPair
    {
        logins += 1
        if loginLimited { throw GatewayFailure.server(.sessionLimited, status: 409, retryAfterSeconds: nil) }
        let pair = try hostPair(String(logins))
        if holdNextLogin {
            holdNextLogin = false
            return try await withCheckedThrowingContinuation { loginWaiter = ($0, pair) }
        }
        return pair
    }
    func renew(token: GatewaySecret) async throws -> GatewaySessionPair {
        renewals += 1
        return try hostPair("rotated")
    }
    func session(token: GatewaySecret) async throws -> GatewaySessionStatus {
        statuses += 1
        return .init(
            protocolVersion: 1, accountID: hostAccountID, expiresAt: Int(hostNow.timeIntervalSince1970) + 600)
    }
    func logout(token: GatewaySecret) async throws {
        loggedOut.append(token)
        if holdNextLogout {
            holdNextLogout = false
            await withCheckedContinuation { logoutWaiter = $0 }
        }
    }
    func logoutAll(token: GatewaySecret) async throws { loggedOut.append(token) }
    func resetSessions(challengeID: String, identityToken: GatewaySecret, expectedAccountID: String?)
        async throws
    {
        resets.append(challengeID)
        if let resetFailure { throw resetFailure }
        loginLimited = false
        if holdNextReset {
            holdNextReset = false
            await withCheckedContinuation { resetWaiter = $0 }
        }
    }
}
@MainActor private final class HostCloud: CloudKitAccountSource {
    var status: CloudKitAccountAvailability = .available
    var name = "cloud-A"
    var requests = 0
    func availability() async throws -> CloudKitAccountAvailability { status }
    func userRecordName() async throws -> String {
        requests += 1
        return name
    }
}
@MainActor private final class HostApple: AppleGatewayIdentitySource {
    var state = AppleGatewayCredentialState.authorized
    var unavailable = false
    var requests = 0
    func credentialState(userID: String) async throws -> AppleGatewayCredentialState {
        requests += 1
        if unavailable { throw GatewayFailure.transport }
        return state
    }
}
@MainActor private final class HostAuthorizer: AppleGatewayAuthorizer {
    var requests = 0, cancellations = 0
    var userID = "apple-A"
    var hold = false
    var waiter: CheckedContinuation<AppleGatewayProof, any Error>?
    func proof() throws -> AppleGatewayProof {
        .init(
            appleUserID: userID, identityToken: try GatewaySecret("synthetic-identity"),
            authorizationCode: try GatewaySecret("synthetic-code"))
    }
    func authorize(challenge: GatewayChallenge) async throws -> AppleGatewayProof {
        requests += 1
        if hold { return try await withCheckedThrowingContinuation { waiter = $0 } }
        return try proof()
    }
    // Deliberately leaves a pending response alive to test hostile/late platform callbacks.
    func cancel() { cancellations += 1 }
    func resume() throws {
        waiter?.resume(returning: try proof())
        waiter = nil
        hold = false
    }
}
@MainActor private final class HostSwitch {
    var enabled = true
    var invalidations = 0
}
@MainActor private struct HostFixture {
    let api = HostAPI()
    let storage = HostStorage()
    let cloud = HostCloud()
    let apple = HostApple()
    let authorizer = HostAuthorizer()
    let policy = HostSwitch()
    let clock = HostClock()
    let center = NotificationCenter()
    let session: GatewaySessionController
    let host: GatewaySignInHost
    init() {
        session = GatewaySessionController(api: api, storage: storage, now: { [clock] in clock.now() })
        host = GatewaySignInHost(
            api: api, session: session, cloudKitAccount: .init(source: cloud), apple: apple,
            authorizer: authorizer, isEnabled: { [policy] in policy.enabled },
            now: { [clock] in clock.now() },
            notificationCenter: center, clearDomainState: { [policy] in policy.invalidations += 1 })
    }
    func signIn() async {
        await host.activate()
        await host.signIn()
    }
}
@MainActor private func waitForHost(_ condition: () async -> Bool) async throws {
    for _ in 0..<10_000 {
        if await condition() { return }
        await Task.yield()
    }
    throw GatewayFailure.transport
}

@Test @MainActor func nativeHostExplicitSignInBindsBothIdentitiesAndGrantsAccess() async throws {
    let f = HostFixture()
    await f.signIn()
    #expect(f.host.phase == .ready)
    #expect(f.host.accountID == hostAccountID)
    #expect(f.cloud.requests == 3)  // launch, before sheet, after sheet
    #expect(f.apple.requests == 1)
    #expect(f.authorizer.requests == 1)
    #expect(await f.api.logins == 1)
    #expect(try await f.host.accessToken() == hostPair("1").sessionToken)
    f.host.stop()
}

@Test @MainActor func backgroundSynchronouslyHidesIdentityAndRestoresWithoutAnAppleSheet() async throws {
    let f = HostFixture()
    await f.signIn()
    let invalidations = f.policy.invalidations
    f.host.suspend()
    #expect(f.host.phase == .suspended)
    #expect(f.host.accountID == nil)
    #expect(f.policy.invalidations > invalidations)
    await #expect(throws: GatewayFailure.signInRequired) { try await f.host.accessToken() }
    await f.host.activate()
    #expect(f.host.phase == .ready)
    #expect(f.authorizer.requests == 1)
    #expect(await f.api.logins == 1)
    #expect(await f.api.statuses == 1)
    f.host.stop()
}

@Test @MainActor func missingICloudNeverRequestsAppleOrGatewayChallenge() async {
    let f = HostFixture()
    f.cloud.status = .noAccount
    await f.host.activate()
    await f.host.signIn()
    #expect(f.host.phase == .unavailable)
    #expect(f.authorizer.requests == 0)
    #expect(await f.api.challenges == 0)
    #expect(f.cloud.requests == 0)
    f.host.stop()
}

@Test @MainActor func revokedNotFoundAndTransferredCredentialsEraseSavedAccessOnForeground() async throws {
    for state in [AppleGatewayCredentialState.revoked, .notFound, .transferred] {
        let f = HostFixture()
        await f.signIn()
        f.apple.state = state
        await f.host.activate()
        #expect(f.host.phase == .signedOut)
        #expect(f.host.accountID == nil)
        #expect(try f.storage.savedState() == .signedOut)
        #expect(await f.api.statuses == 0)
        f.host.stop()
    }
}

@Test @MainActor func transientCredentialFailureBlocksUIWithoutDestroyingRecoverableSession() async throws {
    let f = HostFixture()
    await f.signIn()
    f.apple.unavailable = true
    await f.host.activate()
    #expect(f.host.phase == .unavailable)
    #expect(f.host.accountID == nil)
    #expect(try f.storage.savedState() == .ready)
    await #expect(throws: GatewayFailure.signInRequired) { try await f.host.accessToken() }
    f.apple.unavailable = false
    await f.host.activate()
    #expect(f.host.phase == .ready)
    #expect(await f.api.logins == 1)
    #expect(f.authorizer.requests == 1)
    f.host.stop()
}

@Test @MainActor func cloudAccountChangingInsideAppleSheetCannotBeBoundToTheOldAttempt() async throws {
    let f = HostFixture()
    await f.host.activate()
    f.authorizer.hold = true
    let login = Task { await f.host.signIn() }
    try await waitForHost { f.authorizer.waiter != nil }
    f.cloud.name = "cloud-B"
    try f.authorizer.resume()
    await login.value
    #expect(f.host.phase == .signedOut)
    #expect(await f.api.logins == 0)
    #expect(try f.storage.savedState() == .signedOut)
    f.host.stop()
}

@Test @MainActor func revocationAndCloudNotificationsCloseUIBeforeAsyncCleanup() async throws {
    for notification in [ASAuthorizationAppleIDProvider.credentialRevokedNotification, .CKAccountChanged] {
        let f = HostFixture()
        await f.signIn()
        let oldRevision = f.host.cloudKitAccount.identityRevision
        f.center.post(name: notification, object: nil)
        #expect(f.host.phase == .signedOut)
        #expect(f.host.accountID == nil)
        #expect(f.host.cloudKitAccount.identityRevision > oldRevision)
        await #expect(throws: GatewayFailure.signInRequired) { try await f.host.accessToken() }
        f.host.stop()
    }
}

@Test @MainActor func lateAppleProofAfterBackgroundCannotStartCodeExchange() async throws {
    let f = HostFixture()
    await f.host.activate()
    f.authorizer.hold = true
    let login = Task { await f.host.signIn() }
    try await waitForHost { f.authorizer.waiter != nil }
    f.host.suspend()
    try f.authorizer.resume()
    await login.value
    #expect(f.host.phase == .suspended)
    #expect(await f.api.logins == 0)
    f.host.stop()
}

@Test @MainActor func activeSceneNotificationDuringAppleSheetDoesNotCancelIt() async throws {
    let f = HostFixture()
    await f.host.activate()
    f.authorizer.hold = true
    let login = Task { await f.host.signIn() }
    try await waitForHost { f.authorizer.waiter != nil }
    let cancellations = f.authorizer.cancellations
    await f.host.activate()
    #expect(f.host.phase == .signingIn)
    #expect(f.authorizer.cancellations == cancellations)
    try f.authorizer.resume()
    await login.value
    #expect(f.host.phase == .ready)
    f.host.stop()
}

@Test @MainActor func oldGatewayResponseCannotReplaceANewlyBoundIdentity() async throws {
    let f = HostFixture()
    await f.host.activate()
    await f.api.holdLogin()
    let oldLogin = Task { await f.host.signIn() }
    try await waitForHost { await f.api.waitingForLogin() }
    f.center.post(name: .CKAccountChanged, object: nil)
    f.cloud.name = "cloud-B"
    await f.host.signIn()
    #expect(f.host.phase == .ready)
    await f.api.resumeLogin()
    await oldLogin.value
    #expect(f.host.phase == .ready)
    #expect(try await f.host.accessToken() == hostPair("2").sessionToken)
    #expect(await f.api.loggedOut == [(try hostPair("1")).renewalToken])
    f.host.stop()
}

@Test @MainActor func expiredUIValidationChecksCredentialsAgainBeforeReturningAccess() async throws {
    let f = HostFixture()
    await f.signIn()
    f.clock.advance(61)
    f.apple.state = .revoked
    await #expect(throws: GatewayFailure.signInRequired) { try await f.host.accessToken() }
    #expect(f.host.phase == .signedOut)
    #expect(try f.storage.savedState() == .signedOut)
    f.host.stop()
}

@Test @MainActor func disabledHostCannotStartNativeIdentityOrNetworkCalls() async {
    let f = HostFixture()
    f.policy.enabled = false
    await f.host.activate()
    await f.host.signIn()
    #expect(f.host.phase == .unavailable)
    #expect(f.cloud.requests == 0)
    #expect(f.apple.requests == 0)
    #expect(f.authorizer.requests == 0)
    #expect(await f.api.challenges == 0)
    f.host.stop()
}

@Test @MainActor func activationExpiryClosesAuthenticatedUIAndDomainAccess() async throws {
    let f = HostFixture()
    await f.signIn()
    f.policy.enabled = false
    await #expect(throws: GatewayFailure.configuration) { try await f.host.accessToken() }
    #expect(f.host.phase == .unavailable)
    #expect(f.host.accountID == nil)
    f.host.stop()
}

@Test @MainActor func unexpectedCloudRevisionCannotLeaveAuthenticatedUIVisible() async throws {
    let f = HostFixture()
    await f.signIn()
    f.host.cloudKitAccount.invalidate()
    await #expect(throws: GatewayFailure.accountMismatch) { try await f.host.accessToken() }
    #expect(f.host.phase == .signedOut)
    #expect(f.host.accountID == nil)
    #expect(try f.storage.savedState() == .signedOut)
    f.host.stop()
}

@Test @MainActor func pendingLogoutBarrierCannotEraseTheNextLogin() async throws {
    let f = HostFixture()
    await f.signIn()
    await f.api.holdLogout()
    let logout = Task { await f.host.signOut() }
    try await waitForHost { await f.api.waitingForLogout() }
    f.center.post(name: .CKAccountChanged, object: nil)
    let login = Task { await f.host.signIn() }
    await f.api.resumeLogout()
    await logout.value
    await login.value
    #expect(f.host.phase == .ready)
    #expect(try f.storage.savedState() == .ready)
    #expect(try await f.host.accessToken() == hostPair("2").sessionToken)
    f.host.stop()
}

@Test @MainActor func stoppingHostRemovesItsIdentityObservers() async {
    let f = HostFixture()
    await f.signIn()
    f.host.stop()
    let revision = f.host.cloudKitAccount.identityRevision
    f.center.post(name: .CKAccountChanged, object: nil)
    #expect(f.host.phase == .suspended)
    #expect(f.host.cloudKitAccount.identityRevision == revision)
}

@Test @MainActor func notificationCleanupFailureReportsStorageErrorWithoutReopeningUI() async throws {
    let f = HostFixture()
    await f.signIn()
    f.storage.failWrites()
    f.center.post(name: .CKAccountChanged, object: nil)
    #expect(f.host.accountID == nil)
    try await waitForHost { f.host.phase == .unavailable }
    #expect(f.host.errorMessage == GatewayFailure.storageUnavailable.localizedDescription)
    await #expect(throws: GatewayFailure.signInRequired) { try await f.host.accessToken() }
    f.host.stop()
}

private func activationInfo(expires: Date = hostNow.addingTimeInterval(3_600)) -> [String: Any] {
    [
        "EchoesGatewayDevelopment": [
            "enabled": true, "origin": "https://host.example.invalid",
            "expiresAt": ISO8601DateFormatter().string(from: expires), "container": "iCloud.mpvEcho.Echo",
        ]
    ]
}

@Test @MainActor func sessionLimitOffersExplicitFreshProofRecoveryWithoutAutomaticLogin() async throws {
    let f = HostFixture()
    await f.api.setLoginLimited()
    await f.signIn()
    #expect(f.host.canResetSessions)
    #expect(f.host.phase == .unavailable)
    #expect(await f.api.resets.isEmpty)
    #expect(f.authorizer.requests == 1)
    await f.host.resetSessions()
    #expect(f.host.resetCompleted)
    #expect(!f.host.canResetSessions)
    #expect(f.host.phase == .signedOut)
    #expect(try f.storage.savedState() == .signedOut)
    #expect(await f.api.purposes == [.login, .sessionReset])
    #expect(await f.api.logins == 1)  // Reset cannot silently log in with its unused Apple code.
    await f.host.signIn()
    #expect(f.host.phase == .ready)
    #expect(await f.api.purposes == [.login, .sessionReset, .login])
    f.host.stop()
}

@Test @MainActor func resetCannotTargetADifferentAppleAccountOrCloudKitBinding() async {
    for switchApple in [true, false] {
        let f = HostFixture()
        await f.api.setLoginLimited()
        await f.signIn()
        if switchApple { f.authorizer.userID = "apple-B" } else { f.cloud.name = "cloud-B" }
        await f.host.resetSessions()
        #expect(await f.api.resets.isEmpty)
        #expect(!f.host.canResetSessions)
        #expect(!f.host.resetCompleted)
        #expect(f.host.phase == .signedOut)
        f.host.stop()
    }
}

@Test @MainActor func identityNotificationRemovesAnotherAccountsRecoveryIntent() async {
    let f = HostFixture()
    await f.api.setLoginLimited()
    await f.signIn()
    f.center.post(name: .CKAccountChanged, object: nil)
    #expect(!f.host.canResetSessions)
    await f.host.resetSessions()
    #expect(await f.api.resets.isEmpty)
    f.host.stop()
}

@Test @MainActor func uncertainResetNeverRetriesAutomaticallyAndRequiresANewChallenge() async {
    let f = HostFixture()
    await f.api.setLoginLimited()
    await f.signIn()
    await f.api.setResetFailure(.transport)
    await f.host.resetSessions()
    #expect(!f.host.resetCompleted)
    #expect(f.host.canResetSessions)
    #expect(await f.api.resets.count == 1)
    await f.host.activate()
    #expect(await f.api.resets.count == 1)
    await f.api.setResetFailure(nil)
    await f.host.resetSessions()
    let attempts = await f.api.resets
    #expect(attempts.count == 2)
    #expect(Set(attempts).count == 2)
    #expect(f.host.resetCompleted)
    f.host.stop()
}

@Test @MainActor func foregroundDoesNotCancelResetSheetAndBackgroundFencesItsLateProof() async throws {
    let f = HostFixture()
    await f.api.setLoginLimited()
    await f.signIn()
    f.authorizer.hold = true
    let reset = Task { await f.host.resetSessions() }
    try await waitForHost { f.authorizer.waiter != nil }
    await f.host.activate()
    #expect(f.host.phase == .resettingSessions)
    f.host.suspend()
    try f.authorizer.resume()
    await reset.value
    #expect(await f.api.resets.isEmpty)
    #expect(!f.host.resetCompleted)
    #expect(f.host.phase == .suspended)
    f.host.stop()
}

@Test @MainActor func lateResetAcknowledgementCannotReplaceANewLogin() async throws {
    let f = HostFixture()
    await f.api.setLoginLimited()
    await f.signIn()
    await f.api.holdReset()
    let reset = Task { await f.host.resetSessions() }
    try await waitForHost { await f.api.waitingForReset() }
    f.host.suspend()
    await f.host.activate()
    await f.host.signIn()
    #expect(f.host.phase == .ready)
    await f.api.resumeReset()
    await reset.value
    #expect(f.host.phase == .ready)
    #expect(!f.host.resetCompleted)
    #expect(try await f.host.accessToken() == hostPair("2").sessionToken)
    f.host.stop()
}

@Test @MainActor func recoveryCannotBeInvokedWithoutTheFailedLoginContext() async {
    let f = HostFixture()
    await f.host.activate()
    await f.host.resetSessions()
    #expect(f.authorizer.requests == 0)
    #expect(await f.api.resets.isEmpty)
    f.host.stop()
}

@Test @MainActor func recoveryStopsOfferingResetWhenServerReportsBanDeletionOrNoAccount() async {
    for code in [GatewayErrorCode.accountDisabled, .deletionInProgress, .noAccount] {
        let f = HostFixture()
        await f.api.setLoginLimited()
        await f.signIn()
        await f.api.setResetFailure(
            .server(code, status: code == .noAccount ? 404 : 403, retryAfterSeconds: nil))
        await f.host.resetSessions()
        #expect(!f.host.canResetSessions)
        #expect(!f.host.resetCompleted)
        #expect(f.host.accountID == nil)
        f.host.stop()
    }
}

@Test func bundledActivationRejectsMissingExpiredForeignAndLongLivedConfiguration() throws {
    #expect(throws: GatewayFailure.configuration) {
        try GatewayDevelopmentActivation(infoDictionary: [:], bundleIdentifier: "mpvEcho.Echo", now: hostNow)
    }
    for date in [hostNow, hostNow.addingTimeInterval(-1), hostNow.addingTimeInterval(7 * 86_400 + 1)] {
        #expect(throws: GatewayFailure.configuration) {
            try GatewayDevelopmentActivation(
                infoDictionary: activationInfo(expires: date), bundleIdentifier: "mpvEcho.Echo", now: hostNow)
        }
    }
    #expect(throws: GatewayFailure.configuration) {
        try GatewayDevelopmentActivation(
            infoDictionary: activationInfo(), bundleIdentifier: "other.app", now: hostNow)
    }
    let valid = try GatewayDevelopmentActivation(
        infoDictionary: activationInfo(), bundleIdentifier: "mpvEcho.Echo", now: hostNow)
    #expect(valid.isActive(at: hostNow))
    #expect(!valid.isActive(at: hostNow.addingTimeInterval(3_600)))
    #expect(!valid.isActive(at: hostNow.addingTimeInterval(-31)))
}

@Test func activationAlsoGuardsLateAPIAndCleanupAfterWindowExpiry() async throws {
    let clock = HostClock()
    let api = HostAPI()
    let activation = try GatewayDevelopmentActivation(
        infoDictionary: activationInfo(), bundleIdentifier: "mpvEcho.Echo", now: hostNow)
    let gated = try ActivatedGatewayAuthenticationAPI(api: api, activation: activation, now: { clock.now() })
    _ = try await gated.challenge(purpose: .login)
    clock.advance(3_600)
    await #expect(throws: GatewayFailure.configuration) { try await gated.challenge(purpose: .login) }
    await #expect(throws: GatewayFailure.configuration) {
        try await gated.logout(token: GatewaySecret("synthetic-token"))
    }
    await #expect(throws: GatewayFailure.configuration) {
        try await gated.resetSessions(
            challengeID: UUID().uuidString.lowercased(), identityToken: GatewaySecret("synthetic-token"),
            expectedAccountID: nil)
    }
    #expect(await api.challenges == 1)
    #expect(await api.loggedOut.isEmpty)
}
