import Foundation
import Security
import Testing

@testable import EchoesCloudKit

final class ReportJournalMemoryStorage: GatewayReportReviewJournalStorage, @unchecked Sendable {
    private struct State {
        var records: [String: Data] = [:], owners: [String: String] = [:]
        var writes = 0, reads = 0
        var failAt: Int?
        var afterWrite = false, corruptWrite = false, failErase = false, mainThreadIO = false
    }
    private let lock = NSLock()
    private var state = State()
    let gate = ReviewStorageGate()
    var records: [String: Data] {
        get { lock.withLock { state.records } }
        set { lock.withLock { state.records = newValue } }
    }
    var writes: Int { lock.withLock { state.writes } }
    var reads: Int { lock.withLock { state.reads } }
    var failAt: Int? {
        get { lock.withLock { state.failAt } }
        set { lock.withLock { state.failAt = newValue } }
    }
    var afterWrite: Bool {
        get { lock.withLock { state.afterWrite } }
        set { lock.withLock { state.afterWrite = newValue } }
    }
    var corruptWrite: Bool {
        get { lock.withLock { state.corruptWrite } }
        set { lock.withLock { state.corruptWrite = newValue } }
    }
    var failErase: Bool {
        get { lock.withLock { state.failErase } }
        set { lock.withLock { state.failErase = newValue } }
    }
    var mainThreadIO: Bool { lock.withLock { state.mainThreadIO } }
    func read(scope: GatewayReportReviewScope) throws -> Data? {
        lock.withLock {
            state.reads += 1
            state.mainThreadIO = state.mainThreadIO || Thread.isMainThread
            return state.records[scope.digest]
        }
    }
    func write(_ data: Data, scope: GatewayReportReviewScope) throws {
        gate.blockIfArmed()
        try lock.withLock {
            state.mainThreadIO = state.mainThreadIO || Thread.isMainThread
            state.writes += 1
            if state.failAt == state.writes && !state.afterWrite {
                throw NSError(domain: "PRIVATE-STORAGE-DETAILS", code: 1)
            }
            state.records[scope.digest] = state.corruptWrite ? Data([0]) : data
            state.owners[scope.digest] = scope.owner.digest
            if state.failAt == state.writes { throw NSError(domain: "PRIVATE-STORAGE-DETAILS", code: 2) }
        }
    }
    func erase(owner: PrivateAccountScope) throws {
        try lock.withLock {
            state.mainThreadIO = state.mainThreadIO || Thread.isMainThread
            if state.failErase { throw NSError(domain: "PRIVATE-ERASURE-DETAILS", code: 3) }
            for (key, value) in state.owners where value == owner.digest {
                state.records.removeValue(forKey: key)
                state.owners.removeValue(forKey: key)
            }
        }
    }
}
@MainActor func reportStoreScope(
    account: String = reviewModeratorA, cloud: String = "synthetic-review-cloud",
    apple: String = "synthetic-review-apple",
    origin: String = "https://review-host.example.invalid"
) throws -> GatewayReportReviewScope {
    let config = try CloudKitConfiguration(
        containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
    return try .init(
        configuration: .init(origin: URL(string: origin)!),
        owner: .init(configuration: config, accountID: account, cloudKitRecordName: cloud),
        binding: .init(appleUserID: apple, cloudKitRecordName: cloud))
}
func reportStoreIntent() throws -> GatewayReportReviewRecoveryIntent {
    try ReportWireFixture().recovery
}

@Test @MainActor func reportReviewJournalPreservesExactPendingMetadataAcrossRestartAndRotatesLease()
    async throws
{
    let storage = ReportJournalMemoryStorage()
    let scope = try reportStoreScope()
    let intent = try reportStoreIntent()
    let first = GatewayReportReviewJournal(storage: storage)
    let lease = try await first.open(scope: scope)
    let prepared = try await first.prepare(intent, lease: lease)
    let dispatched = try await first.dispatched(prepared, lease: lease)
    let second = GatewayReportReviewJournal(storage: storage)
    let replacement = try await second.open(scope: scope)
    #expect(try await second.pending(lease: replacement) == dispatched)
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) {
        try await first.pending(lease: lease)
    }
    #expect(dispatched.intent == intent && dispatched.phase == .dispatched)
    let text = String(data: try #require(storage.records[scope.digest]), encoding: .utf8)!
    for forbidden in [
        "Bearer", "inspectionID", "expiresAt", "sessionFingerprint", "reason", "\"message\":",
        "PRIVATE-SYNTHETIC-MESSAGE",
        "synthetic-review-apple", "synthetic-review-cloud",
    ] { #expect(!text.contains(forbidden)) }
}

@Test @MainActor func reportReviewJournalNeverOverwritesPendingOrRemovesUnresolvedDecision() async throws {
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    let lease = try await journal.open(scope: scope)
    let intent = try reportStoreIntent()
    let prepared = try await journal.prepare(intent, lease: lease)
    await #expect(throws: GatewayReportReviewJournalFailure.pendingExists) {
        try await journal.prepare(intent, lease: lease)
    }
    let replacement = try GatewayReportReviewRecoveryIntent(
        reportID: intent.reportID, decisionID: UUID().uuidString.lowercased(), verdict: intent.verdict,
        contentHash: intent.contentHash)
    await #expect(throws: GatewayReportReviewJournalFailure.pendingExists) {
        try await journal.prepare(replacement, lease: lease)
    }
    await #expect(throws: GatewayReportReviewJournalFailure.invalidTransition) {
        try await journal.acknowledge(prepared, lease: lease)
    }
    let dispatched = try await journal.dispatched(prepared, lease: lease)
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) {
        try await journal.dispatched(prepared, lease: lease)
    }
    await #expect(throws: GatewayReportReviewJournalFailure.invalidTransition) {
        try await journal.dispatched(dispatched, lease: lease)
    }
    #expect(try await journal.pending(lease: lease) == dispatched)
}

@Test @MainActor func reportReviewJournalResolvesAllOutcomesAndOnlyExactResolvedEntryCanBeAcknowledged()
    async throws
{
    for outcome in [
        GatewayReportReviewOutcome.confirmed(revision: UUID().uuidString.lowercased()), .retired,
        .superseded,
    ] {
        let storage = ReportJournalMemoryStorage()
        let journal = GatewayReportReviewJournal(storage: storage)
        let scope = try reportStoreScope()
        let lease = try await journal.open(scope: scope)
        let intent = try reportStoreIntent()
        let prepared = try await journal.prepare(intent, lease: lease)
        let result = GatewayReportReviewRecoveryResult(intent: intent, outcome: outcome)
        let resolved = try await journal.resolve(prepared, result: result, lease: lease)
        #expect(resolved.phase == .resolved && resolved.outcome == outcome)
        await #expect(throws: GatewayReportReviewJournalFailure.inactive) {
            try await journal.acknowledge(prepared, lease: lease)
        }
        try await journal.acknowledge(resolved, lease: lease)
        #expect(try await journal.pending(lease: lease) == nil)
    }
}

@Test @MainActor func reportReviewJournalScopesSeparateOriginNativeAppleICloudAndGatewayAccount() async throws
{
    let scopes = try [
        reportStoreScope(), reportStoreScope(account: reviewModeratorB),
        reportStoreScope(cloud: "other-cloud"),
        reportStoreScope(apple: "other-apple"),
        reportStoreScope(origin: "https://other-review.example.invalid"),
    ]
    #expect(Set(scopes.map(\.digest)).count == scopes.count)
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let intent = try reportStoreIntent()
    var original: GatewayReportReviewJournalEntry?
    for (n, scope) in scopes.enumerated() {
        let lease = try await journal.open(scope: scope)
        if n == 0 {
            original = try await journal.prepare(intent, lease: lease)
        } else {
            #expect(try await journal.pending(lease: lease) == nil)
        }
    }
    #expect(try await journal.pending(lease: journal.open(scope: scopes[0])) == original)
}

@Test @MainActor func reportReviewJournalRejectsCorruptOverlongCrossScopeAndExtraFieldsWithoutDeletingIntent()
    async throws
{
    let scope = try reportStoreScope()
    let other = try reportStoreScope(account: reviewModeratorB)
    let storage = ReportJournalMemoryStorage()
    let first = GatewayReportReviewJournal(storage: storage)
    let lease = try await first.open(scope: scope)
    _ = try await first.prepare(reportStoreIntent(), lease: lease)
    let good = try #require(storage.records[scope.digest])
    let raw = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
    var variants = [Data([0]), Data(repeating: 32, count: 4097)]
    for patch: [String: Any] in [
        ["schemaVersion": 2], ["owner": other.owner.digest], ["scope": other.digest], ["lease": "bad"],
        ["private": "PRIVATE-SENTINEL"],
    ] {
        variants.append(try JSONSerialization.data(withJSONObject: raw.merging(patch) { _, n in n }))
    }
    for data in variants {
        storage.records[scope.digest] = data
        await #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
            try await GatewayReportReviewJournal(storage: storage).open(scope: scope)
        }
        #expect(storage.records[scope.digest] == data)
    }
    storage.records[scope.digest] = good
    let restored = GatewayReportReviewJournal(storage: storage)
    #expect(try await restored.pending(lease: restored.open(scope: scope)) != nil)
}

@Test @MainActor func reportReviewJournalAmbiguousWritesPreserveIDsAndReadbackMismatchFailsClosed()
    async throws
{
    for after in [false, true] {
        let storage = ReportJournalMemoryStorage()
        let scope = try reportStoreScope()
        let intent = try reportStoreIntent()
        let journal = GatewayReportReviewJournal(storage: storage)
        let lease = try await journal.open(scope: scope)
        storage.failAt = storage.writes + 1
        storage.afterWrite = after
        await #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
            try await journal.prepare(intent, lease: lease)
        }
        storage.failAt = nil
        let restored = GatewayReportReviewJournal(storage: storage)
        let newLease = try await restored.open(scope: scope)
        #expect(try await restored.pending(lease: newLease)?.intent == (after ? intent : nil))
    }
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    storage.corruptWrite = true
    await #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
        try await journal.open(scope: reportStoreScope())
    }
}

@Test @MainActor func reportReviewJournalDeletionFenceSurvivesFailedEraseAndBlocksQueuedReopen() async throws
{
    let scope = try reportStoreScope()
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(reportStoreIntent(), lease: lease)
    try journal.fenceForAccountDeletion(binding: scope.binding, accountID: scope.owner.accountID)
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) { try await journal.open(scope: scope) }
    storage.failErase = true
    await #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
        try await journal.erase(owner: scope.owner)
    }
    #expect(storage.records[scope.digest] != nil)
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) { try await journal.open(scope: scope) }
    storage.failErase = false
    try await journal.erase(owner: scope.owner)
    #expect(storage.records[scope.digest] == nil)
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) {
        try await journal.pending(lease: lease)
    }
}

@Test @MainActor func reportReviewJournalErasesAllOriginsForExactOwnerWithoutTouchingOtherAccount()
    async throws
{
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scopes = try [
        reportStoreScope(), reportStoreScope(origin: "https://other-review.example.invalid"),
        reportStoreScope(account: reviewModeratorB),
    ]
    for scope in scopes {
        let lease = try await journal.open(scope: scope)
        _ = try await journal.prepare(reportStoreIntent(), lease: lease)
    }
    try await journal.erase(owner: scopes[0].owner)
    #expect(storage.records.count == 1 && storage.records[scopes[2].digest] != nil)
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) {
        try await journal.open(scope: scopes[1])
    }
    #expect(try await journal.pending(lease: journal.open(scope: scopes[2])) != nil)
}

@Test @MainActor func reportReviewJournalRejectsMismatchedResolutionAndInvalidConfirmedRevision() async throws
{
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    let lease = try await journal.open(scope: scope)
    let intent = try reportStoreIntent()
    let entry = try await journal.prepare(intent, lease: lease)
    let other = try GatewayReportReviewRecoveryIntent(
        reportID: intent.reportID, decisionID: UUID().uuidString.lowercased(), verdict: intent.verdict,
        contentHash: intent.contentHash)
    for changed in [
        other,
        try .init(
            reportID: "community-v1-report-" + String(repeating: "a", count: 64),
            decisionID: intent.decisionID, verdict: intent.verdict, contentHash: intent.contentHash),
        try .init(
            reportID: intent.reportID, decisionID: intent.decisionID, verdict: .dismiss,
            contentHash: intent.contentHash),
        try .init(
            reportID: intent.reportID, decisionID: intent.decisionID, verdict: intent.verdict,
            contentHash: String(repeating: "a", count: 64)),
    ] {
        await #expect(throws: GatewayReportReviewJournalFailure.invalidTransition) {
            try await journal.resolve(
                entry, result: .init(intent: changed, outcome: .notApplied), lease: lease)
        }
    }
    for revision in ["bad", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"] {
        await #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
            try await journal.resolve(
                entry, result: .init(intent: intent, outcome: .confirmed(revision: revision)), lease: lease)
        }
    }
    #expect(try await journal.pending(lease: lease) == entry)
}

@Test @MainActor func reportReviewKeychainNamespaceAccessibilityAndOwnerEraseScopeAreExplicit() async throws {
    let storage = KeychainGatewayReportReviewJournalStorage()
    let scope = try reportStoreScope()
    let query = storage.query(scope)
    let erase = storage.ownerQuery(scope.owner)
    #expect(query[kSecAttrService as String] as? String == "mpvEcho.Echo.gateway.report-review.v1")
    #expect(query[kSecAttrAccount as String] as? String == scope.digest)
    #expect(query[kSecAttrGeneric as String] as? Data == Data(scope.owner.digest.utf8))
    #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(
        erase[kSecAttrAccount as String] == nil
            && erase[kSecAttrGeneric as String] as? Data == Data(scope.owner.digest.utf8))
    #expect(
        KeychainGatewayReportReviewJournalStorage.accessibility as String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
}

@Test @MainActor func reportReviewJournalPeekDoesNotCreateRecordOrRotateLiveLease() async throws {
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    #expect(try await journal.peek(scope: scope) == nil)
    #expect(storage.records.isEmpty && storage.writes == 0)
    let lease = try await journal.open(scope: scope)
    let intent = try reportStoreIntent()
    let entry = try await journal.prepare(intent, lease: lease)
    let writes = storage.writes
    #expect(try await journal.peek(scope: scope) == entry)
    #expect(storage.writes == writes && journal.isActive(lease))
    let recreated = GatewayReportReviewJournal(storage: storage)
    #expect(try await recreated.peek(scope: scope) == entry)
    #expect(storage.writes == writes)
}
@Test @MainActor func reportReviewJournalPeekRejectsErasedAndCorruptScopeWithoutRepair() async throws {
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    storage.records[scope.digest] = Data([0])
    let writes = storage.writes
    await #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
        try await journal.peek(scope: scope)
    }
    #expect(storage.records[scope.digest] == Data([0]) && storage.writes == writes)
    try await journal.erase(owner: scope.owner)
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) { try await journal.peek(scope: scope) }
}

private func reportStoreEventually(_ predicate: @Sendable () -> Bool) async throws {
    for _ in 0..<5000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayReportReviewJournalFailure.unavailable
}

@Test @MainActor func reportReviewJournalStorageNeverBlocksMainActorAndFencedWriteCannotReturnNewAccountData()
    async throws
{
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    let other = try reportStoreScope(account: reviewModeratorB)
    let lease = try await journal.open(scope: scope)
    let intent = try reportStoreIntent()
    storage.gate.arm()
    let running = Task { try await journal.prepare(intent, lease: lease) }
    defer { storage.gate.release() }
    try await reportStoreEventually { storage.gate.hasEntered() }
    journal.fence(lease)
    #expect(!journal.isActive(lease))
    let replacement = Task { try await journal.open(scope: other) }
    storage.gate.release()
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) { try await running.value }
    let otherLease = try await replacement.value
    #expect(try await journal.pending(lease: otherLease) == nil)
    #expect(try await journal.peek(scope: scope)?.intent == intent)
    #expect(!storage.mainThreadIO)
}

@Test @MainActor func reportReviewJournalCancelledWritePreservesOriginalIDsForExplicitRecovery() async throws
{
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    let lease = try await journal.open(scope: scope)
    let intent = try reportStoreIntent()
    storage.gate.arm()
    let running = Task { try await journal.prepare(intent, lease: lease) }
    defer { storage.gate.release() }
    try await reportStoreEventually { storage.gate.hasEntered() }
    running.cancel()
    storage.gate.release()
    await #expect(throws: GatewayFailure.cancelled) { try await running.value }
    let restarted = GatewayReportReviewJournal(storage: storage)
    let newLease = try await restarted.open(scope: scope)
    let pending = try #require(await restarted.pending(lease: newLease))
    #expect(pending.intent == intent && pending.phase == .prepared)
    await #expect(throws: GatewayReportReviewJournalFailure.pendingExists) {
        try await restarted.prepare(intent, lease: newLease)
    }
    #expect(!storage.mainThreadIO)
}

@Test @MainActor func reportReviewJournalPreCancelledCommandsNeverReadWriteOrRotateExistingLease()
    async throws
{
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    let lease = try await journal.open(scope: scope)
    let intent = try reportStoreIntent()
    let entry = try await journal.prepare(intent, lease: lease)
    let writes = storage.writes
    let reads = storage.reads
    for command in ["open", "peek", "pending", "prepare", "dispatch", "retire", "resolve", "acknowledge"] {
        let running = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            switch command {
            case "open": _ = try await journal.open(scope: scope)
            case "peek": _ = try await journal.peek(scope: scope)
            case "pending": _ = try await journal.pending(lease: lease)
            case "prepare": _ = try await journal.prepare(intent, lease: lease)
            case "dispatch": _ = try await journal.dispatched(entry, lease: lease)
            case "retire": _ = try await journal.retiring(entry, lease: lease)
            case "resolve":
                _ = try await journal.resolve(
                    entry, result: .init(intent: intent, outcome: .notApplied), lease: lease)
            default: try await journal.acknowledge(entry, lease: lease)
            }
        }
        await #expect(throws: GatewayFailure.cancelled) { try await running.value }
        #expect(journal.isActive(lease) && storage.writes == writes && storage.reads == reads)
    }
    #expect(try await journal.pending(lease: lease) == entry)
}

@Test @MainActor
func reportReviewJournalAmbiguousDispatchAndResolutionAreReopenedWithoutInventingAnotherDecision()
    async throws
{
    for phase in ["dispatch", "resolve"] {
        for after in [false, true] {
            let storage = ReportJournalMemoryStorage()
            let journal = GatewayReportReviewJournal(storage: storage)
            let scope = try reportStoreScope()
            let lease = try await journal.open(scope: scope)
            let intent = try reportStoreIntent()
            var entry = try await journal.prepare(intent, lease: lease)
            if phase == "resolve" { entry = try await journal.dispatched(entry, lease: lease) }
            storage.failAt = storage.writes + 1
            storage.afterWrite = after
            let old = entry
            await #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
                if phase == "dispatch" {
                    _ = try await journal.dispatched(old, lease: lease)
                } else {
                    _ = try await journal.resolve(
                        old, result: .init(intent: intent, outcome: .superseded), lease: lease)
                }
            }
            storage.failAt = nil
            let restarted = GatewayReportReviewJournal(storage: storage)
            let newLease = try await restarted.open(scope: scope)
            let pending = try #require(await restarted.pending(lease: newLease))
            #expect(pending.intent == intent)
            #expect(pending.phase == (after ? (phase == "dispatch" ? .dispatched : .resolved) : old.phase))
        }
    }
}

@Test @MainActor func reportReviewJournalPersistedPayloadRejectsWrongIntentPhaseOrOutcomeWithoutRepair()
    async throws
{
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(reportStoreIntent(), lease: lease)
    let good = try #require(storage.records[scope.digest])
    let root = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
    let entry = try #require(root["entry"] as? [String: Any])
    let intent = try #require(entry["intent"] as? [String: Any])
    var invalid: [[String: Any]] = [
        entry.merging(["phase": "unknown"]) { _, n in n }, entry.merging(["phase": "resolved"]) { _, n in n },
        entry.merging(["outcome": "confirmed", "resultRevision": UUID().uuidString.lowercased()]) { _, n in n
        },
        entry.merging(["phase": "resolved", "outcome": "confirmed"]) { _, n in n },
        entry.merging([
            "phase": "resolved", "outcome": "not-applied", "resultRevision": UUID().uuidString.lowercased(),
        ]) { _, n in n },
        entry.merging(["revision": "bad"]) { _, n in n },
    ]
    for patch: [String: Any] in [
        ["reportID": "bad"], ["decisionID": "bad"], ["verdict": "approve"], ["contentHash": "bad"],
        ["message": "PRIVATE-SYNTHETIC"],
    ] {
        invalid.append(entry.merging(["intent": intent.merging(patch) { _, n in n }]) { _, n in n })
    }
    for changed in invalid {
        let data = try JSONSerialization.data(withJSONObject: root.merging(["entry": changed]) { _, n in n })
        storage.records[scope.digest] = data
        await #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
            try await GatewayReportReviewJournal(storage: storage).peek(scope: scope)
        }
        #expect(storage.records[scope.digest] == data)
    }
}

@Test @MainActor func reportReviewJournalAccountDeletionDuringWriteRejectsLateResultAndKeepsOtherAccount()
    async throws
{
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    let other = try reportStoreScope(account: reviewModeratorB)
    let intent = try reportStoreIntent()
    let otherLease = try await journal.open(scope: other)
    let otherEntry = try await journal.prepare(intent, lease: otherLease)
    let lease = try await journal.open(scope: scope)
    storage.gate.arm()
    let running = Task { try await journal.prepare(intent, lease: lease) }
    defer { storage.gate.release() }
    try await reportStoreEventually { storage.gate.hasEntered() }
    try journal.fenceForAccountDeletion(binding: scope.binding, accountID: scope.owner.accountID)
    #expect(!journal.isActive(lease))
    let erasing = Task { try await journal.erase(owner: scope.owner) }
    storage.gate.release()
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) { try await running.value }
    try await erasing.value
    #expect(storage.records[scope.digest] == nil)
    let newOther = try await journal.open(scope: other)
    #expect(try await journal.pending(lease: newOther) == otherEntry)
}

@Test @MainActor func reportReviewJournalSeparateNamespaceCannotLoadAvatarJournalOrMismatchedNativeBinding()
    async throws
{
    let scope = try reportStoreScope()
    let avatar = try reviewStoreScope()
    #expect(scope.owner == avatar.owner && scope.digest != avatar.digest)
    #expect(
        KeychainGatewayReportReviewJournalStorage.service != KeychainGatewayAvatarReviewJournalStorage.service
    )
    #expect(throws: GatewayFailure.accountMismatch) {
        try GatewayReportReviewScope(
            configuration: .init(origin: reportOrigin), owner: scope.owner,
            binding: .init(appleUserID: scope.binding.appleUserID, cloudKitRecordName: "different-cloud"))
    }
    let avatars = ReviewMemoryStorage()
    let journal = GatewayAvatarReviewJournal(storage: avatars)
    _ = try await journal.prepare(reviewStoreIntent(), lease: journal.open(scope: avatar))
    let storage = ReportJournalMemoryStorage()
    let avatarData = try #require(avatars.records[avatar.digest])
    storage.records[scope.digest] = avatarData
    await #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
        try await GatewayReportReviewJournal(storage: storage).open(scope: scope)
    }
}

@Test @MainActor func reportReviewJournalDeletionFenceCapacityFailsClosedInsteadOfForgettingEarlierOwners()
    async throws
{
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(reportStoreIntent(), lease: lease)
    for index in 0..<33 {
        let cloud = "synthetic-fence-" + String(index)
        try journal.fenceForAccountDeletion(
            binding: .init(appleUserID: "synthetic-apple-" + String(index), cloudKitRecordName: cloud),
            accountID: nil)
    }
    #expect(!journal.isActive(lease))
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) { try await journal.open(scope: scope) }
    #expect(storage.records[scope.digest] != nil)
    try await journal.erase(owner: scope.owner)
    #expect(storage.records[scope.digest] == nil)
}

@Test @MainActor
func reportReviewJournalConcreteRuntimeRecoveryIsPersistedAndReopenedWithSameDecisionIdentity() async throws {
    let f = try ReportWireFixture()
    let storage = ReportJournalMemoryStorage()
    let scope = try reportStoreScope()
    let journal = GatewayReportReviewJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let prepared = try await journal.prepare(f.recovery, lease: lease)
    let dispatched = try await journal.dispatched(prepared, lease: lease)
    let response = try await reportClient(
        ReportHTTPStub(f.cases["recover-confirmed"]!), clock: ReviewClock(f.now)
    ).recover(f.recovery, token: reviewBearer)
    let resolved = try await journal.resolve(dispatched, result: response, lease: lease)
    let restarted = GatewayReportReviewJournal(storage: storage)
    let newLease = try await restarted.open(scope: scope)
    #expect(try await restarted.pending(lease: newLease) == resolved)
    #expect(resolved.intent == f.recovery && resolved.outcome == response.outcome)
    try await restarted.acknowledge(resolved, lease: newLease)
    #expect(try await restarted.pending(lease: newLease) == nil)
}

// Real Security IO runs in GatewayReportJournalStorageUITests, inside the app process.
// The standalone package XCTest runner returns errSecMissingEntitlement (-34018).

@Test @MainActor func reportReviewJournalErasedOwnerCapacityClosesAdmissionButStillAllowsExactCleanup()
    async throws
{
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(reportStoreIntent(), lease: lease)
    for index in 0..<32 {
        let other = try reportStoreScope(
            account: UUID().uuidString.lowercased(), cloud: "synthetic-erase-" + String(index))
        try await journal.erase(owner: other.owner)
    }
    storage.failErase = true
    await #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
        try await journal.erase(owner: scope.owner)
    }
    #expect(!journal.isActive(lease) && storage.records[scope.digest] != nil)
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) { try await journal.open(scope: scope) }
    storage.failErase = false
    try await journal.erase(owner: scope.owner)
    #expect(storage.records[scope.digest] == nil)
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) { try await journal.open(scope: scope) }
}

@Test @MainActor func reportReviewJournalInvalidDeletionFenceCannotInvalidateUnrelatedLiveLease() async throws
{
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    let lease = try await journal.open(scope: scope)
    #expect(throws: GatewayReportReviewJournalFailure.unavailable) {
        try journal.fenceForAccountDeletion(binding: scope.binding, accountID: "bad")
    }
    #expect(journal.isActive(lease))
    #expect(try await journal.pending(lease: lease) == nil)
}

@Test @MainActor func reportReviewJournalFreshResolutionCannotBeAcknowledgedByAnEarlierResult() async throws {
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    let lease = try await journal.open(scope: scope)
    let intent = try reportStoreIntent()
    let prepared = try await journal.prepare(intent, lease: lease)
    let first = try await journal.resolve(
        prepared,
        result: .init(intent: intent, outcome: .confirmed(revision: UUID().uuidString.lowercased())),
        lease: lease)
    let next = try await journal.resolve(
        first, result: .init(intent: intent, outcome: first.outcome!), lease: lease)
    #expect(first != next && next.intent == first.intent)
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) {
        try await journal.acknowledge(first, lease: lease)
    }
    #expect(try await journal.pending(lease: lease) == next)
    try await journal.acknowledge(next, lease: lease)
    #expect(try await journal.pending(lease: lease) == nil)
}

@Test @MainActor func reportReviewJournalLateFenceForOldLeaseCannotCloseReopenedScope() async throws {
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let scope = try reportStoreScope()
    let first = try await journal.open(scope: scope)
    let intent = try reportStoreIntent()
    let entry = try await journal.prepare(intent, lease: first)
    let reopened = try await journal.open(scope: scope)
    journal.fence(first)
    #expect(journal.isActive(reopened))
    #expect(try await journal.pending(lease: reopened) == entry)
    await #expect(throws: GatewayReportReviewJournalFailure.inactive) {
        try await journal.pending(lease: first)
    }
}
