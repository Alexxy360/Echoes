import AuthenticationServices
import Foundation

public struct AppleGatewayProof: Sendable {
    public let appleUserID: String
    public let identityToken: GatewaySecret
    public let authorizationCode: GatewaySecret
}

/// Preparation/validation only: the host presents the native Apple sheet. Creating this object
/// neither launches authentication nor grants Sign in with Apple capability to the app.
@MainActor
public final class AppleGatewayAuthorizationAttempt {
    public let challenge: GatewayChallenge
    public let state: String
    private let now: @Sendable () -> Date
    private var consumed = false
    private var prepared = false

    public init(challenge: GatewayChallenge, now: @escaping @Sendable () -> Date = { Date() }) throws {
        try challenge.validate(now: now())
        self.challenge = challenge
        self.now = now
        state = UUID().uuidString.lowercased()
    }
    public func makeRequest() throws -> ASAuthorizationAppleIDRequest {
        guard !consumed, !prepared else { throw GatewayFailure.superseded }
        try challenge.validate(now: now())
        prepared = true
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        request.nonce = challenge.appleNonce
        request.state = state
        return request
    }
    public func complete(_ credential: ASAuthorizationAppleIDCredential) throws -> AppleGatewayProof {
        try complete(
            userID: credential.user, state: credential.state,
            identityToken: credential.identityToken, authorizationCode: credential.authorizationCode)
    }
    public func cancel() { consumed = true }

    func complete(userID: String, state: String?, identityToken: Data?, authorizationCode: Data?) throws
        -> AppleGatewayProof
    {
        guard !consumed else { throw GatewayFailure.superseded }
        consumed = true
        try challenge.validate(now: now())
        guard state == self.state, !userID.isEmpty, userID.utf8.count <= 512,
            let identityToken, identityToken.count <= 12_288,
            let identity = String(data: identityToken, encoding: .utf8),
            let authorizationCode, authorizationCode.count <= 2_048,
            let code = String(data: authorizationCode, encoding: .utf8)
        else { throw GatewayFailure.invalidInput }
        return AppleGatewayProof(
            appleUserID: userID, identityToken: try GatewaySecret(identity),
            authorizationCode: try GatewaySecret(code))
    }
}
