import Foundation

/// Minimal protected local recovery metadata. Target binds a future presentation fence; it is
/// not a new authorization, publication grant or HTTP field. No reason, pixels or receipt is stored.
public struct GatewayAvatarReportReviewSavedIntent: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let recovery: GatewayAvatarReportReviewRecoveryIntent
    public let photoTarget: GatewayAvatarReportReviewPhotoTarget?
    public init(decision: GatewayAvatarReportReviewDecisionIntent) throws {
        try self.init(recovery: .init(decision: decision), photoTarget: decision.receipt.photoTarget)
    }
    init(
        recovery: GatewayAvatarReportReviewRecoveryIntent, photoTarget: GatewayAvatarReportReviewPhotoTarget?
    ) throws {
        guard recovery.verdict != .hidePhoto || photoTarget != nil else {
            throw GatewayAvatarReportReviewJournalFailure.unavailable
        }
        self.recovery = recovery
        self.photoTarget = photoTarget
    }
    var reportID: String { recovery.reportID }
    var decisionID: String { recovery.decisionID }
    var verdict: GatewayAvatarReportReviewVerdict { recovery.verdict }
    var contentHash: String { recovery.contentHash }
    public var description: String { "GatewayAvatarReportReviewSavedIntent(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
