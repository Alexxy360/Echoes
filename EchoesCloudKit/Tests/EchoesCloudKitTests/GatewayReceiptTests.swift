import Foundation
import Testing

@testable import EchoesCloudKit

@MainActor private func completedReceipt() async throws -> (
    DeletionFlowFixture, GatewayDeletionController, GatewayDeletionProgress
) {
    let f = try DeletionFlowFixture()
    f.cleanup.complete = true
    let controller = f.controller()
    let initial = try await f.request(controller)
    let receipt = try await controller.advance(journalID: initial.journalID)
    #expect(receipt.completed)
    return (f, controller, receipt)
}

@Test @MainActor func forgettingCompletedReceiptRemovesOnlyItsLocalRecordWithoutRemoteOrCleanupCalls()
    async throws
{
    let (f, controller, receipt) = try await completedReceipt()
    let other = try DeletionFlowFixture(storage: f.storage, appleID: "native-apple-B", cloudName: "owner-B")
    let otherRequest = try await other.request(other.controller())
    let before = (f.api.requestCalls, f.api.recoveryCalls, f.api.statusCalls, f.api.ackCalls)
    let local = (f.fences, f.localClears, f.cleanup.calls)
    try await controller.forgetCompleted(receipt: receipt)
    let remaining = try f.storage.journal().requests
    #expect(remaining.count == 1 && remaining.first?.journalID == otherRequest.journalID)
    #expect((f.api.requestCalls, f.api.recoveryCalls, f.api.statusCalls, f.api.ackCalls) == before)
    #expect((f.fences, f.localClears, f.cleanup.calls) == local)
    #expect(controller.progress == nil && controller.phase == .ready)
}

@Test @MainActor func serverCompletedWithoutThisDevicesCheckpointsCannotBeForgotten() async throws {
    let f = try DeletionFlowFixture()
    f.api.serverCompleted = true
    f.api.serverAck = true
    let controller = f.controller()
    let incomplete = try await f.request(controller)
    #expect(incomplete.status?.completed == true && !incomplete.completed)
    let before = try f.storage.read()
    await #expect(throws: GatewayDeletionFailure.receiptChanged) {
        try await controller.forgetCompleted(receipt: incomplete)
    }
    #expect(try f.storage.read() == before)
}

@Test @MainActor func uncertainInitialAndRecoveryRequestsAreNeverDiscardedAsCompletedReceipts()
    async throws
{
    let f = try DeletionFlowFixture()
    let controller = f.controller()
    f.api.loseRequest = true
    await #expect(throws: GatewayFailure.transport) { try await f.request(controller) }
    let pending = try #require(try await controller.ownedRequests().first)
    await #expect(throws: GatewayDeletionFailure.receiptChanged) {
        try await controller.forgetCompleted(receipt: pending)
    }
    f.api.loseRecovery = true
    await #expect(throws: GatewayFailure.transport) {
        try await controller.recover(
            challenge: flowChallenge(), proof: flowProof(), expectedAccountID: flowAccountID,
            journalID: pending.journalID)
    }
    let recovery = try #require(try await controller.ownedRequests().first)
    #expect(recovery.needsFreshProof)
    await #expect(throws: GatewayDeletionFailure.receiptChanged) {
        try await controller.forgetCompleted(receipt: recovery)
    }
    #expect(try f.storage.journal().requests.count == 1)
}

@Test @MainActor func rotatedReceiptRequiresANewDisplayedSnapshotBeforeItCanBeForgotten() async throws {
    let (f, controller, old) = try await completedReceipt()
    let newer = try await f.controller().recover(
        challenge: flowChallenge(), proof: flowProof(), expectedAccountID: flowAccountID,
        journalID: old.journalID)
    #expect(newer.completed && old != newer)
    let before = try f.storage.read()
    await #expect(throws: GatewayDeletionFailure.receiptChanged) {
        try await controller.forgetCompleted(receipt: old)
    }
    #expect(try f.storage.read() == before)
    try await controller.forgetCompleted(receipt: newer)
    #expect(try f.storage.journal().requests.isEmpty)
}

@Test @MainActor func failedReceiptRemovalPreservesProtectedStorageAndCanBeRetriedAfterUnlock()
    async throws
{
    let (f, controller, receipt) = try await completedReceipt()
    let before = try f.storage.read()
    f.storage.failWrite = f.storage.totalWrites + 1
    await #expect(throws: GatewayFailure.storageUnavailable) {
        try await controller.forgetCompleted(receipt: receipt)
    }
    #expect(try f.storage.read() == before)
    #expect(controller.phase == .storageBlocked)
    f.storage.failWrite = nil
    try await controller.forgetCompleted(receipt: receipt)
    #expect(try f.storage.journal().requests.isEmpty)
}

@Test @MainActor func receiptRemovalChecksNativeOwnerBindingAndReadableStorage() async throws {
    let (f, controller, receipt) = try await completedReceipt()
    let before = try f.storage.read()
    f.owner.name = "owner-B"
    await #expect(throws: GatewayFailure.accountMismatch) {
        try await controller.forgetCompleted(receipt: receipt)
    }
    #expect(try f.storage.read() == before)
    let foreign = try DeletionFlowFixture(storage: f.storage, appleID: "native-apple-B")
    await #expect(throws: GatewayFailure.accountMismatch) {
        try await foreign.controller().forgetCompleted(receipt: receipt)
    }
    #expect(try f.storage.read() == before)
    f.owner.name = "owner-A"
    f.storage.set(Data("corrupt protected journal".utf8))
    await #expect(throws: GatewayFailure.storageUnavailable) {
        try await controller.forgetCompleted(receipt: receipt)
    }
    #expect(try f.storage.read() == Data("corrupt protected journal".utf8))
}

@Test @MainActor func lateStatusResponseCannotResurrectAForgottenReceipt() async throws {
    let (f, oldController, receipt) = try await completedReceipt()
    f.api.holdNextStatus = true
    let polling = Task { try await oldController.poll(journalID: receipt.journalID) }
    for _ in 0..<1000 where f.api.pendingStatus == nil { await Task.yield() }
    let response = try #require(f.api.pendingStatus)
    // Keep native revisions independent so the assertion exercises the missing durable record,
    // rather than passing only because a shared account session invalidated the old operation.
    let removing = try DeletionFlowFixture(storage: f.storage)
    try await removing.controller().forgetCompleted(receipt: receipt)
    response.resume()
    f.api.pendingStatus = nil
    await #expect(throws: GatewayFailure.accountMismatch) { try await polling.value }
    #expect(try f.storage.journal().requests.isEmpty)
}

@Test @MainActor func fullJournalRecoversCapacityOnlyAfterExplicitRemovalOfACompletedReceipt()
    async throws
{
    let f = try DeletionFlowFixture()
    f.cleanup.complete = true
    let controller = f.controller()
    var receipts: [GatewayDeletionProgress] = []
    for _ in 0..<8 {
        f.api.activeTicket = nil
        f.api.serverAck = false
        f.api.serverCompleted = false
        let initial = try await f.request(controller)
        receipts.append(try await controller.advance(journalID: initial.journalID))
    }
    let before = try f.storage.read()
    await #expect(throws: GatewayDeletionFailure.journalFull) { try await f.request(controller) }
    #expect(try f.storage.read() == before)
    try await controller.forgetCompleted(receipt: receipts[0])
    f.api.activeTicket = nil
    f.api.serverAck = false
    f.api.serverCompleted = false
    _ = try await f.request(controller)
    let remaining = try f.storage.journal().requests
    #expect(remaining.count == 8 && !remaining.contains { $0.journalID == receipts[0].journalID })
    #expect(Set(receipts.dropFirst().map(\.journalID)).isSubset(of: Set(remaining.map(\.journalID))))
}
