import Foundation

/// Read only from the app's bundled configuration. Launch environment, links and HTTP must never
/// choose the recipient of real Apple credentials. Absent/disabled configuration fails closed.
public struct GatewayDevelopmentActivation: Sendable {
    public let configuration: GatewayConfiguration
    public let cloudKit: CloudKitConfiguration
    public let expiresAt: Date
    private let initializedAt: Date
    public init(infoDictionary: [String: Any], bundleIdentifier: String?, now: Date = Date()) throws {
        guard bundleIdentifier == "mpvEcho.Echo",
            let settings = infoDictionary["EchoesGatewayDevelopment"] as? [String: Any],
            Set(settings.keys) == ["enabled", "origin", "expiresAt", "container"],
            settings["enabled"] as? Bool == true,
            let origin = settings["origin"] as? String, let url = URL(string: origin),
            let expiry = settings["expiresAt"] as? String,
            expiry.range(
                of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", options: .regularExpression)
                != nil,
            let date = ISO8601DateFormatter().date(from: expiry),
            ISO8601DateFormatter().string(from: date) == expiry,
            date > now, date.timeIntervalSince(now) <= 7 * 86_400,
            settings["container"] as? String == "iCloud.mpvEcho.Echo"
        else { throw GatewayFailure.configuration }
        configuration = try GatewayConfiguration(origin: url)
        cloudKit = try CloudKitConfiguration(
            containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
        expiresAt = date
        initializedAt = now
    }
    public func isActive(at date: Date = Date()) -> Bool {
        date < expiresAt && date >= initializedAt.addingTimeInterval(-30)
    }
}

/// Also gates each provider call made by a late task/cleanup. The UI host alone cannot enforce this.
public struct ActivatedGatewayAuthenticationAPI: GatewayAuthenticationAPI {
    private let api: any GatewayAuthenticationAPI
    private let activation: GatewayDevelopmentActivation
    private let now: @Sendable () -> Date
    public var origin: String { api.origin }
    public init(
        api: any GatewayAuthenticationAPI, activation: GatewayDevelopmentActivation,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard api.origin == activation.configuration.origin.absoluteString else {
            throw GatewayFailure.configuration
        }
        self.api = api
        self.activation = activation
        self.now = now
    }
    private func validate() throws {
        guard activation.isActive(at: now()) else { throw GatewayFailure.configuration }
    }
    public func challenge(purpose: GatewayChallengePurpose) async throws -> GatewayChallenge {
        try validate()
        return try await api.challenge(purpose: purpose)
    }
    public func login(challengeID: String, identityToken: GatewaySecret, authorizationCode: GatewaySecret)
        async throws -> GatewaySessionPair
    {
        try validate()
        return try await api.login(
            challengeID: challengeID, identityToken: identityToken, authorizationCode: authorizationCode)
    }
    public func renew(token: GatewaySecret) async throws -> GatewaySessionPair {
        try validate()
        return try await api.renew(token: token)
    }
    public func session(token: GatewaySecret) async throws -> GatewaySessionStatus {
        try validate()
        return try await api.session(token: token)
    }
    public func logout(token: GatewaySecret) async throws {
        try validate()
        try await api.logout(token: token)
    }
    public func logoutAll(token: GatewaySecret) async throws {
        try validate()
        try await api.logoutAll(token: token)
    }
    public func resetSessions(challengeID: String, identityToken: GatewaySecret, expectedAccountID: String?)
        async throws
    {
        try validate()
        try await api.resetSessions(
            challengeID: challengeID, identityToken: identityToken, expectedAccountID: expectedAccountID)
    }
}

/// Deletion uses a separate capability and remains bounded by the same trusted Development origin/window.
public struct ActivatedGatewayAccountDeletionAPI: GatewayAccountDeletionAPI {
    private let api: any GatewayAccountDeletionAPI
    private let activation: GatewayDevelopmentActivation
    private let now: @Sendable () -> Date
    public var origin: String { api.origin }
    public init(
        api: any GatewayAccountDeletionAPI, activation: GatewayDevelopmentActivation,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard api.origin == activation.configuration.origin.absoluteString else {
            throw GatewayFailure.configuration
        }
        self.api = api
        self.activation = activation
        self.now = now
    }
    private func validate() throws {
        guard activation.isActive(at: now()) else { throw GatewayFailure.configuration }
    }
    public func deletionChallenge(recovering: Bool) async throws -> GatewayChallenge {
        try validate()
        return try await api.deletionChallenge(recovering: recovering)
    }
    public func requestDeletion(ticket: GatewayDeletionTicket, proof: GatewayDeletionProof?) async throws
        -> GatewayDeletionStatus
    {
        try validate()
        return try await api.requestDeletion(ticket: ticket, proof: proof)
    }
    public func recoverDeletion(proof: GatewayDeletionProof) async throws -> GatewayRecoveredDeletion {
        try validate()
        return try await api.recoverDeletion(proof: proof)
    }
    public func deletionStatus(ticket: GatewayDeletionTicket) async throws -> GatewayDeletionStatus {
        try validate()
        return try await api.deletionStatus(ticket: ticket)
    }
    public func acknowledgePrivateCleanup(ticket: GatewayDeletionTicket) async throws -> GatewayDeletionStatus
    {
        try validate()
        return try await api.acknowledgePrivateCleanup(ticket: ticket)
    }
}
