import Foundation
import Observation

/// One presenter belongs to the application runtime. Old sheets can close only their own session.
@MainActor @Observable public final class GatewayAvatarReportPresenter {
    public let host: GatewayAvatarReportHost
    public private(set) var activeID: UUID?
    @ObservationIgnored private weak var active: GatewayAvatarReportSession?
    public init(host: GatewayAvatarReportHost) { self.host = host }
    public func open(
        photo: GatewayAvatarReportPhoto? = nil, ownerID: UUID? = nil,
        isCurrent: @escaping @MainActor () -> Bool
    )
        throws -> GatewayAvatarReportSession
    {
        guard isCurrent() else { throw GatewayAvatarReportHostFailure.superseded }
        invalidate()
        let value = GatewayAvatarReportSession(
            presenter: self, photo: photo, ownerID: ownerID, isCurrent: isCurrent)
        active = value
        activeID = value.id
        return value
    }
    public func invalidate() {
        active?.retire()
        active = nil
        activeID = nil
        host.setForeground(false)
    }
    public func invalidate(ownerID: UUID) {
        guard active?.ownerID == ownerID else { return }
        invalidate()
    }
    fileprivate func close(_ id: UUID) {
        guard activeID == id else { return }
        invalidate()
    }
}
@MainActor @Observable public final class GatewayAvatarReportSession: Identifiable {
    public let id = UUID()
    fileprivate let ownerID: UUID?
    public let host: GatewayAvatarReportHost
    public var hasPhoto: Bool { photo != nil }
    private let photo: GatewayAvatarReportPhoto?
    private let parentIsCurrent: @MainActor () -> Bool
    private weak var presenter: GatewayAvatarReportPresenter?
    private var closed = false
    fileprivate init(
        presenter: GatewayAvatarReportPresenter, photo: GatewayAvatarReportPhoto?, ownerID: UUID?,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        self.ownerID = ownerID
        self.presenter = presenter
        host = presenter.host
        self.photo = photo
        parentIsCurrent = isCurrent
    }
    public var isCurrent: Bool { !closed && parentIsCurrent() && presenter?.activeID == id }
    fileprivate func retire() { closed = true }
    private func check() throws {
        guard isCurrent else { throw GatewayAvatarReportHostFailure.superseded }
        if Task.isCancelled { throw GatewayFailure.cancelled }
    }
    public func close() {
        closed = true
        presenter?.close(id)
    }
    public func open() async throws {
        try check()
        host.setForeground(true)
        try await host.connect(isCurrent: { [weak self] in self?.isCurrent == true })
        try check()
        if host.pendingOperation == nil, let photo {
            do { try host.present(photo) } catch GatewayAvatarReportHostFailure.displayRequired {
                // Explicit refresh remains available.
            }
        }
    }
    public func refreshPhoto() async throws {
        try check()
        guard let photo else { throw GatewayAvatarReportHostFailure.displayRequired }
        try await host.refreshPhoto(photo)
        try check()
    }
    public func submit(reason: String, presentation: GatewayAvatarReportPresentation) async throws {
        try check()
        try await host.submit(reason: reason, presentation: presentation)
        try check()
    }
    public func recover() async throws {
        try check()
        try await host.recover()
        try check()
    }
    public func cancelPending() async throws {
        try check()
        try await host.cancelPending()
        try check()
    }
    public func acknowledgeResult(_ value: GatewayAvatarReportResolution) async throws {
        try check()
        try await host.acknowledgeResult(value)
        try check()
    }
}
