import Foundation

/// Durable metadata for a read-only outcome query, also usable after receipt/session expiry.
/// Constructing it never authorizes a decision or proves that any photo was displayed.
public struct GatewayAvatarReviewRecoveryIntent: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let item: GatewayAvatarReviewItem
    public let decisionID: String
    public let verdict: GatewayAvatarReviewVerdict
    public init(item: GatewayAvatarReviewItem, decisionID: String, verdict: GatewayAvatarReviewVerdict) throws
    {
        guard gatewayUUID(decisionID) else { throw GatewayAvatarReviewFailure.invalidInput }
        self.item = item
        self.decisionID = decisionID
        self.verdict = verdict
    }
    public init(decision: GatewayAvatarReviewDecisionIntent) {
        item = decision.receipt.item
        decisionID = decision.decisionID
        verdict = decision.verdict
    }
    public var description: String { "GatewayAvatarReviewRecoveryIntent(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayAvatarReviewOutcome: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    case confirmed(revision: String)
    case notApplied
    case superseded
    public var description: String { "GatewayAvatarReviewOutcome(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarReviewRecoveryResult: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let intent: GatewayAvatarReviewRecoveryIntent
    public let outcome: GatewayAvatarReviewOutcome
    public var description: String { "GatewayAvatarReviewRecoveryResult(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
