import Foundation

/// Trusted local presentation fence; never server authorization or a publication grant.
/// Exact saved metadata keeps a reported-photo decision separate from upload moderation.
public enum GatewayAvatarReportReviewPublicationEvent: Sendable, CustomStringConvertible, CustomReflectable {
    case pending(GatewayAvatarReportReviewSavedIntent)
    case resolved(intent: GatewayAvatarReportReviewSavedIntent, outcome: GatewayAvatarReportReviewOutcome)
    public var description: String { "GatewayAvatarReportReviewPublicationEvent(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
