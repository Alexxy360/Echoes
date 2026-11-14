import CloudKit
import Foundation
import Testing

@testable import EchoesCloudKit

private let flowAccountID = "60000000-0000-4000-8000-000000000006"
private let flowNow = Date(timeIntervalSince1970: 1_800_000_000)
private final class DeletionJournalMemory: GatewayDeletionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var writes = 0
    private var failWriteNumber: Int?
    var failWrite: Int? {
        get { lock.withLock { failWriteNumber } }
        set { lock.withLock { failWriteNumber = newValue } }
    }
    func read() throws -> Data? { lock.withLock { value } }
    func write(_ value: Data) throws {
        try lock.withLock {
            writes += 1
            if writes == failWriteNumber { throw GatewayFailure.storageUnavailable }
            self.value = value
        }
    }
    func set(_ value: Data) { lock.withLock { self.value = value } }
    func journal() throws -> StoredGatewayDeletionJournal {
        try JSONDecoder().decode(StoredGatewayDeletionJournal.self, from: #require(try read()))
    }
    func rewrite(_ change: (inout StoredGatewayDeletionJournal) throws -> Void) throws {
        var journal = try journal()
        try change(&journal)
        set(try JSONEncoder().encode(journal))
    }
}
@MainActor private final class DeletionFlowAPI: GatewayAccountDeletionAPI {
    nonisolated let origin = "https://gateway.example.invalid"
    var accountID = flowAccountID
    var activeTicket: GatewayDeletionTicket?
    var serverAck = false, serverCompleted = false, completesOnACK = true
    var requestCalls = 0, recoveryCalls = 0, statusCalls = 0, ackCalls = 0
    var loseRequest = false, loseRecovery = false, loseACK = false
    var requestProofs: [Bool] = []
    var beforeRequest: (() throws -> Void)?, beforeRecovery: (() throws -> Void)?,
        beforeACK: (() throws -> Void)?
    var holdRequest = false, pendingRequest: CheckedContinuation<Void, Never>?
    var failStatus = false
    var holdNextRecovery = false
    var pendingRecovery: CheckedContinuation<Void, Never>?
    func status(_ ticket: GatewayDeletionTicket) throws -> GatewayDeletionStatus {
        guard ticket == activeTicket else {
            throw GatewayFailure.server(.other, status: 503, retryAfterSeconds: nil)
        }
        return .init(
            protocolVersion: 1, deletionID: ticket.deletionID, accountID: accountID,
            publicData: serverCompleted ? .deleted : .pending,
            privateData: serverAck ? .deviceAcknowledged : .awaitingDevice,
            appleAuthorization: serverCompleted ? .manualRequired : .pending,
            localAccount: serverCompleted ? .removed : .blocked, attentionRequired: false,
            completed: serverCompleted)
    }
    func deletionChallenge(recovering: Bool) async throws -> GatewayChallenge { flowChallenge() }
    func requestDeletion(ticket: GatewayDeletionTicket, proof: GatewayDeletionProof?) async throws
        -> GatewayDeletionStatus
    {
        requestCalls += 1
        requestProofs.append(proof != nil)
        try beforeRequest?()
        if activeTicket == nil {
            guard proof != nil else {
                throw GatewayFailure.server(.invalidChallenge, status: 401, retryAfterSeconds: nil)
            }
            activeTicket = ticket
        }
        if holdRequest { await withCheckedContinuation { pendingRequest = $0 } }
        if loseRequest {
            loseRequest = false
            throw GatewayFailure.transport
        }
        return try status(ticket)
    }
    func recoverDeletion(proof: GatewayDeletionProof) async throws -> GatewayRecoveredDeletion {
        recoveryCalls += 1
        try beforeRecovery?()
        guard let activeTicket else {
            throw GatewayFailure.server(.noDeletion, status: 404, retryAfterSeconds: nil)
        }
        let random = try GatewayDeletionTicket.create()
        let replacement = try GatewayDeletionTicket(
            deletionID: activeTicket.deletionID,
            statusToken: .init(activeTicket.deletionID + "." + random.statusToken.value.dropFirst(37)))
        self.activeTicket = replacement
        let response = try GatewayRecoveredDeletion(ticket: replacement, status: status(replacement))
        if holdNextRecovery {
            holdNextRecovery = false
            await withCheckedContinuation { pendingRecovery = $0 }
        }
        if loseRecovery {
            loseRecovery = false
            throw GatewayFailure.transport
        }
        return response
    }
    func deletionStatus(ticket: GatewayDeletionTicket) async throws -> GatewayDeletionStatus {
        statusCalls += 1
        if failStatus { throw GatewayFailure.transport }
        return try status(ticket)
    }
    func acknowledgePrivateCleanup(ticket: GatewayDeletionTicket) async throws -> GatewayDeletionStatus {
        ackCalls += 1
        try beforeACK?()
        _ = try status(ticket)
        serverAck = true
        if completesOnACK { serverCompleted = true }
        if loseACK {
            loseACK = false
            throw GatewayFailure.transport
        }
        return try status(ticket)
    }
    func resumeRequest() {
        pendingRequest?.resume()
        pendingRequest = nil
        holdRequest = false
    }
}
@MainActor private func flowChallenge() -> GatewayChallenge {
    .init(
        protocolVersion: 1, challengeID: UUID().uuidString.lowercased(),
        nonce: try! .init(String(repeating: "A", count: 43)),
        expiresAt: Int(flowNow.timeIntervalSince1970) + 300)
}
@MainActor private func flowProof(_ user: String = "native-apple-A") throws -> AppleGatewayProof {
    try .init(
        appleUserID: user, identityToken: .init("SYNTHETIC-PRIVATE-DELETION-IDENTITY"),
        authorizationCode: .init("SYNTHETIC-UNUSED-APPLE-CODE"))
}
@MainActor private final class DeletionCleanupModel: GatewayPrivateAccountCleanup {
    var calls = 0
    var complete = false
    var cursors: [PrivateCleanupCursor?] = []
    var error: (any Error)?
    var foreignScope: PrivateAccountScope?
    var onStep: (() async throws -> Void)?
    func step(
        scope: PrivateAccountScope, deletionID: String, cursor: PrivateCleanupCursor?,
        authorizeDeletion: @escaping @MainActor (PrivateAccountScope) async throws -> Void
    ) async throws -> PrivateCleanupStep {
        calls += 1
        cursors.append(cursor)
        try await authorizeDeletion(foreignScope ?? scope)
        try await onStep?()
        if let error { throw error }
        return try .init(
            scope: scope,
            cursor: complete
                ? nil : .init(scope: scope, deletionID: deletionID, opaqueToken: Data("synthetic-page".utf8)),
            contentDeleted: complete, deletedRecords: complete ? 0 : 100)
    }
}
@MainActor private final class DeletionFlowFixture {
    let owner = ZoneOwner()
    let account: CloudKitAccountSession
    let api = DeletionFlowAPI()
    let storage: DeletionJournalMemory
    let cleanup = DeletionCleanupModel()
    let config: CloudKitConfiguration
    let binding: GatewayIdentityBinding
    var enabled = true, failFence = false, failLocalCleanup = false
    var fences = 0, localClears = 0
    var localHook: (() async throws -> Void)?
    init(
        storage: DeletionJournalMemory = .init(), appleID: String = "native-apple-A",
        cloudName: String = "owner-A"
    ) throws {
        owner.name = cloudName
        account = .init(source: owner)
        self.storage = storage
        config = try .init(containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
        binding = try .init(appleUserID: appleID, cloudKitRecordName: cloudName)
    }
    func controller(cleaner: (any GatewayPrivateAccountCleanup)? = nil) -> GatewayDeletionController {
        let controller = GatewayDeletionController(
            configuration: config, binding: binding, api: api, storage: storage,
            account: account, cleanup: cleaner ?? cleanup, isEnabled: { [self] in enabled }, now: { flowNow },
            fenceLocalAccess: { [self] context, _ in
                #expect(context == binding)
                fences += 1
                if failFence { throw GatewayFailure.storageUnavailable }
            },
            clearLocalData: { [self] scope in
                #expect(scope.cloudKitAccountHash == binding.cloudKitAccountHash)
                localClears += 1
                try await localHook?()
                if failLocalCleanup { throw NSError(domain: "PRIVATE-LOCAL-FILE-PATH-DO-NOT-LOG", code: 1) }
            })
        controller.activate()
        return controller
    }
    func request(_ controller: GatewayDeletionController, expected: String? = flowAccountID) async throws
        -> GatewayDeletionProgress
    {
        try await controller.request(
            challenge: flowChallenge(), proof: flowProof(binding.appleUserID), expectedAccountID: expected)
    }
    func recover(
        _ controller: GatewayDeletionController, id: String? = nil, expected: String? = flowAccountID
    ) async throws -> GatewayDeletionProgress {
        try await controller.recover(
            challenge: flowChallenge(), proof: flowProof(binding.appleUserID), expectedAccountID: expected,
            journalID: id)
    }
}

@Test @MainActor func deletionTicketIsDurableBeforeFenceOrNetworkAndNeverStoresAppleProofOrCode() async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.api.beforeRequest = {
        let stored = try #require(try f.storage.journal().requests.first)
        #expect(stored.phase == .requestPending)
        #expect(stored.ticket != nil)
        #expect(f.fences == 1)
    }
    let result = try await f.request(controller)
    #expect(result.accountID == flowAccountID)
    #expect(try f.storage.journal().requests.first?.phase == .accepted)
    let bytes = try #require(try f.storage.read())
    let json = String(decoding: bytes, as: UTF8.self)
    #expect(!json.contains("SYNTHETIC-PRIVATE-DELETION-IDENTITY"))
    #expect(!json.contains("SYNTHETIC-UNUSED-APPLE-CODE"))
    #expect(f.cleanup.calls == 0 && f.localClears == 0 && f.api.ackCalls == 0)
}

@Test @MainActor func storageOrAccessFenceFailurePreventsInitialDeletionDispatch() async throws {
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.storage.failWrite = 1
    await #expect(throws: GatewayFailure.storageUnavailable) { try await f.request(controller) }
    #expect(f.api.requestCalls == 0 && f.fences == 0)
    #expect(controller.phase == .storageBlocked)
    f.storage.failWrite = nil
    f.failFence = true
    await #expect(throws: GatewayFailure.storageUnavailable) { try await f.request(controller) }
    #expect(f.api.requestCalls == 0)
    let firstTicket = try #require(try f.storage.journal().requests.first?.ticket)
    f.failFence = false
    _ = try await f.request(controller)
    #expect(f.api.activeTicket == firstTicket)
    #expect(try f.storage.journal().requests.count == 1)
}

@Test @MainActor func lostInitialResponseRestoresTheSamePersistedTicketWithoutAnotherAppleProof() async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.api.loseRequest = true
    await #expect(throws: GatewayFailure.transport) { try await f.request(controller) }
    let entry = try #require(try f.storage.journal().requests.first)
    controller.suspend()
    let restarted = f.controller()
    let result = try await restarted.poll(journalID: entry.journalID)
    #expect(result.accountID == flowAccountID)
    #expect(f.api.requestProofs == [true, false])
    #expect(try f.storage.journal().requests.first?.ticket == entry.ticket)
    #expect(f.api.ackCalls == 0)
}

@Test @MainActor func failedAcceptedTicketWriteCanBeRecoveredAfterRestartWithoutCreatingAnotherJob()
    async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.storage.failWrite = 2
    await #expect(throws: GatewayFailure.storageUnavailable) { try await f.request(controller) }
    #expect(f.api.requestCalls == 1)
    let entry = try #require(try f.storage.journal().requests.first)
    #expect(entry.phase == .requestPending)
    f.storage.failWrite = nil
    controller.suspend()
    let result = try await f.controller().poll(journalID: entry.journalID)
    #expect(result.status != nil && f.api.requestProofs == [true, false])
}

@Test @MainActor func unknownRecoveryKeepsProgressButForbidsOldTicketUseUntilAnotherFreshProof() async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    let first = try await f.request(controller)
    _ = try await controller.advance(journalID: first.journalID)
    let before = try #require(try f.storage.journal().requests.first)
    let oldTicket = before.ticket
    f.api.beforeRecovery = { () throws -> Void in
        let phase = try f.storage.journal().requests.first?.phase
        #expect(phase == .recoveryPending)
    }
    f.api.loseRecovery = true
    await #expect(throws: GatewayFailure.transport) { try await f.recover(controller, id: first.journalID) }
    #expect(try f.storage.journal().requests.first?.ticket == oldTicket)
    await #expect(throws: GatewayDeletionFailure.freshProofRequired) {
        try await controller.poll(journalID: first.journalID)
    }
    await #expect(throws: GatewayDeletionFailure.freshProofRequired) {
        try await controller.advance(journalID: first.journalID)
    }
    #expect(f.api.recoveryCalls == 1 && f.api.ackCalls == 0)
    let restored = try await f.recover(controller, id: first.journalID)
    #expect(restored.journalID == first.journalID)
    let after = try #require(try f.storage.journal().requests.first)
    #expect(after.cursor == before.cursor && after.ticket != oldTicket)
}

@Test @MainActor func recoveringWithoutLocalIDMergesTheSameOwnedJobInsteadOfLosingItsCursor() async throws {
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    let first = try await f.request(controller)
    _ = try await controller.advance(journalID: first.journalID)
    let before = try #require(try f.storage.journal().requests.first)
    let recovered = try await f.recover(controller)
    #expect(recovered.journalID == first.journalID)
    #expect(try f.storage.journal().requests.count == 1)
    #expect(try f.storage.journal().requests.first?.cursor == before.cursor)
}

@Test @MainActor func aMissingRemoteJobNeverBecomesAnAcceptedLocalDeletionOrCleanup() async throws {
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    await #expect(throws: GatewayFailure.server(.noDeletion, status: 404, retryAfterSeconds: nil)) {
        try await f.recover(controller)
    }
    let pending = try #require(try f.storage.journal().requests.first)
    #expect(pending.phase == .recoveryPending && pending.ticket == nil)
    #expect(f.cleanup.calls == 0 && f.api.ackCalls == 0)
}

@Test @MainActor func boundedPrivatePagesPersistTheirCursorAndResumeBeforeLocalCleanupAndAcknowledgement()
    async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    let first = try await f.request(controller)
    let partial = try await controller.advance(journalID: first.journalID)
    #expect(!partial.privateContentDeleted && !partial.ownAcknowledgement)
    #expect(f.cleanup.calls == 1 && f.localClears == 0 && f.api.ackCalls == 0)
    let cursor = try #require(try f.storage.journal().requests.first?.cursor)
    controller.suspend()
    let restarted = f.controller()
    f.cleanup.complete = true
    f.api.beforeACK = {
        let entry = try #require(try f.storage.journal().requests.first)
        #expect(entry.contentDeleted && entry.localDataDeleted && !entry.ownAcknowledgement)
    }
    let completed = try await restarted.advance(journalID: first.journalID)
    #expect(f.cleanup.cursors.last! == cursor)
    #expect(completed.completed && f.cleanup.calls == 2 && f.localClears == 1 && f.api.ackCalls == 1)
}

@Test @MainActor
func localFileFailureKeepsThePrivateCheckpointAndNeverAcknowledgesUntilTheScopedRetrySucceeds() async throws {
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.cleanup.complete = true
    f.failLocalCleanup = true
    let first = try await f.request(controller)
    await #expect(throws: NSError.self) { try await controller.advance(journalID: first.journalID) }
    #expect(controller.errorMessage?.contains("PRIVATE-LOCAL-FILE-PATH") == false)
    let entry = try #require(try f.storage.journal().requests.first)
    #expect(entry.contentDeleted && !entry.localDataDeleted && f.api.ackCalls == 0)
    controller.suspend()
    f.failLocalCleanup = false
    let result = try await f.controller().advance(journalID: first.journalID)
    #expect(result.completed && f.cleanup.calls == 1 && f.localClears == 2)
}

@Test @MainActor
func unknownPrivateACKIsRetriedIdempotentlyAfterRestartWithoutRepeatingPrivateOrLocalErasure() async throws {
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.cleanup.complete = true
    f.api.loseACK = true
    let first = try await f.request(controller)
    await #expect(throws: GatewayFailure.transport) {
        try await controller.advance(journalID: first.journalID)
    }
    #expect(try f.storage.journal().requests.first?.ownAcknowledgement == false)
    controller.suspend()
    let result = try await f.controller().advance(journalID: first.journalID)
    #expect(result.completed && f.api.ackCalls == 2 && f.cleanup.calls == 1 && f.localClears == 1)
}

@Test @MainActor func anotherDevicesCompletedReceiptNeverSkipsThisDevicesPrivateAndLocalCleanup() async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.cleanup.complete = true
    let first = try await f.request(controller)
    f.api.serverAck = true
    f.api.serverCompleted = true
    let polled = try await controller.poll(journalID: first.journalID)
    #expect(polled.status?.completed == true && !polled.completed && controller.phase == .ready)
    let result = try await controller.advance(journalID: first.journalID)
    #expect(result.completed && result.status?.appleAuthorization == .manualRequired)
    #expect(f.cleanup.calls == 1 && f.localClears == 1 && f.api.ackCalls == 1)
}

@Test @MainActor func wrongAccountResponseOrCleanupScopeCannotAuthorizePrivateErasure() async throws {
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.api.accountID = UUID().uuidString.lowercased()
    await #expect(throws: GatewayFailure.invalidResponse) { try await f.request(controller) }
    #expect(try f.storage.journal().requests.first?.status == nil)
    let id = try #require(try f.storage.journal().requests.first?.journalID)
    f.api.accountID = flowAccountID
    _ = try await controller.poll(journalID: id)
    f.cleanup.foreignScope = try .init(
        configuration: f.config, accountID: UUID().uuidString.lowercased(), cloudKitRecordName: "owner-A")
    await #expect(throws: GatewayFailure.accountMismatch) { try await controller.advance(journalID: id) }
    #expect(f.api.ackCalls == 0 && f.localClears == 0)
}

@Test @MainActor func lateInitialResponseAfterBackgroundCannotReplaceDurablePendingStateOrReopenTheUI()
    async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.api.holdRequest = true
    let task = Task { try await f.request(controller) }
    for _ in 0..<1000 {
        if f.api.pendingRequest != nil { break }
        await Task.yield()
    }
    #expect(f.api.pendingRequest != nil)
    await #expect(throws: GatewayFailure.operationInProgress) { try await controller.ownedRequests() }
    controller.suspend()
    f.api.resumeRequest()
    await #expect(throws: GatewayFailure.superseded) { try await task.value }
    #expect(controller.phase == .suspended && controller.progress == nil)
    #expect(try f.storage.journal().requests.first?.phase == .requestPending)
    controller.activate()
    let id = try #require(try f.storage.journal().requests.first?.journalID)
    #expect(try await controller.poll(journalID: id).status != nil)
}

@Test @MainActor
func cloudAccountSwitchBeforeDispatchAndDuringLocalCleanupStopsTheNextStepWithoutDroppingTheTicket()
    async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.owner.name = "owner-B"
    await #expect(throws: GatewayFailure.accountMismatch) { try await f.request(controller) }
    #expect(f.api.requestCalls == 0)
    #expect(try f.storage.read() == nil)
    f.owner.name = "owner-A"
    let first = try await f.request(controller)
    f.cleanup.complete = true
    f.localHook = {
        f.owner.name = "owner-B"
        await f.account.refresh()
    }
    await #expect(throws: GatewayFailure.accountMismatch) {
        try await controller.advance(journalID: first.journalID)
    }
    #expect(f.api.ackCalls == 0)
    #expect(try f.storage.journal().requests.first?.localDataDeleted == false)
}

@Test @MainActor func journalScopesSeparateNativeOwnersAndRejectAnExplicitForeignResumeID() async throws {
    let storage = DeletionJournalMemory()
    let a = try DeletionFlowFixture(storage: storage)
    let ca = a.controller()
    let first = try await a.request(ca)
    let b = try DeletionFlowFixture(storage: storage, appleID: "native-apple-B", cloudName: "owner-B")
    let cb = b.controller()
    b.api.accountID = UUID().uuidString.lowercased()
    #expect(try await cb.ownedRequests().isEmpty)
    await #expect(throws: GatewayFailure.accountMismatch) { try await cb.poll(journalID: first.journalID) }
    _ = try await b.request(cb, expected: b.api.accountID)
    #expect(try storage.journal().requests.count == 2)
    #expect(try await ca.ownedRequests().count == 1)
    #expect(try await cb.ownedRequests().count == 1)
    #expect(b.api.statusCalls == 0)
}

@Test @MainActor func corruptOrCrossNamespaceJournalIsNotOverwrittenOrInterpretedAsEmpty() async throws {
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    _ = try await f.request(controller)
    let baseline = try #require(try f.storage.read())
    for field in ["version", "origin", "container", "environment"] {
        var json = try #require(try JSONSerialization.jsonObject(with: baseline) as? [String: Any])
        json[field] = field == "version" ? 2 : "wrong-namespace"
        let corrupted = try JSONSerialization.data(withJSONObject: json)
        f.storage.set(corrupted)
        await #expect(throws: GatewayFailure.storageUnavailable) { try await controller.ownedRequests() }
        #expect(try f.storage.read() == corrupted)
    }
    f.storage.set(Data(repeating: 65, count: 65_537))
    await #expect(throws: GatewayFailure.storageUnavailable) { try await controller.ownedRequests() }
}

@Test @MainActor func foreignPersistedCursorIsRejectedBeforeTheCleanupAdapterReceivesIt() async throws {
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    let first = try await f.request(controller)
    let foreign = try PrivateAccountScope(
        configuration: f.config, accountID: UUID().uuidString.lowercased(), cloudKitRecordName: "owner-A")
    try f.storage.rewrite { journal in
        let ticket = try #require(journal.requests[0].ticket)
        journal.requests[0].cursor = try .init(
            scope: foreign, deletionID: ticket.deletionID, opaqueToken: Data("opaque".utf8))
    }
    await #expect(throws: PrivateDataFailure.invalidCursor) {
        try await controller.advance(journalID: first.journalID)
    }
    #expect(f.cleanup.calls == 0 && f.api.ackCalls == 0)
}

@Test @MainActor
func privateScanRestartIsExplicitAndDoesNotRetryAnExpiredTokenOrAProviderFailureAutomatically() async throws {
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    let first = try await f.request(controller)
    _ = try await controller.advance(journalID: first.journalID)
    f.cleanup.error = CKError(.changeTokenExpired)
    await #expect(throws: CKError.self) { try await controller.advance(journalID: first.journalID) }
    #expect(f.cleanup.calls == 2 && f.api.ackCalls == 0)
    _ = try await controller.restartPrivateScan(journalID: first.journalID)
    #expect(f.cleanup.calls == 2)
    f.cleanup.error = nil
    f.cleanup.complete = true
    _ = try await controller.advance(journalID: first.journalID)
    #expect(f.cleanup.cursors.last! == nil)
}

@Test @MainActor func inactiveDevelopmentOrWrongNativeAppleProofCannotDispatchDeletionOrEraseAStoredTicket()
    async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.enabled = false
    await #expect(throws: GatewayFailure.configuration) { try await f.request(controller) }
    f.enabled = true
    await #expect(throws: GatewayFailure.accountMismatch) {
        try await controller.request(
            challenge: flowChallenge(), proof: flowProof("another-apple-user"),
            expectedAccountID: flowAccountID)
    }
    #expect(f.api.requestCalls == 0)
    #expect(try f.storage.read() == nil)
}

@Test @MainActor
func deletionCoordinatorConnectsTheRealScopedDatabaseToTicketAuthorizationAndOnlyThenAcknowledges()
    async throws
{
    let f = try DeletionFlowFixture()
    let zone = ZoneModel(owner: f.owner)
    let database = NativePrivateProfileDatabase(account: f.account, transport: zone, authorizeWrite: { _ in })
    await f.account.refresh()
    let scope = try PrivateAccountScope(
        configuration: f.config, accountID: flowAccountID, cloudKitRecordName: "owner-A")
    let draft = try PrivateProfileRecordCodec.encode(
        .init(displayName: "Syntetyczny"), updating: nil, scope: scope)
    _ = try await database.saveProfile(draft, scope: scope)
    let controller = f.controller(cleaner: database)
    let first = try await f.request(controller)
    let partial = try await controller.advance(journalID: first.journalID)
    #expect(!partial.completed && zone.records[scope.profileID] == nil && f.api.ackCalls == 0)
    let result = try await controller.advance(journalID: first.journalID)
    #expect(result.completed)
    let guardRecord = try #require(zone.records[scope.guardID])
    #expect(try PrivateScopeGuard.isDeleted(guardRecord, scope: scope))
    #expect(f.localClears == 1 && f.api.ackCalls == 1 && f.api.statusCalls >= 4)
}

@Test @MainActor func failedRecoveryTicketReplacementSurvivesRestartAsUncertainUntilANewProof() async throws {
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    let first = try await f.request(controller)
    let old = f.api.activeTicket
    f.storage.failWrite = 4  // initial prepare/accept, recovery marker, then failed replacement
    await #expect(throws: GatewayFailure.storageUnavailable) {
        try await f.recover(controller, id: first.journalID)
    }
    #expect(f.api.activeTicket != old)
    #expect(try f.storage.journal().requests.first?.phase == .recoveryPending)
    controller.suspend()
    f.storage.failWrite = nil
    let restarted = f.controller()
    await #expect(throws: GatewayDeletionFailure.freshProofRequired) {
        try await restarted.advance(journalID: first.journalID)
    }
    let recovered = try await f.recover(restarted, id: first.journalID)
    #expect(recovered.journalID == first.journalID && !recovered.needsFreshProof)
    #expect(f.api.recoveryCalls == 2 && f.api.ackCalls == 0)
}

@Test @MainActor func aSiblingRecoveryCannotBeOverwrittenByTheOldPrivateStepsLateCursor() async throws {
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    let first = try await f.request(controller)
    let originalTicket = f.api.activeTicket
    let siblingAccount = CloudKitAccountSession(source: f.owner)
    let sibling = GatewayDeletionController(
        configuration: f.config, binding: f.binding, api: f.api,
        storage: f.storage, account: siblingAccount, cleanup: f.cleanup, isEnabled: { true },
        now: { flowNow },
        fenceLocalAccess: { _, _ in }, clearLocalData: { _ in })
    sibling.activate()
    f.cleanup.onStep = {
        _ = try await f.recover(sibling, id: first.journalID)
    }
    await #expect(throws: GatewayFailure.superseded) {
        try await controller.advance(journalID: first.journalID)
    }
    let stored = try #require(try f.storage.journal().requests.first)
    #expect(stored.ticket != originalTicket && stored.cursor == nil && !stored.contentDeleted)
    #expect(f.api.ackCalls == 0 && f.localClears == 0)
}

@Test @MainActor func expiredOrRotatedCapabilityCannotAuthorizeThePrivateStepOrClearLocalFiles() async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    let first = try await f.request(controller)
    let old = try #require(f.api.activeTicket)
    let random = try GatewayDeletionTicket.create()
    f.api.activeTicket = try .init(
        deletionID: old.deletionID,
        statusToken: .init(old.deletionID + "." + random.statusToken.value.dropFirst(37)))
    await #expect(throws: GatewayFailure.server(.other, status: 503, retryAfterSeconds: nil)) {
        try await controller.advance(journalID: first.journalID)
    }
    #expect(f.cleanup.calls == 0 && f.localClears == 0 && f.api.ackCalls == 0)
}

@Test @MainActor func boundedJournalNeverOverwritesEarlierCompletedReceiptsToMakeRoomForAnotherRequest()
    async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.cleanup.complete = true
    let first = try await f.request(controller)
    _ = try await controller.advance(journalID: first.journalID)
    try f.storage.rewrite { journal in
        let sample = try #require(journal.requests.first)
        journal.requests = try (0..<8).map { _ in
            let ticket = try GatewayDeletionTicket.create()
            var entry = sample
            // Each receipt belongs to a distinct previous application account of the same native owner.
            entry = .init(
                journalID: UUID().uuidString.lowercased(), binding: sample.binding, phase: .accepted,
                ticket: ticket, accountID: UUID().uuidString.lowercased())
            entry.status = .init(
                protocolVersion: 1, deletionID: ticket.deletionID, accountID: entry.accountID!,
                publicData: .deleted, privateData: .deviceAcknowledged, appleAuthorization: .manualRequired,
                localAccount: .removed, attentionRequired: false, completed: true)
            entry.contentDeleted = true
            entry.localDataDeleted = true
            entry.ownAcknowledgement = true
            return entry
        }
    }
    let before = try f.storage.read()
    let calls = f.api.requestCalls
    await #expect(throws: GatewayDeletionFailure.journalFull) { try await f.request(controller) }
    #expect(try f.storage.read() == before)
    #expect(f.api.requestCalls == calls)
}

@Test @MainActor func aLateRecoveryResponseCannotOverwriteANewerTicketFromAnotherCoordinator() async throws {
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    let first = try await f.request(controller)
    let sibling = GatewayDeletionController(
        configuration: f.config, binding: f.binding, api: f.api,
        storage: f.storage, account: CloudKitAccountSession(source: f.owner), cleanup: f.cleanup,
        isEnabled: { true }, now: { flowNow }, fenceLocalAccess: { _, _ in }, clearLocalData: { _ in })
    sibling.activate()
    f.api.holdNextRecovery = true
    let old = Task { try await f.recover(controller, id: first.journalID) }
    for _ in 0..<1000 {
        if f.api.pendingRecovery != nil { break }
        await Task.yield()
    }
    let firstResponse = try #require(f.api.pendingRecovery)
    f.api.pendingRecovery = nil
    f.api.holdNextRecovery = true
    let newer = Task { try await f.recover(sibling, id: first.journalID) }
    for _ in 0..<1000 {
        if f.api.pendingRecovery != nil { break }
        await Task.yield()
    }
    let secondResponse = try #require(f.api.pendingRecovery)
    let replacement = try #require(f.api.activeTicket)
    // The older response arrives while the newer attempt is still recoveryPending. Merely checking
    // that phase cannot reject it; the durable attempt ID must fence the response.
    firstResponse.resume()
    await #expect(throws: GatewayFailure.superseded) { try await old.value }
    #expect(try f.storage.journal().requests.first?.phase == .recoveryPending)
    secondResponse.resume()
    f.api.pendingRecovery = nil
    _ = try await newer.value
    #expect(try f.storage.journal().requests.first?.ticket == replacement)
}

@Test @MainActor func repeatedUnknownRecoveryReusesItsDurableMarkerAndFencesOtherTicketsForThatOwner()
    async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    let first = try await f.request(controller)
    f.api.loseRecovery = true
    await #expect(throws: GatewayFailure.transport) { try await f.recover(controller) }
    await #expect(throws: GatewayDeletionFailure.freshProofRequired) {
        try await controller.poll(journalID: first.journalID)
    }
    await #expect(throws: GatewayDeletionFailure.freshProofRequired) {
        try await controller.advance(journalID: first.journalID)
    }
    #expect(try f.storage.journal().requests.count == 2)
    let recovered = try await f.recover(controller)
    #expect(recovered.journalID == first.journalID)
    #expect(try f.storage.journal().requests.count == 1)
}

@Test @MainActor func anUncertainRecoveryOfACompletedReceiptIsNotPresentedAsCurrentlyCompleted() async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.cleanup.complete = true
    let first = try await f.request(controller)
    #expect(try await controller.advance(journalID: first.journalID).completed)
    f.api.loseRecovery = true
    await #expect(throws: GatewayFailure.transport) { try await f.recover(controller, id: first.journalID) }
    let pending = try #require(try await controller.ownedRequests().first)
    #expect(pending.needsFreshProof && !pending.completed)
    #expect(pending.status?.completed == true)
}
