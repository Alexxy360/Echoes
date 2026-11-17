import CoreGraphics
import EchoesCore
import Foundation
import Observation

public enum GatewayCommunityAvatarSurface: Equatable, Sendable {
    case map, profile
    case message(String)
}
public struct GatewayCommunityAvatarLease: Equatable, Sendable {
    fileprivate let id: UUID
}

/// A binding cannot invalidate or borrow images from a later foreground domain.
@MainActor public final class GatewayCommunityAvatarBinding {
    fileprivate let id: UUID
    private weak var host: GatewayCommunityAvatarHost?
    fileprivate init(id: UUID, host: GatewayCommunityAvatarHost) {
        self.id = id
        self.host = host
    }
    public func acquire(reference: AvatarReference, surface: GatewayCommunityAvatarSurface) throws
        -> GatewayCommunityAvatarLease
    {
        guard let host else { throw GatewayAvatarFailure.superseded }
        return try host.acquire(binding: id, reference: reference, surface: surface)
    }
    public func release(_ lease: GatewayCommunityAvatarLease) { host?.release(binding: id, lease: lease) }
    public func image(for lease: GatewayCommunityAvatarLease) -> CGImage? {
        host?.image(binding: id, lease: lease)
    }
    public func isLoading(_ lease: GatewayCommunityAvatarLease) -> Bool {
        host?.isLoading(binding: id, lease: lease) == true
    }
    public func retry(_ lease: GatewayCommunityAvatarLease) { host?.retry(binding: id, lease: lease) }
    public func invalidate() { host?.invalidate(binding: id) }
}

/// One runtime owns one host/client, including unsettled work across foreground bindings. Views
/// register leases, never pixels. Concurrent consumers share a pending fresh read; attaching after
/// completion requires another fresh read, which replaces the composite presentation for all leases.
@MainActor @Observable public final class GatewayCommunityAvatarHost: CommunityPresentationObserver {
    private final class Relay { weak var host: GatewayCommunityAvatarHost? }
    private struct Key: Hashable {
        let owner: String, version: String, variant: String
        init(_ reference: AvatarReference, _ variant: AvatarVariant) {
            owner = reference.ownerID
            version = reference.versionID
            self.variant = variant.rawValue
        }
    }
    private struct Consumer {
        let reference: AvatarReference
        let surface: GatewayCommunityAvatarSurface
        var variant: AvatarVariant { surface == .profile ? .image : .thumbnail }
        var key: Key { Key(reference, variant) }
    }
    private struct Group {
        let id: UUID, order: UInt64
        var consumers: Set<UUID>
        var expiry: Double
        var mapAuthority: Bool
        var handle: GatewayAvatarPresentation?
        var waiting = true
    }
    private struct Pending {
        let group: UUID
        let task: Task<Void, Never>
    }
    @ObservationIgnored private let client: GatewayAvatarClient
    @ObservationIgnored private let source: any GatewayAvatarAuthorizationSource
    @ObservationIgnored private let cloudKit: CloudKitConfiguration
    @ObservationIgnored private let enabled: @MainActor () -> Bool
    @ObservationIgnored private let uptime: @MainActor () -> Double
    @ObservationIgnored private weak var session: CommunitySession?
    @ObservationIgnored private var context: UUID?
    @ObservationIgnored private var authorization: GatewayCommunityAuthorization?
    @ObservationIgnored private var privateScope: PrivateAccountScope?
    @ObservationIgnored private var current: @MainActor () -> Bool = { false }
    @ObservationIgnored private var active = false
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var connected = false
    @ObservationIgnored private var connectID: UUID?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var failedConnectEpoch: UUID?
    @ObservationIgnored private var consumers: [UUID: Consumer] = [:]
    @ObservationIgnored private var groups: [Key: Group] = [:]
    @ObservationIgnored private var pending: [UUID: Pending] = [:]
    @ObservationIgnored private var order: UInt64 = 0
    @ObservationIgnored private var lastClock: Double = 0
    @ObservationIgnored private var minute: Double = -1
    @ObservationIgnored private var reads = 0
    @ObservationIgnored private var images = 0
    public private(set) var presentationRevision = UUID()

    public init(
        api: any GatewayAvatarReadAPI, configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration,
        authorization: any GatewayAvatarAuthorizationSource, cache: any GatewayAvatarCaching,
        decoder: any GatewayAvatarDecoding = NativeGatewayAvatarDecoder(),
        isEnabled: @escaping @MainActor () -> Bool,
        uptime: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        let relay = Relay()
        self.source = authorization
        self.cloudKit = cloudKit
        self.enabled = isEnabled
        self.uptime = uptime
        client = try GatewayAvatarClient(
            api: api, configuration: configuration, cloudKit: cloudKit,
            authorization: authorization, cache: cache, decoder: decoder,
            isEnabled: { relay.host?.operational == true },
            isVisible: { relay.host?.allows($0) == true }, uptime: uptime)
        relay.host = self
    }
    public func bind(session: CommunitySession, isCurrent: @escaping @MainActor () -> Bool) throws
        -> GatewayCommunityAvatarBinding
    {
        if let context { invalidate(binding: context) }
        guard enabled(), isCurrent(), let native = source.communityAuthorization,
            let scope = source.privateDataScope(configuration: cloudKit),
            scope.accountID == native.identity.accountID
        else { throw GatewayFailure.signInRequired }
        let id = UUID()
        context = id
        authorization = native
        privateScope = scope
        current = isCurrent
        self.session = session
        do { try session.bindPresentationObserver(self) } catch {
            invalidate(binding: id)
            throw GatewayFailure.configuration
        }
        return .init(id: id, host: self)
    }
    private var operational: Bool {
        context != nil && enabled() && current() && source.communityAuthorization == authorization
            && privateScope != nil && source.privateDataScope(configuration: cloudKit) == privateScope
            && session?.phase == .ready && session?.isForeground == true
            && session?.userID == authorization?.identity.accountID && session?.usableCoordinate != nil
    }
    public func communityPresentationDidChange(_ session: CommunitySession) {
        guard self.session === session else { return }
        reconcile()
    }
    fileprivate func invalidate(binding id: UUID) {
        guard context == id else { return }
        session?.unbindPresentationObserver(self)
        session = nil
        context = nil
        authorization = nil
        privateScope = nil
        current = { false }
        active = false
        connected = false
        epoch = UUID()
        connectTask?.cancel()
        client.invalidate()
        consumers.removeAll()
        groups.removeAll()
        for item in pending.values { item.task.cancel() }
        presentationRevision = UUID()
    }
    /// Parent eligibility is checked again at render time, including time passing without an event.
    private func eligibility(_ consumer: Consumer) -> Double? {
        guard operational, let session, let coordinate = session.usableCoordinate,
            !session.blockedIDs.contains(consumer.reference.ownerID),
            !session.blockingUserIDs.contains(consumer.reference.ownerID)
        else { return nil }
        let date = session.serverDate
        let owner = consumer.reference.ownerID
        let map = session.users.first { $0.id == owner }
        if let map {
            guard map.isValid(at: date),
                coordinate.distance(to: map.coordinate) <= CommunityPolicy.radiusMeters,
                map.avatarReference == consumer.reference
            else { return nil }
        }
        switch consumer.surface {
        case .map, .profile: return map?.expiresAt
        case .message(let id):
            guard session.isChatOpen, let message = session.messages.first(where: { $0.id == id }),
                message.isValid(at: date), message.avatarReference == consumer.reference
            else { return nil }
            if map == nil {
                let siblings = session.messages.filter { $0.senderID == owner && $0.isValid(at: date) }
                guard !siblings.isEmpty,
                    siblings.allSatisfy({ $0.avatarVersionID == consumer.reference.versionID })
                else { return nil }
            }
            return message.expiresAt
        }
    }
    private func allows(_ reference: AvatarReference) -> Bool {
        guard operational else { return false }
        return [AvatarVariant.thumbnail, .image].contains { variant in
            groups[Key(reference, variant)]?.consumers.contains { id in
                consumers[id].flatMap(eligibility) != nil
            } == true
        }
    }
    fileprivate func acquire(
        binding: UUID, reference: AvatarReference, surface: GatewayCommunityAvatarSurface
    ) throws -> GatewayCommunityAvatarLease {
        guard context == binding else { throw GatewayAvatarFailure.superseded }
        let consumer = Consumer(reference: reference, surface: surface)
        guard let expiry = eligibility(consumer) else { throw GatewayAvatarFailure.notFound }
        guard consumers.count < 320 else { throw GatewayAvatarFailure.limited(retryAfterSeconds: nil) }
        let id = UUID()
        consumers[id] = consumer
        if !active {
            reconcile()
        } else {
            if var group = groups[consumer.key],
                group.expiry > (session?.serverDate.timeIntervalSince1970 ?? .infinity) * 1000
            {
                if group.handle != nil {
                    discard(consumer.key, group)
                    group.handle = nil
                    group.waiting = true
                }
                group.consumers.insert(id)
                group.expiry = min(group.expiry, expiry)
                groups[consumer.key] = group
            } else {
                var members: Set<UUID> = [id]
                var deadline = expiry
                if let old = groups[consumer.key] {
                    discard(consumer.key, old)
                    for other in old.consumers {
                        if let value = consumers[other].flatMap(eligibility) {
                            members.insert(other)
                            deadline = min(deadline, value)
                        }
                    }
                }
                guard order < .max else {
                    invalidate(binding: binding)
                    throw GatewayAvatarFailure.unavailable
                }
                order += 1
                groups[consumer.key] = .init(
                    id: UUID(), order: order, consumers: members, expiry: deadline,
                    mapAuthority: session?.users.contains(where: { $0.id == reference.ownerID }) == true)
            }
            presentationRevision = UUID()
            pump()
        }
        return .init(id: id)
    }
    fileprivate func release(binding: UUID, lease: GatewayCommunityAvatarLease) {
        guard context == binding, let consumer = consumers.removeValue(forKey: lease.id) else { return }
        if var group = groups[consumer.key] {
            group.consumers.remove(lease.id)
            if group.consumers.isEmpty {
                discard(consumer.key, group)
                groups.removeValue(forKey: consumer.key)
            } else {
                groups[consumer.key] = group
            }
        }
        presentationRevision = UUID()
        pump()
    }
    fileprivate func image(binding: UUID, lease: GatewayCommunityAvatarLease) -> CGImage? {
        _ = presentationRevision
        guard context == binding, let consumer = consumers[lease.id], eligibility(consumer) != nil,
            let group = groups[consumer.key], group.consumers.contains(lease.id), let handle = group.handle
        else { return nil }
        return client.image(for: handle)
    }
    fileprivate func isLoading(binding: UUID, lease: GatewayCommunityAvatarLease) -> Bool {
        _ = presentationRevision
        guard context == binding, failedConnectEpoch != epoch, let consumer = consumers[lease.id],
            eligibility(consumer) != nil,
            let group = groups[consumer.key]
        else { return false }
        return group.waiting || pending.values.contains { $0.group == group.id }
    }
    fileprivate func retry(binding: UUID, lease: GatewayCommunityAvatarLease) {
        guard context == binding, let consumer = consumers[lease.id], eligibility(consumer) != nil,
            var group = groups[consumer.key], !pending.values.contains(where: { $0.group == group.id })
        else { return }
        client.invalidate(reference: consumer.reference, variant: consumer.variant)
        group.handle = nil
        group.waiting = true
        groups[consumer.key] = group
        failedConnectEpoch = nil
        presentationRevision = UUID()
        pump()
    }
    private func discard(_ key: Key, _ group: Group) {
        if let reference = try? AvatarReference(ownerID: key.owner, versionID: key.version),
            let variant = AvatarVariant(rawValue: key.variant)
        {
            client.invalidate(reference: reference, variant: variant)
        }
        for value in pending.values where value.group == group.id { value.task.cancel() }
    }
    private func reconcile() {
        let nowActive = operational
        if !nowActive {
            if active {
                active = false
                connected = false
                epoch = UUID()
                connectTask?.cancel()
                client.invalidate()
                groups.removeAll()
                for item in pending.values { item.task.cancel() }
                presentationRevision = UUID()
            }
            return
        }
        if !active {
            active = true
            epoch = UUID()
            failedConnectEpoch = nil
        }
        guard let session else { return }
        let time = session.serverDate.timeIntervalSince1970 * 1000
        var desired: [Key: (Set<UUID>, Double, Bool)] = [:]
        for (id, consumer) in consumers {
            guard let expiry = eligibility(consumer) else { continue }
            let previous = desired[consumer.key]
            desired[consumer.key] = (
                (previous?.0 ?? []).union([id]), min(previous?.1 ?? expiry, expiry),
                session.users.contains { $0.id == consumer.reference.ownerID }
            )
        }
        for (key, group) in groups where desired[key] == nil {
            discard(key, group)
            groups.removeValue(forKey: key)
        }
        for (key, value) in desired {
            if var group = groups[key], group.expiry > time, group.mapAuthority == value.2 {
                if !value.0.isSubset(of: group.consumers), group.handle != nil {
                    discard(key, group)
                    group.handle = nil
                    group.waiting = true
                }
                group.consumers = value.0
                group.expiry = value.1
                groups[key] = group
            } else {
                if let old = groups[key] { discard(key, old) }
                guard order < .max else {
                    if let context { invalidate(binding: context) }
                    return
                }
                order += 1
                groups[key] = .init(
                    id: UUID(), order: order, consumers: value.0, expiry: value.1, mapAuthority: value.2)
            }
        }
        presentationRevision = UUID()
        pump()
    }
    private func spend(_ variant: AvatarVariant) -> Bool {
        let now = uptime()
        guard now.isFinite, now >= lastClock else { return false }
        lastClock = now
        let bucket = floor(now / 60)
        if bucket != minute {
            minute = bucket
            reads = 0
            images = 0
        }
        guard reads < 12, variant != .image || images < 4 else { return false }
        reads += 1
        if variant == .image { images += 1 }
        return true
    }
    private func pump() {
        guard active, operational, let context, !groups.isEmpty else { return }
        guard connected else {
            guard connectID == nil, failedConnectEpoch != epoch else { return }
            let id = UUID()
            let startedEpoch = epoch
            connectID = id
            connectTask = Task { [weak self, client] in
                var succeeded = false
                do {
                    _ = try await client.connect()
                    succeeded = true
                } catch {}
                guard let self, self.connectID == id else { return }
                self.connectID = nil
                self.connectTask = nil
                if self.context == context, self.epoch == startedEpoch, self.operational {
                    self.connected = succeeded
                    if !succeeded { self.failedConnectEpoch = startedEpoch }
                }
                self.presentationRevision = UUID()
                self.pump()
            }
            return
        }
        for (key, captured) in groups.sorted(by: { $0.value.order < $1.value.order }) where captured.waiting {
            guard pending.count < 4 else { break }
            guard let id = captured.consumers.first(where: { consumers[$0].flatMap(eligibility) != nil }),
                let consumer = consumers[id]
            else { continue }
            groups[key]?.waiting = false
            guard spend(consumer.variant) else {
                presentationRevision = UUID()
                continue
            }
            let operation = UUID()
            let coordinate = session?.usableCoordinate
            let task = Task { [weak self, client] in
                var handle: GatewayAvatarPresentation?
                do {
                    handle = try await client.load(
                        reference: consumer.reference, variant: consumer.variant, coordinate: coordinate)
                } catch {}
                guard let self else { return }
                self.pending.removeValue(forKey: operation)
                if self.context == context, self.groups[key]?.id == captured.id, self.operational,
                    self.groups[key]?.consumers.contains(where: {
                        self.consumers[$0].flatMap(self.eligibility) != nil
                    }) == true
                {
                    self.groups[key]?.handle = handle
                }
                self.presentationRevision = UUID()
                self.pump()
            }
            pending[operation] = .init(group: captured.id, task: task)
        }
    }
}
