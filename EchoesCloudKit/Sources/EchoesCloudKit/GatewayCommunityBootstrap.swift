import Foundation
import Observation

/// Reads only protected metadata before a new community domain can admit avatar reads.
/// Invalidation revokes the result, but keeps the opening slot until both dependencies return.
@MainActor @Observable public final class GatewayCommunityBootstrap {
    public struct Pending: Sendable {
        public let upload: GatewayAvatarReviewRecoveryIntent?
        public let reportedPhoto: GatewayAvatarReportReviewSavedIntent?
        fileprivate let lifetime: UUID
    }
    public private(set) var isOpening = false
    @ObservationIgnored private var lifetime = UUID()
    @ObservationIgnored private let upload:
        @MainActor (GatewayAvatarReviewScope) async throws -> GatewayAvatarReviewJournalEntry?
    @ObservationIgnored private let reportedPhoto:
        @MainActor (GatewayAvatarReportReviewScope) async throws -> GatewayAvatarReportReviewJournalEntry?

    public convenience init(
        upload: GatewayAvatarReviewJournal, reportedPhoto: GatewayAvatarReportReviewJournal
    ) {
        self.init(
            upload: { try await upload.peek(scope: $0) },
            reportedPhoto: { try await reportedPhoto.peek(scope: $0) })
    }
    init(
        upload:
            @escaping @MainActor (GatewayAvatarReviewScope) async throws -> GatewayAvatarReviewJournalEntry?,
        reportedPhoto:
            @escaping @MainActor (GatewayAvatarReportReviewScope) async throws ->
            GatewayAvatarReportReviewJournalEntry?
    ) {
        self.upload = upload
        self.reportedPhoto = reportedPhoto
    }
    public func invalidate() { lifetime = UUID() }
    public func isCurrent(_ pending: Pending) -> Bool { pending.lifetime == lifetime }

    /// The caller must synchronously close its previous presentation before calling this method.
    /// No lease rotation, writes, domain construction, networking or restoration of pixels occurs here.
    public func load(
        configuration: GatewayConfiguration, owner: PrivateAccountScope, binding: GatewayIdentityBinding,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> Pending {
        guard !isOpening else { throw GatewayCommunityFailure.busy }
        isOpening = true
        lifetime = UUID()
        let expected = lifetime
        defer { isOpening = false }
        func check() throws {
            try Task.checkCancellation()
            guard lifetime == expected, isCurrent(), lifetime == expected else {
                throw GatewayCommunityFailure.superseded
            }
            try Task.checkCancellation()
        }
        try check()
        let uploadScope = try GatewayAvatarReviewScope(
            configuration: configuration, owner: owner, binding: binding)
        let photoScope = try GatewayAvatarReportReviewScope(
            configuration: configuration, owner: owner, binding: binding)
        let uploadEntry = try await upload(uploadScope)
        try check()
        let photoEntry = try await reportedPhoto(photoScope)
        try check()
        return .init(upload: uploadEntry?.intent, reportedPhoto: photoEntry?.intent, lifetime: expected)
    }
}
