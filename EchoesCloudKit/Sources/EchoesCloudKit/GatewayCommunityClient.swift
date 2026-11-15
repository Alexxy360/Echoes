import EchoesCore
import Foundation

/// One foreground adapter. Native authorization and a durable lease fence every awaited result.
@MainActor public final class GatewayCommunityClient: CommunityClient {
    private struct Context: Equatable {
        let authorization: GatewayCommunityAuthorization
        let scope: GatewayCommunityScope
        let lease: String
    }
    private let api: any GatewayCommunityAPI
    private let configuration: GatewayConfiguration
    private let cloudKit: CloudKitConfiguration
    private let authorization: any GatewayCommunityAuthorizationSource
    private let journal: GatewayCommunityJournal
    private let coordinate: @MainActor () -> Coordinate?
    private let now: @MainActor () -> Date
    private var context: Context?
    private var connecting: UUID?
    private var publishing: UUID?
    private var stopping: UUID?
    private var reporting: UUID?
    private var sending: UUID?
    private var blocking: [String: UUID] = [:]
    private var visibilityEpoch = UUID()
    private var generation: Int?
    public private(set) var serverTimeOffset: TimeInterval = 0

    public init(
        api: any GatewayCommunityAPI, configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration,
        authorization: any GatewayCommunityAuthorizationSource, storage: any GatewayCommunityJournalStorage,
        coordinate: @escaping @MainActor () -> Coordinate?, now: @escaping @MainActor () -> Date = Date.init
    ) throws {
        guard api.origin == configuration.origin.absoluteString,
            cloudKit.containerIdentifier == "iCloud.mpvEcho.Echo", cloudKit.environment == .development
        else { throw GatewayFailure.configuration }
        self.api = api
        self.configuration = configuration
        self.cloudKit = cloudKit
        self.authorization = authorization
        journal = .init(storage: storage)
        self.coordinate = coordinate
        self.now = now
    }
    public func invalidate() {
        context = nil
        connecting = nil
        publishing = nil
        stopping = nil
        reporting = nil
        sending = nil
        blocking = [:]
        generation = nil
        serverTimeOffset = 0
        visibilityEpoch = UUID()
    }
    public func connect() async throws -> String {
        guard connecting == nil else { throw GatewayCommunityFailure.busy }
        invalidate()
        let operation = UUID()
        connecting = operation
        defer { if connecting == operation { connecting = nil } }
        guard let native = authorization.communityAuthorization else { throw GatewayFailure.signInRequired }
        let scope = try GatewayCommunityScope(
            configuration: configuration, cloudKit: cloudKit, accountID: native.identity.accountID,
            binding: native.identity.binding)
        let value = Context(authorization: native, scope: scope, lease: operation.uuidString.lowercased())
        try journal.open(scope, lease: value.lease)
        context = value
        do {
            _ = try await authorization.communityAccessToken(for: native)
            try check(value)
            return scope.accountID
        } catch {
            if context == value { invalidate() }
            throw error
        }
    }
    private func bound() throws -> Context {
        guard connecting == nil else { throw GatewayCommunityFailure.busy }
        guard let context else { throw GatewayFailure.signInRequired }
        try check(context)
        return context
    }
    private func check(_ expected: Context, epoch: UUID? = nil) throws {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard context == expected, authorization.communityAuthorization == expected.authorization,
            epoch == nil || epoch == visibilityEpoch
        else { throw GatewayCommunityFailure.superseded }
        _ = try journal.current(expected.scope, lease: expected.lease)
    }
    private func dispatch(_ operation: GatewayCommunityOperation, context: Context, epoch: UUID? = nil)
        async throws -> GatewayCommunityReply
    {
        try check(context, epoch: epoch)
        do {
            let token = try await authorization.communityAccessToken(for: context.authorization)
            try check(context, epoch: epoch)
            let reply = try await api.perform(operation, token: token)
            try check(context, epoch: epoch)
            let offset = reply.serverTime.timeIntervalSince(now())
            guard offset.isFinite, abs(offset) <= 300 else { throw GatewayCommunityFailure.invalidResponse }
            serverTimeOffset = offset
            return reply
        } catch {
            if error as? GatewayFailure == .signInRequired {
                await authorization.rejectCommunityAccess(for: context.authorization)
                if self.context == context { invalidate() }
                throw error
            }
            try check(context, epoch: epoch)
            throw error
        }
    }
    private func mutate<T: Sendable>(
        _ operation: GatewayCommunityOperation, context: Context, epoch: UUID? = nil,
        decode: (GatewayCommunityReply) throws -> T
    ) async throws -> T {
        try check(context, epoch: epoch)
        try journal.put(operation, scope: context.scope, lease: context.lease)
        let reply = try await dispatch(operation, context: context, epoch: epoch)
        try check(context, epoch: epoch)
        guard
            try journal.operation(journal.key(operation), scope: context.scope, lease: context.lease)
                == operation
        else { throw GatewayCommunityFailure.superseded }
        let value = try decode(reply)
        try journal.remove(operation, scope: context.scope, lease: context.lease)
        return value
    }
    public func configuration() async throws -> URL? {
        let context = try bound()
        let reply = try await dispatch(.configuration, context: context)
        guard case .configuration(let url) = reply.value else {
            throw GatewayCommunityFailure.invalidResponse
        }
        return url
    }
    public func visibilityGeneration() async throws -> Int {
        let context = try bound()
        let epoch = visibilityEpoch
        let reply = try await dispatch(.visibility, context: context, epoch: epoch)
        guard case .generation(let value) = reply.value, value >= 0 else {
            throw GatewayCommunityFailure.invalidResponse
        }
        generation = value
        return value
    }
    public func publish(
        name: String, coordinate: Coordinate, measuredAt: Date, song: String, songID: String, generation: Int
    ) async throws {
        guard publishing == nil else { throw GatewayCommunityFailure.busy }
        let context = try bound()
        let epoch = visibilityEpoch
        let task = UUID()
        publishing = task
        defer { if publishing == task { publishing = nil } }
        guard self.generation == generation else { throw GatewayCommunityFailure.stale }
        let normalizedName = try InputValidation.name(name)
        let song = song.isEmpty ? "" : try InputValidation.message(song)
        var operation = GatewayCommunityOperation.publish(
            requestID: UUID().uuidString.lowercased(), name: normalizedName, coordinate: coordinate,
            measuredAt: measuredAt, song: song, songID: songID, generation: generation)
        if case .publish(
            let id, let oldName, let oldCoordinate, let oldDate, let oldSong, let oldSongID, let oldGeneration
        ) = try journal.operation("presence", scope: context.scope, lease: context.lease),
            oldName == normalizedName, oldCoordinate == coordinate, oldDate == measuredAt, oldSong == song,
            oldSongID == songID, oldGeneration == generation
        {
            operation = .publish(
                requestID: id, name: normalizedName, coordinate: coordinate, measuredAt: measuredAt,
                song: song, songID: songID, generation: generation)
        }
        try await mutate(operation, context: context, epoch: epoch) { reply in
            guard case .publication(let id, let version, let visible) = reply.value, visible,
                version == generation,
                id
                    == communityOwnedRecordName(
                        accountID: context.scope.accountID, kind: "presence", logicalID: "singleton")
            else { throw GatewayCommunityFailure.invalidResponse }
        }
    }
    public func stopSharing() async throws -> Int {
        guard stopping == nil else { throw GatewayCommunityFailure.busy }
        let context = try bound()
        let task = UUID()
        stopping = task
        visibilityEpoch = UUID()
        let epoch = visibilityEpoch
        defer { if stopping == task { stopping = nil } }
        let operation: GatewayCommunityOperation
        if case .stop = try journal.operation("presence", scope: context.scope, lease: context.lease) {
            operation = try journal.operation("presence", scope: context.scope, lease: context.lease)!
        } else {
            let reply = try await dispatch(.visibility, context: context, epoch: epoch)
            guard case .generation(let value) = reply.value else {
                throw GatewayCommunityFailure.invalidResponse
            }
            operation = .stop(requestID: UUID().uuidString.lowercased(), generation: value)
        }
        do {
            let value = try await mutate(operation, context: context, epoch: epoch) { reply -> Int in
                guard case .stop(_, let previous) = operation,
                    case .publication(let id, let version, let visible) = reply.value,
                    !visible, version == previous + 1,
                    id
                        == communityOwnedRecordName(
                            accountID: context.scope.accountID, kind: "presence", logicalID: "singleton")
                else { throw GatewayCommunityFailure.invalidResponse }
                return version
            }
            generation = value
            return value
        } catch {
            if error as? GatewayCommunityFailure == .stale {
                try check(context, epoch: epoch)
                try journal.remove(operation, scope: context.scope, lease: context.lease)
                generation = nil
            }
            throw error
        }
    }
    public func nearby(coordinate: Coordinate) async throws -> [NearbyProfile] {
        let context = try bound()
        let reply = try await dispatch(.nearby(coordinate: coordinate), context: context)
        guard case .nearby(let users) = reply.value else { throw GatewayCommunityFailure.invalidResponse }
        return users
    }
    public func messages(coordinate: Coordinate, cursor: String?, knownIDs: [String]) async throws
        -> MessagePage
    {
        let context = try bound()
        do {
            let reply = try await dispatch(
                .messages(coordinate: coordinate, cursor: cursor, knownIDs: knownIDs), context: context)
            guard case .messages(let page) = reply.value else {
                throw GatewayCommunityFailure.invalidResponse
            }
            return page
        } catch GatewayCommunityFailure.invalidCursor { throw CommunityPageFailure.cursorExpired }
    }
    public func send(text: String, name: String, coordinate: Coordinate, requestID: String) async throws
        -> ChatMessage
    {
        guard sending == nil else { throw GatewayCommunityFailure.busy }
        let context = try bound()
        let task = UUID()
        sending = task
        defer { if sending == task { sending = nil } }
        let operation = GatewayCommunityOperation.send(
            requestID: requestID.lowercased(), name: try InputValidation.name(name),
            text: try InputValidation.message(text), coordinate: coordinate)
        if let previous = try journal.operation("message", scope: context.scope, lease: context.lease),
            previous != operation
        {
            throw PendingMessageFailure.unresolved
        }
        return try await mutate(operation, context: context) { reply in
            guard case .sent(let message) = reply.value,
                case .send(let id, let expectedName, let expectedText, _) = operation,
                message.senderID == context.scope.accountID,
                message.id
                    == communityOwnedRecordName(
                        accountID: context.scope.accountID, kind: "message", logicalID: id),
                message.senderName == expectedName, message.text == expectedText,
                message.timestamp.isFinite, message.timestamp >= 0,
                message.timestamp <= reply.serverTime.timeIntervalSince1970 * 1000 + 5000,
                message.expiresAt == message.timestamp + 7_200_000
            else { throw GatewayCommunityFailure.invalidResponse }
            return message
        }
    }
    public func block(userID: String, blocked: Bool) async throws {
        let target = userID.lowercased()
        guard blocking[target] == nil else { throw GatewayCommunityFailure.busy }
        let context = try bound()
        let task = UUID()
        blocking[target] = task
        defer { if blocking[target] == task { blocking[target] = nil } }
        guard target != context.scope.accountID, gatewayUUID(target) else {
            throw GatewayCommunityFailure.invalidInput
        }
        let operation: GatewayCommunityOperation
        if case .block(let id, let oldTarget, let oldBlocked, let version) = try journal.operation(
            "block:" + target, scope: context.scope, lease: context.lease), oldBlocked == blocked
        {
            operation = .block(requestID: id, accountID: oldTarget, blocked: blocked, generation: version)
        } else {
            let reply = try await dispatch(.blockState(accountID: target), context: context)
            guard case .blockState(let version, _) = reply.value else {
                throw GatewayCommunityFailure.invalidResponse
            }
            operation = .block(
                requestID: UUID().uuidString.lowercased(), accountID: target, blocked: blocked,
                generation: version)
        }
        do {
            try await mutate(operation, context: context) { reply in
                guard case .receipt(let id) = reply.value,
                    id
                        == communityOwnedRecordName(
                            accountID: context.scope.accountID, kind: "block", logicalID: target)
                else { throw GatewayCommunityFailure.invalidResponse }
            }
        } catch {
            if error as? GatewayCommunityFailure == .stale {
                try check(context)
                try journal.remove(operation, scope: context.scope, lease: context.lease)
            }
            throw error
        }
    }
    public func blockedUsers() async throws -> [String] {
        let context = try bound()
        let reply = try await dispatch(.blocked, context: context)
        guard case .blocked(let users) = reply.value else { throw GatewayCommunityFailure.invalidResponse }
        return users
    }
    public func report(messageID: String, reason: String) async throws {
        guard reporting == nil else { throw GatewayCommunityFailure.busy }
        let context = try bound()
        let task = UUID()
        reporting = task
        defer { if reporting == task { reporting = nil } }
        guard let position = coordinate(), position.isValid else { throw ValidationError.location }
        let reason = try InputValidation.message(reason)
        let operation = GatewayCommunityOperation.report(
            requestID: communityReportID(scope: context.scope, messageID: messageID, reason: reason),
            messageID: messageID, reason: reason, coordinate: position)
        try await mutate(operation, context: context) { reply in
            guard case .accepted = reply.value else { throw GatewayCommunityFailure.invalidResponse }
        }
    }
    public func pendingMessage() throws -> PendingCommunityMessage? {
        let context = try bound()
        guard
            case .send(let id, let name, let text, let coordinate) = try journal.operation(
                "message", scope: context.scope, lease: context.lease)
        else { return nil }
        let recoveryID = communityDigest(
            "echoes/pending-message/v1\0" + context.scope.digest + "\0" + context.lease + "\0" + id + "\0"
                + name + "\0" + text + "\0" + String(coordinate.latitude) + "\0"
                + String(coordinate.longitude))
        return .init(requestID: id, name: name, text: text, coordinate: coordinate, recoveryID: recoveryID)
    }
    public func forgetPendingMessage(_ expected: PendingCommunityMessage) throws {
        let context = try bound()
        guard try pendingMessage() == expected,
            let operation = try journal.operation("message", scope: context.scope, lease: context.lease)
        else { throw PendingMessageFailure.changed }
        try journal.remove(operation, scope: context.scope, lease: context.lease)
    }
    public func deleteOwnData() async throws {
        throw GatewayCommunityFailure.deletionRequiresReauthentication
    }
    func matches(_ scope: GatewayCommunityScope) -> Bool { context?.scope == scope }
    public func eraseJournal(scope: GatewayCommunityScope) throws {
        if matches(scope) { invalidate() }
        try journal.erase(scope)
    }
}

@MainActor public final class GatewayCommunityDomain {
    private final class SessionReference { weak var session: CommunitySession? }
    public let client: GatewayCommunityClient
    public let session: CommunitySession
    public init(
        api: any GatewayCommunityAPI, configuration: GatewayConfiguration, cloudKit: CloudKitConfiguration,
        authorization: any GatewayCommunityAuthorizationSource, storage: any GatewayCommunityJournalStorage,
        now: @escaping @MainActor () -> Date = Date.init
    ) throws {
        let reference = SessionReference()
        client = try .init(
            api: api, configuration: configuration, cloudKit: cloudKit, authorization: authorization,
            storage: storage, coordinate: { reference.session?.usableCoordinate }, now: now)
        session = .init(client: client, now: now)
        reference.session = session
    }
    public func invalidate() {
        client.invalidate()
        session.invalidateForAccountChange()
    }
    public func eraseJournal(scope: GatewayCommunityScope) throws {
        if client.matches(scope) { invalidate() }
        try client.eraseJournal(scope: scope)
    }
}
