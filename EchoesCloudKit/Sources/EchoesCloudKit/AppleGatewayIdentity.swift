import AuthenticationServices
import Foundation

public enum AppleGatewayCredentialState: Equatable, Sendable {
    case authorized, revoked, notFound, transferred
}

@MainActor
public protocol AppleGatewayIdentitySource {
    func credentialState(userID: String) async throws -> AppleGatewayCredentialState
}

@MainActor
public final class NativeAppleGatewayIdentitySource: AppleGatewayIdentitySource {
    public init() {}
    public func credentialState(userID: String) async throws -> AppleGatewayCredentialState {
        do {
            switch try await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID) {
            case .authorized: return .authorized
            case .revoked: return .revoked
            case .notFound: return .notFound
            case .transferred: return .transferred
            @unknown default: throw GatewayFailure.transport
            }
        } catch { throw GatewayFailure.transport }
    }
}

@MainActor
public protocol AppleGatewayAuthorizer {
    func authorize(challenge: GatewayChallenge) async throws -> AppleGatewayProof
    func cancel()
}
