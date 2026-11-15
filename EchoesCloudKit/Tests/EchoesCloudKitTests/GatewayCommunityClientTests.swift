import EchoesCore
import Foundation
import Testing

@testable import EchoesCloudKit

private let clientNow = Date(timeIntervalSince1970: 1_800_000_000)
private let ownerA = "11111111-1111-4111-8111-111111111111"
private let ownerB = "22222222-2222-4222-8222-222222222222"
private let clientPosition = Coordinate(latitude: 51.11, longitude: 17.03)
@MainActor private final class ClientStorage: GatewayCommunityJournalStorage {
    var data: [String: Data] = [:]
    var failReads = false, failWrites = false, failRemovals = false
    func read(scope: GatewayCommunityScope) throws -> Data? {
        if failReads { throw GatewayCommunityFailure.storage }
        return data[scope.digest]
    }
    func write(_ bytes: Data, scope: GatewayCommunityScope) throws {
        if failWrites { throw GatewayCommunityFailure.storage }
        data[scope.digest] = bytes
    }
    func remove(scope: GatewayCommunityScope) throws {
        if failRemovals { throw GatewayCommunityFailure.storage }
        data.removeValue(forKey: scope.digest)
    }
}
@MainActor private final class ClientAuthorization: GatewayCommunityAuthorizationSource {
    var communityAuthorization: GatewayCommunityAuthorization?
    var tokenCalls = 0, rejected = 0
    var holdToken = false
    var waiter: CheckedContinuation<Void, Never>?
    var onInvalidation: (() -> Void)?
    init() throws { try select(ownerA) }
    func select(_ account: String, apple: String = "apple-A", cloud: String = "cloud-A") throws {
        communityAuthorization = try .init(
            accountID: account, binding: .init(appleUserID: apple, cloudKitRecordName: cloud),
            revision: UUID())
    }
    func communityAccessToken(for expected: GatewayCommunityAuthorization) async throws -> GatewaySecret {
        guard communityAuthorization == expected else { throw GatewayFailure.superseded }
        tokenCalls += 1
        if holdToken {
            holdToken = false
            await withCheckedContinuation { waiter = $0 }
        }
        // Deliberately returns the captured token after account changes; the adapter must fence it.
        return try GatewaySecret(expected.identity.accountID + "." + String(repeating: "a", count: 43))
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
    func rejectCommunityAccess(for expected: GatewayCommunityAuthorization) async {
        guard communityAuthorization == expected else { return }
        rejected += 1
        communityAuthorization = nil
        onInvalidation?()
    }
}
private actor ClientAPI: GatewayCommunityAPI {
    nonisolated let origin = "https://client.example.invalid"
    struct Block {
        let id: String
        let generation: Int
        let active: Bool
    }
    var operations: [GatewayCommunityOperation] = []
    var messages: [String: ChatMessage] = [:], visibility: [String: Int] = [:],
        stops: [String: (String, Int)] = [:]
    var blocks: [String: Block] = [:]
    var dropSend = false, dropStop = false, dropBlock = false, forgeSend = false, denyAccess = false
    var cursorRejected = false
    var heldPath: String?, waiting: CheckedContinuation<Void, Never>?,
        observer: CheckedContinuation<Void, Never>?
    func hold(_ path: String) { heldPath = "/v1/community/" + path }
    func waitForHold() async {
        if waiting != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() {
        waiting?.resume()
        waiting = nil
    }
    func loseSend() { dropSend = true }
    func loseStop() { dropStop = true }
    func loseBlock() { dropBlock = true }
    func wrongSendOwner() { forgeSend = true }
    func reject() { denyAccess = true }
    func expireCursor() { cursorRejected = true }
    func captured() -> [GatewayCommunityOperation] { operations }
    func messageCount() -> Int { messages.count }
    func perform(_ op: GatewayCommunityOperation, token: GatewaySecret) async throws -> GatewayCommunityReply
    {
        operations.append(op)
        if denyAccess { throw GatewayFailure.signInRequired }
        let owner = String(token.value.prefix(36))
        let time = clientNow.timeIntervalSince1970 * 1000
        let value: GatewayCommunityValue
        var lose = false
        switch op {
        case .configuration: value = .configuration(supportURL: nil)
        case .visibility: value = .generation(visibility[owner] ?? 0)
        case .stop(let id, let previous):
            if let last = stops[owner], last.0 == id {
                value = .publication(
                    id: communityOwnedRecordName(accountID: owner, kind: "presence", logicalID: "singleton"),
                    generation: last.1, visible: false)
            } else {
                guard previous == visibility[owner] ?? 0 else { throw GatewayCommunityFailure.stale }
                visibility[owner] = previous + 1
                stops[owner] = (id, previous + 1)
                value = .publication(
                    id: communityOwnedRecordName(accountID: owner, kind: "presence", logicalID: "singleton"),
                    generation: previous + 1, visible: false)
            }
            lose = dropStop
            dropStop = false
        case .publish(_, _, _, _, _, _, let generation):
            guard generation == visibility[owner] ?? 0 else { throw GatewayCommunityFailure.stale }
            value = .publication(
                id: communityOwnedRecordName(accountID: owner, kind: "presence", logicalID: "singleton"),
                generation: generation, visible: true)
        case .nearby:
            value = .nearby([
                .init(
                    id: ownerB, name: "Maja", coordinate: clientPosition, lastSong: "", appleMusicID: "",
                    expiresAt: time + 600000)
            ])
        case .messages:
            if cursorRejected { throw GatewayCommunityFailure.invalidCursor }
            value = .messages(.init(messages: Array(messages.values), nextCursor: nil))
        case .send(let id, let name, let text, _):
            let key = owner + id
            let message =
                messages[key]
                ?? .init(
                    id: communityOwnedRecordName(accountID: owner, kind: "message", logicalID: id),
                    text: text, senderName: name,
                    senderID: owner, timestamp: time, expiresAt: time + 7_200_000)
            messages[key] = message
            if forgeSend {
                forgeSend = false
                value = .sent(
                    .init(
                        id: message.id, text: text, senderName: name, senderID: ownerB, timestamp: time,
                        expiresAt: time + 7_200_000))
            } else {
                value = .sent(message)
            }
            lose = dropSend
            dropSend = false
        case .blockState(let target):
            let row = blocks[owner + target]
            value = .blockState(generation: row?.generation ?? 0, blocked: row?.active ?? false)
        case .block(let id, let target, let active, let version):
            let key = owner + target
            let row = blocks[key]
            if row?.id != id {
                guard version == row?.generation ?? 0 else { throw GatewayCommunityFailure.stale }
                blocks[key] = .init(id: id, generation: version + 1, active: active)
            }
            value = .receipt(communityOwnedRecordName(accountID: owner, kind: "block", logicalID: target))
            lose = dropBlock
            dropBlock = false
        case .blocked:
            value = .blocked(
                blocks.filter { $0.key.hasPrefix(owner) && $0.value.active }.map { String($0.key.suffix(36)) }
            )
        case .report: value = .accepted
        case .profile: value = .profile(nil)
        case .saveProfile: throw GatewayCommunityFailure.unavailable
        }
        if heldPath == op.path {
            heldPath = nil
            await withCheckedContinuation {
                waiting = $0
                observer?.resume()
                observer = nil
            }
        }
        if lose { throw GatewayCommunityFailure.unavailable }
        return .init(serverTime: clientNow, value: value)
    }
}
@MainActor private struct ClientFixture {
    let source: ClientAuthorization
    let storage: ClientStorage
    let api: ClientAPI
    let configuration: GatewayConfiguration
    let cloudKit: CloudKitConfiguration
    let client: GatewayCommunityClient
    init(storage: ClientStorage? = nil, source: ClientAuthorization? = nil, api: ClientAPI? = nil) throws {
        self.storage = storage ?? .init()
        self.source = try source ?? .init()
        self.api = api ?? .init()
        configuration = try .init(origin: URL(string: "https://client.example.invalid")!)
        cloudKit = try .init(containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
        client = try .init(
            api: self.api, configuration: configuration, cloudKit: cloudKit, authorization: self.source,
            storage: self.storage,
            coordinate: { clientPosition }, now: { clientNow })
    }
    func scope() throws -> GatewayCommunityScope {
        let current = source.communityAuthorization!
        return try .init(
            configuration: configuration, cloudKit: cloudKit, accountID: current.identity.accountID,
            binding: current.identity.binding)
    }
}

@Test @MainActor func communityJournalRestartsUnknownSendWithTheSamePayloadAndOriginalTimestamp() async throws
{
    let f = try ClientFixture()
    _ = try await f.client.connect()
    await f.api.loseSend()
    let id = UUID().uuidString
    await #expect(throws: GatewayCommunityFailure.unavailable) {
        try await f.client.send(text: "Treść", name: "Maja", coordinate: clientPosition, requestID: id)
    }
    let pending = try #require(try f.client.pendingMessage())
    #expect(pending.requestID == id.lowercased())
    let next = try ClientFixture(storage: f.storage, source: f.source, api: f.api)
    _ = try await next.client.connect()
    let restored = try #require(try next.client.pendingMessage())
    #expect(restored.text == pending.text)
    #expect(restored.recoveryID != pending.recoveryID)
    let sent = try await next.client.send(
        text: restored.text, name: restored.name, coordinate: restored.coordinate,
        requestID: restored.requestID)
    #expect(sent.timestamp == clientNow.timeIntervalSince1970 * 1000)
    #expect(try next.client.pendingMessage() == nil)
    #expect(await f.api.messageCount() == 1)
    await #expect(throws: GatewayCommunityFailure.superseded) { try await f.client.configuration() }
}
@Test @MainActor
func communityStorageFailureBeforeDispatchAndAfterAcknowledgementNeverGeneratesAnotherSendID() async throws {
    let f = try ClientFixture()
    _ = try await f.client.connect()
    f.storage.failWrites = true
    let id = UUID().uuidString
    await #expect(throws: GatewayCommunityFailure.storage) {
        try await f.client.send(text: "Treść", name: "Maja", coordinate: clientPosition, requestID: id)
    }
    #expect(await f.api.captured().isEmpty)
    #expect(f.source.tokenCalls == 1)
    f.storage.failWrites = false
    await f.api.hold("send")
    let task = Task {
        try await f.client.send(text: "Treść", name: "Maja", coordinate: clientPosition, requestID: id)
    }
    await f.api.waitForHold()
    f.storage.failWrites = true
    await f.api.release()
    await #expect(throws: GatewayCommunityFailure.storage) { try await task.value }
    f.storage.failWrites = false
    let pending = try #require(try f.client.pendingMessage())
    _ = try await f.client.send(
        text: pending.text, name: pending.name, coordinate: pending.coordinate, requestID: pending.requestID)
    #expect(await f.api.messageCount() == 1)
}
@Test @MainActor func communityLateResponseCannotCrossAnAccountChangeOrSameAccountReauthorization()
    async throws
{
    for account in [ownerA, ownerB] {
        let f = try ClientFixture()
        _ = try await f.client.connect()
        await f.api.hold("nearby")
        let task = Task { try await f.client.nearby(coordinate: clientPosition) }
        await f.api.waitForHold()
        try f.source.select(account)
        await f.api.release()
        await #expect(throws: GatewayCommunityFailure.superseded) { try await task.value }
    }
}
@Test @MainActor func communityAccountChangingDuringTokenAcquisitionNeverDispatchesTheCapturedCredential()
    async throws
{
    let f = try ClientFixture()
    _ = try await f.client.connect()
    f.source.holdToken = true
    let task = Task { try await f.client.nearby(coordinate: clientPosition) }
    while f.source.waiter == nil { await Task.yield() }
    try f.source.select(ownerB)
    f.source.release()
    await #expect(throws: GatewayCommunityFailure.superseded) { try await task.value }
    #expect(await f.api.captured().isEmpty)
}
@Test @MainActor func communityOwnerValidationDoesNotAcknowledgeAnotherAuthorsMessage() async throws {
    let f = try ClientFixture()
    _ = try await f.client.connect()
    await f.api.wrongSendOwner()
    let id = UUID().uuidString
    await #expect(throws: GatewayCommunityFailure.invalidResponse) {
        try await f.client.send(text: "Treść", name: "Maja", coordinate: clientPosition, requestID: id)
    }
    #expect(try f.client.pendingMessage() != nil)
    let message = try await f.client.send(
        text: "Treść", name: "Maja", coordinate: clientPosition, requestID: id)
    #expect(message.senderID == ownerA)
    #expect(await f.api.messageCount() == 1)
}
@Test @MainActor func communityStopReusesItsPersistedIDAndFencesALatePublication() async throws {
    let f = try ClientFixture()
    _ = try await f.client.connect()
    _ = try await f.client.visibilityGeneration()
    await f.api.hold("publish")
    let publishing = Task {
        try await f.client.publish(
            name: "Maja", coordinate: clientPosition, measuredAt: clientNow, song: "", songID: "",
            generation: 0)
    }
    await f.api.waitForHold()
    await f.api.loseStop()
    await #expect(throws: GatewayCommunityFailure.unavailable) { try await f.client.stopSharing() }
    #expect(try await f.client.stopSharing() == 1)
    await f.api.release()
    await #expect(throws: GatewayCommunityFailure.superseded) { try await publishing.value }
    let ops = await f.api.captured().filter {
        if case .stop = $0 { return true }
        return false
    }
    #expect(ops.count == 2 && ops[0] == ops[1])
}
@Test @MainActor func communityBlocksRecoverUnknownRepliesAndUsePerTargetServerRevisions() async throws {
    let f = try ClientFixture()
    _ = try await f.client.connect()
    await f.api.loseBlock()
    await #expect(throws: GatewayCommunityFailure.unavailable) {
        try await f.client.block(userID: ownerB, blocked: true)
    }
    try await f.client.block(userID: ownerB, blocked: true)
    try await f.client.block(userID: ownerB, blocked: false)
    let operations = await f.api.captured().filter {
        if case .block = $0 { return true }
        return false
    }
    #expect(operations.count == 3 && operations[0] == operations[1])
    guard case .block(_, _, false, let revision) = operations[2] else {
        Issue.record("Missing unblock")
        return
    }
    #expect(revision == 1)
    #expect(try await f.client.blockedUsers().isEmpty)
}
@Test @MainActor func communityReportIDsRemainStableAcrossRestartsAndDifferentInterveningReports()
    async throws
{
    let f = try ClientFixture()
    _ = try await f.client.connect()
    let id = "community-v1-message-" + String(repeating: "a", count: 64)
    try await f.client.report(messageID: id, reason: "Powód A")
    try await f.client.report(messageID: id, reason: "Powód B")
    let next = try ClientFixture(storage: f.storage, source: f.source, api: f.api)
    _ = try await next.client.connect()
    try await next.client.report(messageID: id, reason: "Powód A")
    let operations = await f.api.captured().filter {
        if case .report = $0 { return true }
        return false
    }
    #expect(operations.count == 3 && operations[0] == operations[2] && operations[0] != operations[1])
}
@Test @MainActor func communityPendingMessageForgettingIsExactScopedLocalAndNeverClaimsAnUnsend() async throws
{
    let f = try ClientFixture()
    _ = try await f.client.connect()
    await f.api.loseSend()
    await #expect(throws: GatewayCommunityFailure.unavailable) {
        try await f.client.send(
            text: "Treść", name: "Maja", coordinate: clientPosition, requestID: UUID().uuidString)
    }
    let pending = try #require(try f.client.pendingMessage())
    let calls = await f.api.captured().count
    await #expect(throws: PendingMessageFailure.self) {
        try await f.client.send(
            text: "Nowy szkic", name: "Maja", coordinate: clientPosition, requestID: UUID().uuidString)
    }
    let next = try ClientFixture(storage: f.storage, source: f.source, api: f.api)
    _ = try await next.client.connect()
    #expect(throws: PendingMessageFailure.changed) { try next.client.forgetPendingMessage(pending) }
    let fresh = try #require(try next.client.pendingMessage())
    try next.client.forgetPendingMessage(fresh)
    #expect(try next.client.pendingMessage() == nil)
    #expect(await f.api.captured().count == calls)
    #expect(await f.api.messageCount() == 1)
}
@Test @MainActor func communityJournalsSeparateEveryNativeAndGatewayScopeAndEraseOnlyTheRequestedOwner()
    async throws
{
    let f = try ClientFixture()
    _ = try await f.client.connect()
    let scopeA = try f.scope()
    await f.api.loseSend()
    await #expect(throws: GatewayCommunityFailure.unavailable) {
        try await f.client.send(
            text: "A", name: "Maja", coordinate: clientPosition, requestID: UUID().uuidString)
    }
    f.client.invalidate()
    try f.source.select(ownerB)
    _ = try await f.client.connect()
    let scopeB = try f.scope()
    #expect(scopeA != scopeB)
    #expect(try f.client.pendingMessage() == nil)
    try f.client.eraseJournal(scope: scopeA)
    #expect(try await f.client.configuration() == nil)
    #expect(f.storage.data[scopeA.digest] == nil && f.storage.data[scopeB.digest] != nil)
    let binding = try GatewayIdentityBinding(appleUserID: "different-apple", cloudKitRecordName: "cloud-A")
    let otherApple = try GatewayCommunityScope(
        configuration: f.configuration, cloudKit: f.cloudKit, accountID: ownerB, binding: binding)
    #expect(otherApple != scopeB)
}
@Test @MainActor func communityCorruptProtectedStorageFailsClosedAndLegacyDeletionCannotDispatch()
    async throws
{
    let f = try ClientFixture()
    let scope = try f.scope()
    f.storage.data[scope.digest] = Data("broken".utf8)
    await #expect(throws: GatewayCommunityFailure.storage) { try await f.client.connect() }
    #expect(await f.api.captured().isEmpty)
    #expect(f.storage.data[scope.digest] == Data("broken".utf8))
    await #expect(throws: GatewayCommunityFailure.deletionRequiresReauthentication) {
        try await f.client.deleteOwnData()
    }
}
@Test @MainActor
func communityRemoteRevocationClosesTheMatchingNativeAuthorizationWithoutDiscardingPendingEvidence()
    async throws
{
    let f = try ClientFixture()
    _ = try await f.client.connect()
    await f.api.reject()
    await #expect(throws: GatewayFailure.signInRequired) {
        try await f.client.send(
            text: "Treść", name: "Maja", coordinate: clientPosition, requestID: UUID().uuidString)
    }
    #expect(f.source.communityAuthorization == nil && f.source.rejected == 1)
    #expect(f.storage.data.values.count == 1)
}

@Test @MainActor func communityJournalCapacityNeverEvictsAnUncertainOperationToDispatchAnotherWrite()
    async throws
{
    let f = try ClientFixture()
    _ = try await f.client.connect()
    for _ in 0..<8 {
        await f.api.loseBlock()
        await #expect(throws: GatewayCommunityFailure.unavailable) {
            try await f.client.block(userID: UUID().uuidString, blocked: true)
        }
    }
    await #expect(throws: GatewayCommunityFailure.storage) {
        try await f.client.block(userID: UUID().uuidString, blocked: true)
    }
    let writes = await f.api.captured().filter {
        if case .block = $0 { return true }
        return false
    }
    #expect(writes.count == 8)
    let value = try JSONDecoder().decode(
        StoredCommunityJournal.self, from: #require(f.storage.data[try f.scope().digest]))
    #expect(value.pending.count == 8)
}

@Test @MainActor func communityDomainInvalidationClearsUIBeforeALateAccountResponseCanComplete() async throws
{
    let f = try ClientFixture()
    let domain = try GatewayCommunityDomain(
        api: f.api, configuration: f.configuration, cloudKit: f.cloudKit,
        authorization: f.source, storage: f.storage, now: { clientNow })
    f.source.onInvalidation = { [weak domain] in domain?.invalidate() }
    await domain.session.connect(name: "Maja")
    await domain.session.setForeground(true)
    domain.session.updateLocation(.init(coordinate: clientPosition, accuracy: 10, measuredAt: clientNow))
    domain.session.draft = "Treść"
    #expect(await domain.session.sendDraft())
    #expect(domain.session.messages.count == 1)
    await f.api.hold("nearby")
    let task = Task { await domain.session.refreshUsers() }
    await f.api.waitForHold()
    let current = try #require(f.source.communityAuthorization)
    await f.source.rejectCommunityAccess(for: current)
    #expect(domain.session.messages.isEmpty && domain.session.userID == nil && domain.session.phase == .idle)
    await f.api.release()
    await task.value
    #expect(
        domain.session.users.isEmpty && domain.session.messages.isEmpty && domain.session.errorMessage == nil
            && !domain.session.isLoadingUsers)
}

@Test @MainActor func communityCursorFailureReachesCoreAsARecoverablePageReset() async throws {
    let f = try ClientFixture()
    _ = try await f.client.connect()
    await f.api.expireCursor()
    await #expect(throws: CommunityPageFailure.cursorExpired) {
        try await f.client.messages(coordinate: clientPosition, cursor: "v1.abc", knownIDs: [])
    }
}

@Test @MainActor func communityDeletionScopeReconstructsOnlyTheMatchingProtectedJournal() throws {
    let f = try ClientFixture()
    let binding = try GatewayIdentityBinding(appleUserID: "apple-A", cloudKitRecordName: "cloud-A")
    let privateScope = try PrivateAccountScope(
        configuration: f.cloudKit, accountID: ownerA, cloudKitRecordName: "cloud-A")
    let projected = try GatewayCommunityScope(
        configuration: f.configuration, privateScope: privateScope, binding: binding)
    #expect(try projected == f.scope())
    let wrong = try GatewayIdentityBinding(appleUserID: "apple-A", cloudKitRecordName: "different-cloud")
    #expect(throws: GatewayFailure.accountMismatch) {
        try GatewayCommunityScope(configuration: f.configuration, privateScope: privateScope, binding: wrong)
    }
}

@Test @MainActor func communityPendingDataCannotBeReadBeforeConnectionAuthorizationCompletes() async throws {
    let f = try ClientFixture()
    _ = try await f.client.connect()
    await f.api.loseSend()
    await #expect(throws: GatewayCommunityFailure.unavailable) {
        try await f.client.send(
            text: "Chroniony szkic", name: "Maja", coordinate: clientPosition, requestID: UUID().uuidString)
    }
    let restored = try ClientFixture(storage: f.storage, source: f.source, api: f.api)
    f.source.holdToken = true
    let task = Task { try await restored.client.connect() }
    while f.source.waiter == nil { await Task.yield() }
    #expect(throws: GatewayCommunityFailure.busy) { try restored.client.pendingMessage() }
    f.source.release()
    _ = try await task.value
    #expect(try restored.client.pendingMessage()?.text == "Chroniony szkic")
}
