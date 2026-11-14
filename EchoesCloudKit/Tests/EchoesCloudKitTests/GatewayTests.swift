import AuthenticationServices
import Foundation
import Testing

@testable import EchoesCloudKit

private let testNow = Date(timeIntervalSince1970: 1_800_000_000)
private let testAccount = "10000000-0000-4000-8000-000000000001"
private let challengeID = "20000000-0000-4000-8000-000000000002"

private func testChallenge() throws -> GatewayChallenge {
    .init(
        protocolVersion: 1, challengeID: challengeID,
        nonce: try GatewaySecret(String(repeating: "a", count: 43)),
        expiresAt: Int(testNow.timeIntervalSince1970) + 300)
}
private func sessionPair(suffix: String = "old", account: String = testAccount, lifetime: Int = 60) throws
    -> GatewaySessionPair
{
    .init(
        protocolVersion: 1, accountID: account, sessionToken: try GatewaySecret("access-" + suffix),
        expiresAt: Int(testNow.timeIntervalSince1970) + lifetime,
        renewalToken: try GatewaySecret("renew-" + suffix),
        renewalExpiresAt: Int(testNow.timeIntervalSince1970) + 3_600)
}
private func binding(_ account: String = "A") throws -> GatewayIdentityBinding {
    try .init(appleUserID: "apple-" + account, cloudKitRecordName: "cloudkit-" + account)
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = testNow
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}
private final class MemorySessionStorage: GatewaySessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var rejectWrites = false
    init(_ data: Data? = nil) { self.data = data }
    func read() throws -> Data? { lock.withLock { data } }
    func write(_ data: Data) throws {
        try lock.withLock {
            if rejectWrites { throw GatewayFailure.storageUnavailable }
            self.data = data
        }
    }
    func failWrites() { lock.withLock { rejectWrites = true } }
    func saved() throws -> StoredGatewaySession? {
        try read().map { try JSONDecoder().decode(StoredGatewaySession.self, from: $0) }
    }
}

private actor AuthenticationFake: GatewayAuthenticationAPI {
    nonisolated let origin = "https://gateway.example.invalid"
    let initial: GatewaySessionPair
    var rotated: GatewaySessionPair
    var holdLogin = false, holdRenewal = false, failRenewal = false, failLogout = false
    var loginCalls = 0, renewCalls = 0, statusCalls = 0
    var logoutTokens: [GatewaySecret] = []
    var loginWaiter: CheckedContinuation<GatewaySessionPair, any Error>?
    var renewalWaiter: CheckedContinuation<GatewaySessionPair, any Error>?
    init() throws {
        initial = try sessionPair()
        rotated = try sessionPair(suffix: "new", lifetime: 600)
    }
    func setHoldLogin() { holdLogin = true }
    func setHoldRenewal() { holdRenewal = true }
    func setRenewalFailure() { failRenewal = true }
    func setLogoutFailure() { failLogout = true }
    func setRotatedAccount(_ account: String) throws {
        rotated = try sessionPair(suffix: "other", account: account, lifetime: 600)
    }
    func challenge(purpose: GatewayChallengePurpose) async throws -> GatewayChallenge { try testChallenge() }
    func login(challengeID: String, identityToken: GatewaySecret, authorizationCode: GatewaySecret)
        async throws -> GatewaySessionPair
    {
        loginCalls += 1
        if holdLogin { return try await withCheckedThrowingContinuation { loginWaiter = $0 } }
        return initial
    }
    func renew(token: GatewaySecret) async throws -> GatewaySessionPair {
        renewCalls += 1
        if failRenewal { throw GatewayFailure.transport }
        if holdRenewal { return try await withCheckedThrowingContinuation { renewalWaiter = $0 } }
        return rotated
    }
    func session(token: GatewaySecret) async throws -> GatewaySessionStatus {
        statusCalls += 1
        return .init(protocolVersion: 1, accountID: initial.accountID, expiresAt: initial.expiresAt)
    }
    func logout(token: GatewaySecret) async throws {
        logoutTokens.append(token)
        if failLogout { throw GatewayFailure.transport }
    }
    func logoutAll(token: GatewaySecret) async throws { try await logout(token: token) }
    func resumeLogin() {
        loginWaiter?.resume(returning: initial)
        loginWaiter = nil
    }
    func resumeRenewal() {
        renewalWaiter?.resume(returning: rotated)
        renewalWaiter = nil
    }
    func waitingForLogin() -> Bool { loginWaiter != nil }
    func waitingForRenewal() -> Bool { renewalWaiter != nil }
}

private struct Fixture {
    let api: AuthenticationFake
    let storage = MemorySessionStorage()
    let clock = TestClock()
    let controller: GatewaySessionController
    init() throws {
        api = try AuthenticationFake()
        controller = GatewaySessionController(api: api, storage: storage, now: { [clock] in clock.now() })
    }
    func signIn() async throws {
        try await controller.signIn(
            challenge: testChallenge(), identityToken: GatewaySecret("synthetic-identity"),
            authorizationCode: GatewaySecret("synthetic-code"), verifiedBinding: binding())
    }
}
private func waitUntil(_ predicate: @escaping () async -> Bool) async throws {
    for _ in 0..<10_000 {
        if await predicate() { return }
        await Task.yield()
    }
    throw GatewayFailure.transport
}

@Test func gatewaySecretsRejectHeaderInjectionAndRedactDiagnostics() throws {
    let secret = try GatewaySecret("do-not-log-this-secret")
    #expect(!String(describing: secret).contains(secret.value))
    #expect(!String(reflecting: secret).contains(secret.value))
    #expect(Mirror(reflecting: secret).children.isEmpty)
    for invalid in ["", "bearer\r\ninjected", "has space", "żółć", String(repeating: "a", count: 16_385)] {
        #expect(throws: GatewayFailure.self) { try GatewaySecret(invalid) }
    }
}

@Test func gatewaySessionIsAtomicAndRevalidatedOnRestore() async throws {
    let fixture = try Fixture()
    try await fixture.signIn()
    let saved = try #require(try fixture.storage.saved())
    #expect(saved.state == .ready)
    #expect(saved.pair == (try sessionPair()))
    let restored = GatewaySessionController(api: fixture.api, storage: fixture.storage, now: { testNow })
    try await restored.restore(verifiedBinding: binding())
    #expect(await fixture.api.statusCalls == 1)
    #expect(await restored.state == .ready(accountID: testAccount))
    #expect(try await restored.accessToken() == sessionPair().sessionToken)
}

@Test func concurrentAccessUsesOneRotationAndReplacesBothTokens() async throws {
    let fixture = try Fixture()
    try await fixture.signIn()
    fixture.clock.advance(40)
    await fixture.api.setHoldRenewal()
    let first = Task { try await fixture.controller.accessToken() }
    try await waitUntil { await fixture.api.waitingForRenewal() }
    let second = Task { try await fixture.controller.accessToken() }
    #expect(try fixture.storage.saved()?.state == .renewalPending)
    #expect(try fixture.storage.saved()?.pair == nil)
    await fixture.api.resumeRenewal()
    #expect(try await first.value == second.value)
    #expect(await fixture.api.renewCalls == 1)
    #expect(try fixture.storage.saved()?.pair == sessionPair(suffix: "new", lifetime: 600))
}

@Test func lostRotationResponseNeverReplaysOldProofEvenAfterRestart() async throws {
    let fixture = try Fixture()
    try await fixture.signIn()
    fixture.clock.advance(40)
    await fixture.api.setRenewalFailure()
    await #expect(throws: GatewayFailure.transport) { try await fixture.controller.accessToken() }
    await #expect(throws: GatewayFailure.signInRequired) { try await fixture.controller.accessToken() }
    let restored = GatewaySessionController(
        api: fixture.api, storage: fixture.storage, now: { fixture.clock.now() })
    await #expect(throws: GatewayFailure.signInRequired) {
        try await restored.restore(verifiedBinding: binding())
    }
    #expect(await fixture.api.renewCalls == 1)
    #expect(await fixture.api.statusCalls == 0)
    #expect(try fixture.storage.saved()?.state == .signedOut)
}

@Test func cancelledCallerDoesNotCancelSharedRotationOrReceiveAToken() async throws {
    let fixture = try Fixture()
    try await fixture.signIn()
    fixture.clock.advance(40)
    await fixture.api.setHoldRenewal()
    let first = Task { try await fixture.controller.accessToken() }
    try await waitUntil { await fixture.api.waitingForRenewal() }
    let second = Task { try await fixture.controller.accessToken() }
    first.cancel()
    await fixture.api.resumeRenewal()
    await #expect(throws: GatewayFailure.cancelled) { try await first.value }
    #expect(try await second.value == sessionPair(suffix: "new", lifetime: 600).sessionToken)
    #expect(await fixture.api.renewCalls == 1)
    #expect(await fixture.controller.state == .ready(accountID: testAccount))
}

@Test func lateLoginCannotRestoreAccountAfterInvalidation() async throws {
    let fixture = try Fixture()
    await fixture.api.setHoldLogin()
    let login = Task { try await fixture.signIn() }
    try await waitUntil { await fixture.api.waitingForLogin() }
    try await fixture.controller.invalidateForAccountChange()
    await fixture.api.resumeLogin()
    await #expect(throws: GatewayFailure.superseded) { try await login.value }
    #expect(await fixture.controller.state == .signInRequired)
    #expect(try fixture.storage.saved()?.pair == nil)
    #expect(await fixture.api.logoutTokens.count == 1)
}

@Test func signOutDuringRotationFencesAndRevokesLateResult() async throws {
    let fixture = try Fixture()
    try await fixture.signIn()
    fixture.clock.advance(40)
    await fixture.api.setHoldRenewal()
    let renewal = Task { try await fixture.controller.accessToken() }
    try await waitUntil { await fixture.api.waitingForRenewal() }
    #expect(try await fixture.controller.signOut() == .serverConfirmed)
    await fixture.api.resumeRenewal()
    await #expect(throws: GatewayFailure.superseded) { try await renewal.value }
    #expect(await fixture.controller.state == .signedOut)
    #expect(try fixture.storage.saved()?.state == .signedOut)
    #expect(await fixture.api.logoutTokens.count == 2)
}

@Test func changedCloudKitOrAppleAccountCannotRestoreStoredSession() async throws {
    for changed in [
        try binding("B"),
        try GatewayIdentityBinding(appleUserID: "apple-A", cloudKitRecordName: "cloudkit-B"),
    ] {
        let fixture = try Fixture()
        try await fixture.signIn()
        let restored = GatewaySessionController(api: fixture.api, storage: fixture.storage, now: { testNow })
        await #expect(throws: GatewayFailure.signInRequired) {
            try await restored.restore(verifiedBinding: changed)
        }
        #expect(await fixture.api.statusCalls == 0)
        #expect(try fixture.storage.saved()?.pair == nil)
    }
}

@Test func failedKeychainWritePreventsDispatchAndDurableLogoutIsNotClaimed() async throws {
    let fixture = try Fixture()
    try await fixture.signIn()
    fixture.clock.advance(40)
    fixture.storage.failWrites()
    await #expect(throws: GatewayFailure.storageUnavailable) { try await fixture.controller.accessToken() }
    #expect(await fixture.api.renewCalls == 0)
    await #expect(throws: GatewayFailure.storageUnavailable) { try await fixture.controller.signOut() }
    #expect(await fixture.controller.state == .storageBlocked)
    await #expect(throws: GatewayFailure.storageUnavailable) { try await fixture.controller.accessToken() }
}

@Test func remoteLogoutFailureStillPersistsLocalSignOut() async throws {
    let fixture = try Fixture()
    try await fixture.signIn()
    await fixture.api.setLogoutFailure()
    #expect(try await fixture.controller.signOut() == .localOnly)
    #expect(try fixture.storage.saved()?.state == .signedOut)
    let restored = GatewaySessionController(api: fixture.api, storage: fixture.storage, now: { testNow })
    try await restored.restore(verifiedBinding: binding())
    #expect(await restored.state == .signedOut)
    #expect(await fixture.api.statusCalls == 0)
}

@Test func signOutAfterRestartRevokesStoredGrantWithoutRestoringItsAccess() async throws {
    let fixture = try Fixture()
    try await fixture.signIn()
    let restarted = GatewaySessionController(api: fixture.api, storage: fixture.storage, now: { testNow })
    #expect(try await restarted.signOut() == .serverConfirmed)
    #expect(await fixture.api.statusCalls == 0)
    #expect(await fixture.api.logoutTokens == [(try sessionPair()).renewalToken])
    #expect(try fixture.storage.saved()?.state == .signedOut)
}

@Test func signOutAfterUnknownRotationNeverClaimsServerConfirmation() async throws {
    let fixture = try Fixture()
    try await fixture.signIn()
    fixture.clock.advance(40)
    await fixture.api.setRenewalFailure()
    await #expect(throws: GatewayFailure.transport) { try await fixture.controller.accessToken() }
    let restarted = GatewaySessionController(
        api: fixture.api, storage: fixture.storage, now: { fixture.clock.now() })
    #expect(try await restarted.signOut() == .localOnly)
    #expect(try fixture.storage.saved()?.state == .signedOut)
}

@Test func rotationCannotSwitchServerAccount() async throws {
    let fixture = try Fixture()
    try await fixture.signIn()
    fixture.clock.advance(40)
    try await fixture.api.setRotatedAccount("10000000-0000-4000-8000-000000000099")
    await #expect(throws: GatewayFailure.accountMismatch) { try await fixture.controller.accessToken() }
    #expect(await fixture.controller.state == .signInRequired)
    #expect(try fixture.storage.saved()?.state == .renewalPending)
}

@Test func malformedOrWrongOriginStorageFailsClosed() async throws {
    let api = try AuthenticationFake()
    let bytes = try JSONEncoder().encode(
        StoredGatewaySession(
            version: 1, origin: "https://other.example.invalid",
            binding: binding(), state: .ready, pair: sessionPair()))
    for data in [bytes, Data("garbled".utf8), Data(repeating: 1, count: 8_193)] {
        let controller = GatewaySessionController(
            api: api, storage: MemorySessionStorage(data), now: { testNow })
        await #expect(throws: GatewayFailure.storageUnavailable) {
            try await controller.restore(verifiedBinding: binding())
        }
        #expect(await controller.state == .storageBlocked)
    }
    #expect(await api.statusCalls == 0)
    #expect(await api.renewCalls == 0)
}

@Test @MainActor func appleRequestBindsStateAndHashesTheRawNonceString() throws {
    let attempt = try AppleGatewayAuthorizationAttempt(challenge: testChallenge(), now: { testNow })
    let request = try attempt.makeRequest()
    #expect(request.requestedScopes?.isEmpty == true)
    // Independent SHA256 fixture: 43 ASCII 'a' characters, not the 32 decoded base64url bytes.
    #expect(request.nonce == "66d34fba71f8f450f7e45598853e53bfc23bbd129027cbb131a2f4ffd7878cd0")
    #expect(request.state == attempt.state)
    let proof = try attempt.complete(
        userID: "apple-A", state: attempt.state,
        identityToken: Data("synthetic-identity".utf8), authorizationCode: Data("synthetic-code".utf8))
    #expect(proof.appleUserID == "apple-A")
    #expect(throws: GatewayFailure.superseded) {
        try attempt.complete(
            userID: "apple-A", state: attempt.state,
            identityToken: Data("synthetic-identity".utf8), authorizationCode: Data("synthetic-code".utf8))
    }
}

@Test @MainActor func appleWrongStateMissingCodeAndCancellationNeverYieldProof() throws {
    for returnedState in [nil, "wrong"] as [String?] {
        let attempt = try AppleGatewayAuthorizationAttempt(challenge: testChallenge(), now: { testNow })
        #expect(throws: GatewayFailure.invalidInput) {
            try attempt.complete(
                userID: "apple-A", state: returnedState,
                identityToken: Data("synthetic-identity".utf8), authorizationCode: Data("synthetic-code".utf8)
            )
        }
        #expect(throws: GatewayFailure.superseded) { try attempt.makeRequest() }
    }
    let attempt = try AppleGatewayAuthorizationAttempt(challenge: testChallenge(), now: { testNow })
    #expect(throws: GatewayFailure.invalidInput) {
        try attempt.complete(
            userID: "apple-A", state: attempt.state, identityToken: Data("x".utf8), authorizationCode: nil)
    }
    let cancelled = try AppleGatewayAuthorizationAttempt(challenge: testChallenge(), now: { testNow })
    cancelled.cancel()
    #expect(throws: GatewayFailure.superseded) { try cancelled.makeRequest() }
}

private actor HTTPFake: GatewayHTTPTransport {
    var requests: [URLRequest] = []
    let response: GatewayHTTPResponse
    init(status: Int = 200, contentType: String? = "application/json", retryAfter: String? = nil, body: Data)
    {
        response = .init(status: status, contentType: contentType, retryAfter: retryAfter, body: body)
    }
    func send(_ request: URLRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        return response
    }
}
private func makeClient(_ fake: HTTPFake) throws -> GatewayHTTPClient {
    try .init(
        configuration: GatewayConfiguration(origin: URL(string: "https://gateway.example.invalid")!),
        transport: fake, now: { testNow })
}

@Test func gatewayOriginRejectsCredentialsQueriesPortsAndNonHTTPS() throws {
    for text in [
        "http://gateway.example.invalid", "https://user:password@gateway.example.invalid",
        "https://gateway.example.invalid?x=1", "https://gateway.example.invalid/#x",
        "https://gateway.example.invalid/path",
        "https://gateway.example.invalid:443", "https://127.0.0.1", "https://localhost",
        "https://-bad.example.invalid",
    ] {
        #expect(throws: GatewayFailure.configuration) { try GatewayConfiguration(origin: URL(string: text)!) }
    }
    #expect(
        try GatewayConfiguration(origin: URL(string: "https://gateway.example.invalid/")!).origin
            .absoluteString
            == "https://gateway.example.invalid")
}

@Test func httpClientUsesClosedPOSTContractWithoutSecretsInURL() async throws {
    let fake = HTTPFake(body: try JSONEncoder().encode(sessionPair()))
    let client = try makeClient(fake)
    let result = try await client.login(
        challengeID: challengeID,
        identityToken: GatewaySecret("synthetic-identity"), authorizationCode: GatewaySecret("synthetic-code")
    )
    #expect(result == (try sessionPair()))
    let requests = await fake.requests
    let request = try #require(requests.first)
    #expect(request.url?.absoluteString == "https://gateway.example.invalid/v1/auth/login")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
    #expect(Set(body.keys) == ["challengeID", "identityToken", "authorizationCode"])
    #expect(body["authorizationCode"] == "synthetic-code")
    #expect(requests.count == 1)
}

@Test func httpClientRejectsRedirectHTMLBadVersionAndOversizedReplies() async throws {
    let good = try JSONEncoder().encode(sessionPair())
    let wrongVersion = Data(
        String(decoding: good, as: UTF8.self).replacingOccurrences(
            of: "\"protocolVersion\":1", with: "\"protocolVersion\":2"
        ).utf8)
    let cases = [
        HTTPFake(status: 302, body: good), HTTPFake(contentType: "text/html", body: good),
        HTTPFake(body: wrongVersion), HTTPFake(body: Data(repeating: 1, count: 32_769)),
        HTTPFake(body: Data("{}".utf8)),
    ]
    for fake in cases {
        let client = try makeClient(fake)
        await #expect(throws: GatewayFailure.invalidResponse) {
            try await client.renew(token: GatewaySecret("synthetic-renew"))
        }
        #expect(await fake.requests.count == 1)
    }
}

@Test func serverErrorIsRedactedAndRetryAfterNeverTriggersRetry() async throws {
    let fake = HTTPFake(
        status: 409, retryAfter: "5", body: Data("{\"protocolVersion\":1,\"error\":\"RENEWAL_BUSY\"}".utf8))
    let client = try makeClient(fake)
    await #expect(throws: GatewayFailure.server(.renewalBusy, status: 409, retryAfterSeconds: 5)) {
        try await client.renew(token: GatewaySecret("synthetic-renew"))
    }
    #expect(await fake.requests.count == 1)
    let unknown = HTTPFake(
        status: 503, retryAfter: "-999",
        body: Data("{\"protocolVersion\":1,\"error\":\"private-server-secret\"}".utf8))
    let other = try makeClient(unknown)
    do {
        _ = try await other.renew(token: GatewaySecret("x"))
        Issue.record("Expected error")
    } catch { #expect(!String(reflecting: error).contains("private-server-secret")) }
}

@Test func httpLogoutRequiresAnEmpty204AndKeepsProofInHeaderOnly() async throws {
    let fake = HTTPFake(status: 204, contentType: nil, body: Data())
    try await makeClient(fake).logout(token: GatewaySecret("synthetic-renew"))
    let request = try #require(await fake.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-renew")
    #expect(request.httpBody == Data("{}".utf8))
    let malformed = HTTPFake(status: 204, body: Data("secret".utf8))
    await #expect(throws: GatewayFailure.invalidResponse) {
        try await makeClient(malformed).logout(token: GatewaySecret("synthetic-renew"))
    }
}
