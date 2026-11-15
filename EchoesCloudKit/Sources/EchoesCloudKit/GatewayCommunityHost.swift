import EchoesCore
import Foundation
import Observation

/// Owns one foreground presentation. A reopened map gets a new domain and durable lease.
@MainActor @Observable public final class GatewayCommunityHost {
    @MainActor public final class Presentation: Identifiable {
        public let id = UUID()
        public let domain: GatewayCommunityDomain
        fileprivate let authorization: GatewayCommunityAuthorization
        fileprivate init(domain: GatewayCommunityDomain, authorization: GatewayCommunityAuthorization) {
            self.domain = domain
            self.authorization = authorization
        }
    }
    public private(set) var presentation: Presentation?
    @ObservationIgnored private let api: any GatewayCommunityAPI
    @ObservationIgnored private let configuration: GatewayConfiguration
    @ObservationIgnored private let cloudKit: CloudKitConfiguration
    @ObservationIgnored private let source: any GatewayCommunityAuthorizationSource
    @ObservationIgnored private let storage: any GatewayCommunityJournalStorage
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let clearLocalState: @MainActor () -> Void

    public init(
        api: any GatewayCommunityAPI, configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration,
        authorization: any GatewayCommunityAuthorizationSource, storage: any GatewayCommunityJournalStorage,
        isEnabled: @escaping @MainActor () -> Bool, clearLocalState: @escaping @MainActor () -> Void = {},
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.api = api
        self.configuration = configuration
        self.cloudKit = cloudKit
        self.source = authorization
        self.storage = storage
        self.isEnabled = isEnabled
        self.clearLocalState = clearLocalState
        self.now = now
    }
    @discardableResult public func open() throws -> Presentation {
        guard isEnabled(), let authorization = source.communityAuthorization else {
            throw GatewayFailure.signInRequired
        }
        guard presentation == nil else { throw GatewayCommunityFailure.busy }
        let domain = try GatewayCommunityDomain(
            api: api, configuration: configuration, cloudKit: cloudKit,
            authorization: source, storage: storage, now: now)
        let value = Presentation(domain: domain, authorization: authorization)
        presentation = value
        return value
    }
    public func isCurrent(_ id: UUID) -> Bool {
        guard isEnabled(), let current = presentation, current.id == id else { return false }
        return current.authorization == source.communityAuthorization
    }
    public func reconcileAuthorization() {
        if let current = presentation, !isCurrent(current.id) { invalidate() }
    }
    /// Called synchronously by native authentication before its asynchronous cleanup.
    public func invalidate() {
        let old = presentation
        presentation = nil
        old?.domain.invalidate()
        clearLocalState()
    }
    /// Clears visible state before awaiting a best-effort stop. Never invalidates a later presentation.
    public func close(_ id: UUID) async {
        guard let old = presentation, old.id == id else { return }
        presentation = nil
        old.domain.session.invalidateForAccountChange()
        clearLocalState()
        _ = try? await old.domain.client.stopSharing()
        old.domain.client.invalidate()
    }
}
