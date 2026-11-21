import Foundation
import Security
import Testing

@testable import EchoesCloudKit

final class ReportedPhotoJournalMemoryStorage: GatewayAvatarReportReviewJournalStorage, @unchecked Sendable {
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
    func read(scope: GatewayAvatarReportReviewScope) throws -> Data? {
        lock.withLock {
            state.reads += 1
            state.mainThreadIO = state.mainThreadIO || Thread.isMainThread
            return state.records[scope.digest]
        }
    }
    func write(_ data: Data, scope: GatewayAvatarReportReviewScope) throws {
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
@MainActor func reportedPhotoStoreScope(
    account: String = reviewModeratorA, cloud: String = "synthetic-review-cloud",
    apple: String = "synthetic-review-apple",
    origin: String = "https://review-host.example.invalid"
) throws -> GatewayAvatarReportReviewScope {
    let config = try CloudKitConfiguration(
        containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
    return try .init(
        configuration: .init(origin: URL(string: origin)!),
        owner: .init(configuration: config, accountID: account, cloudKitRecordName: cloud),
        binding: .init(appleUserID: apple, cloudKitRecordName: cloud))
}
func reportedPhotoStoreIntent() throws -> GatewayAvatarReportReviewSavedIntent {
    let f = try ReportedPhotoWireFixture()
    let frame = try AvatarReportReviewFrame(f.inspection.body, item: f.item, now: f.now)
    return try .init(recovery: f.recovery, photoTarget: frame.target)
}

@Test @MainActor func avatarReportReviewJournalPreservesExactPendingMetadataAcrossRestartAndRotatesLease()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let scope = try reportedPhotoStoreScope()
    let intent = try reportedPhotoStoreIntent()
    let first = GatewayAvatarReportReviewJournal(storage: storage)
    let lease = try await first.open(scope: scope)
    let prepared = try await first.prepare(intent, lease: lease)
    let dispatched = try await first.dispatched(prepared, lease: lease)
    let second = GatewayAvatarReportReviewJournal(storage: storage)
    let replacement = try await second.open(scope: scope)
    #expect(try await second.pending(lease: replacement) == dispatched)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
        try await first.pending(lease: lease)
    }
    #expect(dispatched.intent == intent && dispatched.phase == .dispatched)
    let text = String(data: try #require(storage.records[scope.digest]), encoding: .utf8)!
    for forbidden in [
        "Bearer", "inspectionID", "expiresAt", "sessionFingerprint", "reason", "\"message\":", "manifest",
        "sha256", "width", "height", "inspectionID",
        "PRIVATE_SYNTHETIC_PHOTO_REASON",
        "synthetic-review-apple", "synthetic-review-cloud",
    ] { #expect(!text.contains(forbidden)) }
}

@Test @MainActor func avatarReportReviewJournalNeverOverwritesPendingOrRemovesUnresolvedDecision()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    let lease = try await journal.open(scope: scope)
    let intent = try reportedPhotoStoreIntent()
    let prepared = try await journal.prepare(intent, lease: lease)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.pendingExists) {
        try await journal.prepare(intent, lease: lease)
    }
    let replacement = try GatewayAvatarReportReviewRecoveryIntent(
        reportID: intent.reportID, decisionID: UUID().uuidString.lowercased(), verdict: intent.verdict,
        contentHash: intent.contentHash)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.pendingExists) {
        try await journal.prepare(.init(recovery: replacement, photoTarget: intent.photoTarget), lease: lease)
    }
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.invalidTransition) {
        try await journal.acknowledge(prepared, lease: lease)
    }
    let dispatched = try await journal.dispatched(prepared, lease: lease)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
        try await journal.dispatched(prepared, lease: lease)
    }
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.invalidTransition) {
        try await journal.dispatched(dispatched, lease: lease)
    }
    #expect(try await journal.pending(lease: lease) == dispatched)
}

@Test @MainActor func avatarReportReviewJournalResolvesAllOutcomesAndOnlyExactResolvedEntryCanBeAcknowledged()
    async throws
{
    for outcome in [
        GatewayAvatarReportReviewOutcome.confirmed(revision: UUID().uuidString.lowercased()), .retired,
        .superseded,
    ] {
        let storage = ReportedPhotoJournalMemoryStorage()
        let journal = GatewayAvatarReportReviewJournal(storage: storage)
        let scope = try reportedPhotoStoreScope()
        let lease = try await journal.open(scope: scope)
        let intent = try reportedPhotoStoreIntent()
        let prepared = try await journal.prepare(intent, lease: lease)
        let result = GatewayAvatarReportReviewRecoveryResult(intent: intent.recovery, outcome: outcome)
        let resolved = try await journal.resolve(prepared, result: result, lease: lease)
        #expect(resolved.phase == .resolved && resolved.outcome == outcome)
        await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
            try await journal.acknowledge(prepared, lease: lease)
        }
        try await journal.acknowledge(resolved, lease: lease)
        #expect(try await journal.pending(lease: lease) == nil)
    }
}

@Test @MainActor func avatarReportReviewJournalScopesSeparateOriginNativeAppleICloudAndGatewayAccount()
    async throws
{
    let scopes = try [
        reportedPhotoStoreScope(), reportedPhotoStoreScope(account: reviewModeratorB),
        reportedPhotoStoreScope(cloud: "other-cloud"),
        reportedPhotoStoreScope(apple: "other-apple"),
        reportedPhotoStoreScope(origin: "https://other-review.example.invalid"),
    ]
    #expect(Set(scopes.map(\.digest)).count == scopes.count)
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let intent = try reportedPhotoStoreIntent()
    var original: GatewayAvatarReportReviewJournalEntry?
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

@Test @MainActor
func avatarReportReviewJournalRejectsCorruptOverlongCrossScopeAndExtraFieldsWithoutDeletingIntent()
    async throws
{
    let scope = try reportedPhotoStoreScope()
    let other = try reportedPhotoStoreScope(account: reviewModeratorB)
    let storage = ReportedPhotoJournalMemoryStorage()
    let first = GatewayAvatarReportReviewJournal(storage: storage)
    let lease = try await first.open(scope: scope)
    _ = try await first.prepare(reportedPhotoStoreIntent(), lease: lease)
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
        await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
            try await GatewayAvatarReportReviewJournal(storage: storage).open(scope: scope)
        }
        #expect(storage.records[scope.digest] == data)
    }
    storage.records[scope.digest] = good
    let restored = GatewayAvatarReportReviewJournal(storage: storage)
    #expect(try await restored.pending(lease: restored.open(scope: scope)) != nil)
}

@Test @MainActor func avatarReportReviewJournalAmbiguousWritesPreserveIDsAndReadbackMismatchFailsClosed()
    async throws
{
    for after in [false, true] {
        let storage = ReportedPhotoJournalMemoryStorage()
        let scope = try reportedPhotoStoreScope()
        let intent = try reportedPhotoStoreIntent()
        let journal = GatewayAvatarReportReviewJournal(storage: storage)
        let lease = try await journal.open(scope: scope)
        storage.failAt = storage.writes + 1
        storage.afterWrite = after
        await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
            try await journal.prepare(intent, lease: lease)
        }
        storage.failAt = nil
        let restored = GatewayAvatarReportReviewJournal(storage: storage)
        let newLease = try await restored.open(scope: scope)
        #expect(try await restored.pending(lease: newLease)?.intent == (after ? intent : nil))
    }
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    storage.corruptWrite = true
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
        try await journal.open(scope: reportedPhotoStoreScope())
    }
}

@Test @MainActor func avatarReportReviewJournalDeletionFenceSurvivesFailedEraseAndBlocksQueuedReopen()
    async throws
{
    let scope = try reportedPhotoStoreScope()
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(reportedPhotoStoreIntent(), lease: lease)
    try journal.fenceForAccountDeletion(binding: scope.binding, accountID: scope.owner.accountID)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
        try await journal.open(scope: scope)
    }
    storage.failErase = true
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
        try await journal.erase(owner: scope.owner)
    }
    #expect(storage.records[scope.digest] != nil)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
        try await journal.open(scope: scope)
    }
    storage.failErase = false
    try await journal.erase(owner: scope.owner)
    #expect(storage.records[scope.digest] == nil)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
        try await journal.pending(lease: lease)
    }
}

@Test @MainActor func avatarReportReviewJournalErasesAllOriginsForExactOwnerWithoutTouchingOtherAccount()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scopes = try [
        reportedPhotoStoreScope(), reportedPhotoStoreScope(origin: "https://other-review.example.invalid"),
        reportedPhotoStoreScope(account: reviewModeratorB),
    ]
    for scope in scopes {
        let lease = try await journal.open(scope: scope)
        _ = try await journal.prepare(reportedPhotoStoreIntent(), lease: lease)
    }
    try await journal.erase(owner: scopes[0].owner)
    #expect(storage.records.count == 1 && storage.records[scopes[2].digest] != nil)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
        try await journal.open(scope: scopes[1])
    }
    #expect(try await journal.pending(lease: journal.open(scope: scopes[2])) != nil)
}

@Test @MainActor func avatarReportReviewJournalRejectsMismatchedResolutionAndInvalidConfirmedRevision()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    let lease = try await journal.open(scope: scope)
    let intent = try reportedPhotoStoreIntent()
    let entry = try await journal.prepare(intent, lease: lease)
    let other = try GatewayAvatarReportReviewRecoveryIntent(
        reportID: intent.reportID, decisionID: UUID().uuidString.lowercased(), verdict: intent.verdict,
        contentHash: intent.contentHash)
    for changed in [
        other,
        try .init(
            reportID: "community-v1-avatarreport-" + String(repeating: "a", count: 64),
            decisionID: intent.decisionID, verdict: intent.verdict, contentHash: intent.contentHash),
        try .init(
            reportID: intent.reportID, decisionID: intent.decisionID, verdict: .dismiss,
            contentHash: intent.contentHash),
        try .init(
            reportID: intent.reportID, decisionID: intent.decisionID, verdict: intent.verdict,
            contentHash: String(repeating: "a", count: 64)),
    ] {
        await #expect(throws: GatewayAvatarReportReviewJournalFailure.invalidTransition) {
            try await journal.resolve(
                entry, result: .init(intent: changed, outcome: .notApplied), lease: lease)
        }
    }
    for revision in ["bad", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"] {
        await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
            try await journal.resolve(
                entry, result: .init(intent: intent.recovery, outcome: .confirmed(revision: revision)),
                lease: lease)
        }
    }
    #expect(try await journal.pending(lease: lease) == entry)
}

@Test @MainActor func avatarReportReviewKeychainNamespaceAccessibilityAndOwnerEraseScopeAreExplicit()
    async throws
{
    let storage = KeychainGatewayAvatarReportReviewJournalStorage()
    let scope = try reportedPhotoStoreScope()
    let query = storage.query(scope)
    let erase = storage.ownerQuery(scope.owner)
    #expect(query[kSecAttrService as String] as? String == "mpvEcho.Echo.gateway.avatar-report-review.v1")
    #expect(query[kSecAttrAccount as String] as? String == scope.digest)
    #expect(query[kSecAttrGeneric as String] as? Data == Data(scope.owner.digest.utf8))
    #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(
        erase[kSecAttrAccount as String] == nil
            && erase[kSecAttrGeneric as String] as? Data == Data(scope.owner.digest.utf8))
    #expect(
        KeychainGatewayAvatarReportReviewJournalStorage.accessibility as String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
}

@Test @MainActor func avatarReportReviewJournalPeekDoesNotCreateRecordOrRotateLiveLease() async throws {
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    #expect(try await journal.peek(scope: scope) == nil)
    #expect(storage.records.isEmpty && storage.writes == 0)
    let lease = try await journal.open(scope: scope)
    let intent = try reportedPhotoStoreIntent()
    let entry = try await journal.prepare(intent, lease: lease)
    let writes = storage.writes
    #expect(try await journal.peek(scope: scope) == entry)
    #expect(storage.writes == writes && journal.isActive(lease))
    let recreated = GatewayAvatarReportReviewJournal(storage: storage)
    #expect(try await recreated.peek(scope: scope) == entry)
    #expect(storage.writes == writes)
}
@Test @MainActor func avatarReportReviewJournalPeekRejectsErasedAndCorruptScopeWithoutRepair() async throws {
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    storage.records[scope.digest] = Data([0])
    let writes = storage.writes
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
        try await journal.peek(scope: scope)
    }
    #expect(storage.records[scope.digest] == Data([0]) && storage.writes == writes)
    try await journal.erase(owner: scope.owner)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
        try await journal.peek(scope: scope)
    }
}

private func reportStoreEventually(_ predicate: @Sendable () -> Bool) async throws {
    for _ in 0..<5000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayAvatarReportReviewJournalFailure.unavailable
}

@Test @MainActor
func avatarReportReviewJournalStorageNeverBlocksMainActorAndFencedWriteCannotReturnNewAccountData()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    let other = try reportedPhotoStoreScope(account: reviewModeratorB)
    let lease = try await journal.open(scope: scope)
    let intent = try reportedPhotoStoreIntent()
    storage.gate.arm()
    let running = Task { try await journal.prepare(intent, lease: lease) }
    defer { storage.gate.release() }
    try await reportStoreEventually { storage.gate.hasEntered() }
    journal.fence(lease)
    #expect(!journal.isActive(lease))
    let replacement = Task { try await journal.open(scope: other) }
    storage.gate.release()
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) { try await running.value }
    let otherLease = try await replacement.value
    #expect(try await journal.pending(lease: otherLease) == nil)
    #expect(try await journal.peek(scope: scope)?.intent == intent)
    #expect(!storage.mainThreadIO)
}

@Test @MainActor func avatarReportReviewJournalCancelledWritePreservesOriginalIDsForExplicitRecovery()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    let lease = try await journal.open(scope: scope)
    let intent = try reportedPhotoStoreIntent()
    storage.gate.arm()
    let running = Task { try await journal.prepare(intent, lease: lease) }
    defer { storage.gate.release() }
    try await reportStoreEventually { storage.gate.hasEntered() }
    running.cancel()
    storage.gate.release()
    await #expect(throws: GatewayFailure.cancelled) { try await running.value }
    let restarted = GatewayAvatarReportReviewJournal(storage: storage)
    let newLease = try await restarted.open(scope: scope)
    let pending = try #require(await restarted.pending(lease: newLease))
    #expect(pending.intent == intent && pending.phase == .prepared)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.pendingExists) {
        try await restarted.prepare(intent, lease: newLease)
    }
    #expect(!storage.mainThreadIO)
}

@Test @MainActor func avatarReportReviewJournalPreCancelledCommandsNeverReadWriteOrRotateExistingLease()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    let lease = try await journal.open(scope: scope)
    let intent = try reportedPhotoStoreIntent()
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
                    entry, result: .init(intent: intent.recovery, outcome: .notApplied), lease: lease)
            default: try await journal.acknowledge(entry, lease: lease)
            }
        }
        await #expect(throws: GatewayFailure.cancelled) { try await running.value }
        #expect(journal.isActive(lease) && storage.writes == writes && storage.reads == reads)
    }
    #expect(try await journal.pending(lease: lease) == entry)
}

@Test @MainActor
func avatarReportReviewJournalAmbiguousDispatchAndResolutionAreReopenedWithoutInventingAnotherDecision()
    async throws
{
    for phase in ["dispatch", "resolve"] {
        for after in [false, true] {
            let storage = ReportedPhotoJournalMemoryStorage()
            let journal = GatewayAvatarReportReviewJournal(storage: storage)
            let scope = try reportedPhotoStoreScope()
            let lease = try await journal.open(scope: scope)
            let intent = try reportedPhotoStoreIntent()
            var entry = try await journal.prepare(intent, lease: lease)
            if phase == "resolve" { entry = try await journal.dispatched(entry, lease: lease) }
            storage.failAt = storage.writes + 1
            storage.afterWrite = after
            let old = entry
            await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
                if phase == "dispatch" {
                    _ = try await journal.dispatched(old, lease: lease)
                } else {
                    _ = try await journal.resolve(
                        old, result: .init(intent: intent.recovery, outcome: .superseded), lease: lease)
                }
            }
            storage.failAt = nil
            let restarted = GatewayAvatarReportReviewJournal(storage: storage)
            let newLease = try await restarted.open(scope: scope)
            let pending = try #require(await restarted.pending(lease: newLease))
            #expect(pending.intent == intent)
            #expect(pending.phase == (after ? (phase == "dispatch" ? .dispatched : .resolved) : old.phase))
        }
    }
}

@Test @MainActor func avatarReportReviewJournalPersistedPayloadRejectsWrongIntentPhaseOrOutcomeWithoutRepair()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(reportedPhotoStoreIntent(), lease: lease)
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
        await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
            try await GatewayAvatarReportReviewJournal(storage: storage).peek(scope: scope)
        }
        #expect(storage.records[scope.digest] == data)
    }
}

@Test @MainActor
func avatarReportReviewJournalAccountDeletionDuringWriteRejectsLateResultAndKeepsOtherAccount()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    let other = try reportedPhotoStoreScope(account: reviewModeratorB)
    let intent = try reportedPhotoStoreIntent()
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
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) { try await running.value }
    try await erasing.value
    #expect(storage.records[scope.digest] == nil)
    let newOther = try await journal.open(scope: other)
    #expect(try await journal.pending(lease: newOther) == otherEntry)
}

@Test @MainActor
func avatarReportReviewJournalSeparateNamespaceCannotLoadAvatarJournalOrMismatchedNativeBinding()
    async throws
{
    let scope = try reportedPhotoStoreScope()
    let avatar = try reviewStoreScope()
    #expect(scope.owner == avatar.owner && scope.digest != avatar.digest)
    #expect(
        KeychainGatewayAvatarReportReviewJournalStorage.service
            != KeychainGatewayAvatarReviewJournalStorage.service
    )
    #expect(throws: GatewayFailure.accountMismatch) {
        try GatewayAvatarReportReviewScope(
            configuration: .init(origin: reportOrigin), owner: scope.owner,
            binding: .init(appleUserID: scope.binding.appleUserID, cloudKitRecordName: "different-cloud"))
    }
    let avatars = ReviewMemoryStorage()
    let journal = GatewayAvatarReviewJournal(storage: avatars)
    _ = try await journal.prepare(reviewStoreIntent(), lease: journal.open(scope: avatar))
    let storage = ReportedPhotoJournalMemoryStorage()
    let avatarData = try #require(avatars.records[avatar.digest])
    storage.records[scope.digest] = avatarData
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
        try await GatewayAvatarReportReviewJournal(storage: storage).open(scope: scope)
    }
}

@Test @MainActor
func avatarReportReviewJournalDeletionFenceCapacityFailsClosedInsteadOfForgettingEarlierOwners()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(reportedPhotoStoreIntent(), lease: lease)
    for index in 0..<33 {
        let cloud = "synthetic-fence-" + String(index)
        try journal.fenceForAccountDeletion(
            binding: .init(appleUserID: "synthetic-apple-" + String(index), cloudKitRecordName: cloud),
            accountID: nil)
    }
    #expect(!journal.isActive(lease))
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
        try await journal.open(scope: scope)
    }
    #expect(storage.records[scope.digest] != nil)
    try await journal.erase(owner: scope.owner)
    #expect(storage.records[scope.digest] == nil)
}

@Test @MainActor
func avatarReportReviewJournalConcreteRuntimeRecoveryIsPersistedAndReopenedWithSameDecisionIdentity()
    async throws
{
    let f = try ReportedPhotoWireFixture()
    let storage = ReportedPhotoJournalMemoryStorage()
    let scope = try reportedPhotoStoreScope()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let prepared = try await journal.prepare(reportedPhotoStoreIntent(), lease: lease)
    let dispatched = try await journal.dispatched(prepared, lease: lease)
    let response = try await reportedPhotoClient(
        ReportedPhotoHTTPStub(f.cases["recover-confirmed"]!), clock: ReviewClock(f.now)
    ).recover(f.recovery, token: reviewBearer)
    let resolved = try await journal.resolve(dispatched, result: response, lease: lease)
    let restarted = GatewayAvatarReportReviewJournal(storage: storage)
    let newLease = try await restarted.open(scope: scope)
    #expect(try await restarted.pending(lease: newLease) == resolved)
    #expect(resolved.intent.recovery == f.recovery && resolved.outcome == response.outcome)
    try await restarted.acknowledge(resolved, lease: newLease)
    #expect(try await restarted.pending(lease: newLease) == nil)
}

// Actual Security IO for this new namespace still requires future app-hosted acceptance.
// The standalone package XCTest runner returns errSecMissingEntitlement (-34018).

@Test @MainActor func avatarReportReviewJournalErasedOwnerCapacityClosesAdmissionButStillAllowsExactCleanup()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(reportedPhotoStoreIntent(), lease: lease)
    for index in 0..<32 {
        let other = try reportedPhotoStoreScope(
            account: UUID().uuidString.lowercased(), cloud: "synthetic-erase-" + String(index))
        try await journal.erase(owner: other.owner)
    }
    storage.failErase = true
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
        try await journal.erase(owner: scope.owner)
    }
    #expect(!journal.isActive(lease) && storage.records[scope.digest] != nil)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
        try await journal.open(scope: scope)
    }
    storage.failErase = false
    try await journal.erase(owner: scope.owner)
    #expect(storage.records[scope.digest] == nil)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
        try await journal.open(scope: scope)
    }
}

@Test @MainActor func avatarReportReviewJournalInvalidDeletionFenceCannotInvalidateUnrelatedLiveLease()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    let lease = try await journal.open(scope: scope)
    #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
        try journal.fenceForAccountDeletion(binding: scope.binding, accountID: "bad")
    }
    #expect(journal.isActive(lease))
    #expect(try await journal.pending(lease: lease) == nil)
}

@Test @MainActor func avatarReportReviewJournalFreshResolutionCannotBeAcknowledgedByAnEarlierResult()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    let lease = try await journal.open(scope: scope)
    let intent = try reportedPhotoStoreIntent()
    let prepared = try await journal.prepare(intent, lease: lease)
    let first = try await journal.resolve(
        prepared,
        result: .init(intent: intent.recovery, outcome: .confirmed(revision: UUID().uuidString.lowercased())),
        lease: lease)
    let next = try await journal.resolve(
        first, result: .init(intent: intent.recovery, outcome: first.outcome!), lease: lease)
    #expect(first != next && next.intent == first.intent)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
        try await journal.acknowledge(first, lease: lease)
    }
    #expect(try await journal.pending(lease: lease) == next)
    try await journal.acknowledge(next, lease: lease)
    #expect(try await journal.pending(lease: lease) == nil)
}

@Test @MainActor func avatarReportReviewJournalLateFenceForOldLeaseCannotCloseReopenedScope() async throws {
    let storage = ReportedPhotoJournalMemoryStorage()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let scope = try reportedPhotoStoreScope()
    let first = try await journal.open(scope: scope)
    let intent = try reportedPhotoStoreIntent()
    let entry = try await journal.prepare(intent, lease: first)
    let reopened = try await journal.open(scope: scope)
    journal.fence(first)
    #expect(journal.isActive(reopened))
    #expect(try await journal.pending(lease: reopened) == entry)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
        try await journal.pending(lease: first)
    }
}

@Test @MainActor func avatarReportReviewJournalSavedIntentBindsValidatedTargetWithoutReceiptOrPixels()
    async throws
{
    let f = try ReportedPhotoWireFixture()
    let inspection = try await reportedPhotoInspection(f)
    let decision = try GatewayAvatarReportReviewDecisionIntent(
        receipt: inspection.receipt, decisionID: f.decisionID, verdict: .hidePhoto)
    let saved = try GatewayAvatarReportReviewSavedIntent(decision: decision)
    #expect(saved.recovery == f.recovery && saved.photoTarget == inspection.receipt.photoTarget)
    #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
        try GatewayAvatarReportReviewSavedIntent(recovery: f.recovery, photoTarget: nil)
    }
    let storage = ReportedPhotoJournalMemoryStorage()
    let scope = try reportedPhotoStoreScope()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let entry = try await journal.prepare(saved, lease: lease)
    let data = try #require(storage.records[scope.digest])
    let text = String(data: data, encoding: .utf8)!
    #expect(entry.intent.photoTarget == saved.photoTarget && data.count < 4096)
    let target = try #require(saved.photoTarget)
    #expect(
        text.contains(target.ownerID) && text.contains(target.versionID)
            && text.contains("publicationGeneration"))
    for forbidden in [
        inspection.reason, inspection.receipt.inspectionID, reviewBearer.value, "manifest", "sha256",
        "sessionFingerprint", "expiresAt", "image", "reason", "receipt",
    ] { #expect(!text.contains(forbidden)) }
    #expect(Mirror(reflecting: saved).children.isEmpty && !String(describing: saved).contains(target.ownerID))
    let wire = try #require(
        JSONSerialization.jsonObject(with: GatewayAvatarReportReviewOperation.recover(saved.recovery).wire())
            as? [String: Any])
    #expect(Set(wire.keys) == ["reportID", "decisionID", "verdict", "contentHash"])
}
@Test @MainActor
func avatarReportReviewJournalRetiringAndNotAppliedKeepExactTargetAcrossReopenUntilTerminalACK() async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let scope = try reportedPhotoStoreScope()
    let intent = try reportedPhotoStoreIntent()
    let first = GatewayAvatarReportReviewJournal(storage: storage)
    let lease = try await first.open(scope: scope)
    var entry = try await first.prepare(intent, lease: lease)
    entry = try await first.dispatched(entry, lease: lease)
    entry = try await first.resolve(
        entry, result: .init(intent: intent.recovery, outcome: .notApplied), lease: lease)
    #expect(entry.phase == .dispatched && entry.outcome == .notApplied)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.invalidTransition) {
        try await first.acknowledge(entry, lease: lease)
    }
    entry = try await first.retiring(entry, lease: lease)
    let retiring = entry
    entry = try await first.resolve(
        entry, result: .init(intent: intent.recovery, outcome: .notApplied), lease: lease)
    #expect(entry.phase == .retiring && entry.intent == intent && entry.revision != retiring.revision)
    let next = GatewayAvatarReportReviewJournal(storage: storage)
    let replacement = try await next.open(scope: scope)
    let restored = try #require(await next.pending(lease: replacement))
    #expect(restored == entry && restored.intent.photoTarget == intent.photoTarget)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.invalidTransition) {
        try await next.acknowledge(restored, lease: replacement)
    }
    let terminal = try await next.resolve(
        restored, result: .init(intent: intent.recovery, outcome: .retired), lease: replacement)
    #expect(terminal.phase == .resolved && terminal.intent.photoTarget == intent.photoTarget)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.invalidTransition) {
        try await next.resolve(
            terminal, result: .init(intent: intent.recovery, outcome: .notApplied), lease: replacement)
    }
    try await next.acknowledge(terminal, lease: replacement)
    #expect(try await next.pending(lease: replacement) == nil)
}
@Test @MainActor
func avatarReportReviewJournalStoredHideRequiresClosedValidTargetAndRejectsLegacyFalseTerminalWithoutRepair()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let scope = try reportedPhotoStoreScope()
    let intent = try reportedPhotoStoreIntent()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(intent, lease: lease)
    let original = try #require(storage.records[scope.digest])
    let root = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    let entry = try #require(root["entry"] as? [String: Any])
    let fields = try #require(entry["intent"] as? [String: Any])
    let target = try #require(fields["target"] as? [String: Any])
    var badIntents: [[String: Any]] = [fields.merging(["target": NSNull()]) { _, n in n }]
    var missing = fields
    missing.removeValue(forKey: "target")
    badIntents.append(missing)
    for patch: [String: Any] in [
        ["ownerID": "bad"], ["versionID": "bad"], ["publicationGeneration": 0],
        ["publicationGeneration": true], ["publicationGeneration": 9_007_199_254_740_991],
        ["downloadURL": "PRIVATE"],
    ] {
        badIntents.append(fields.merging(["target": target.merging(patch) { _, n in n }]) { _, n in n })
    }
    var entries = badIntents.map { entry.merging(["intent": $0]) { _, n in n } }
    entries.append(entry.merging(["phase": "resolved", "outcome": "not-applied"]) { _, n in n })
    for invalid in entries {
        let bytes = try JSONSerialization.data(withJSONObject: root.merging(["entry": invalid]) { _, n in n })
        storage.records[scope.digest] = bytes
        let writes = storage.writes
        await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
            try await GatewayAvatarReportReviewJournal(storage: storage).peek(scope: scope)
        }
        #expect(storage.records[scope.digest] == bytes && storage.writes == writes)
    }
}
@Test @MainActor func avatarReportReviewJournalExactEntryCannotRebindPhotoTargetWithSameWireRecovery()
    async throws
{
    let storage = ReportedPhotoJournalMemoryStorage()
    let scope = try reportedPhotoStoreScope()
    let intent = try reportedPhotoStoreIntent()
    let journal = GatewayAvatarReportReviewJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let entry = try await journal.prepare(intent, lease: lease)
    let target = try #require(intent.photoTarget)
    let altered = try GatewayAvatarReportReviewSavedIntent(
        recovery: intent.recovery,
        photoTarget: .init(
            ownerID: target.ownerID, versionID: UUID().uuidString.lowercased(),
            publicationGeneration: target.publicationGeneration + 1))
    let forged = GatewayAvatarReportReviewJournalEntry(
        intent: altered, phase: entry.phase, revision: entry.revision, outcome: entry.outcome)
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.inactive) {
        try await journal.dispatched(forged, lease: lease)
    }
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.pendingExists) {
        try await journal.prepare(altered, lease: lease)
    }
    #expect(try await journal.pending(lease: lease) == entry)
    let terminal = try await journal.resolve(
        entry, result: .init(intent: intent.recovery, outcome: .superseded), lease: lease)
    #expect(terminal.intent.photoTarget == target)
}
@Test @MainActor
func avatarReportReviewJournalMissingPhotoDismissStoresNoTargetAndDoesNotInventOneAfterRestart() async throws
{
    let f = try ReportedPhotoWireFixture()
    let response = try #require(f.cases["inspect-missing"])
    let (root, _) = try reportedPhotoParts(response)
    let item = try reportedPhotoItem(root)
    let material = try await reportedPhotoClient(ReportedPhotoHTTPStub(response), clock: ReviewClock(f.now))
        .inspect(item, token: reviewBearer)
    let decision = try GatewayAvatarReportReviewDecisionIntent(
        receipt: material.receipt, decisionID: UUID().uuidString.lowercased(), verdict: .dismiss)
    let saved = try GatewayAvatarReportReviewSavedIntent(decision: decision)
    #expect(saved.photoTarget == nil)
    let storage = ReportedPhotoJournalMemoryStorage()
    let scope = try reportedPhotoStoreScope()
    let first = GatewayAvatarReportReviewJournal(storage: storage)
    let lease = try await first.open(scope: scope)
    let entry = try await first.prepare(saved, lease: lease)
    let next = GatewayAvatarReportReviewJournal(storage: storage)
    let nextLease = try await next.open(scope: scope)
    #expect(try await next.pending(lease: nextLease) == entry)
    let text = String(data: try #require(storage.records[scope.digest]), encoding: .utf8)!
    #expect(!text.contains("target") && !text.contains("ownerID") && !text.contains("versionID"))
}
@Test @MainActor func avatarReportReviewJournalNamespaceRejectsMessageUploadAndIntakeScopesAndOversizeWrite()
    async throws
{
    let scope = try reportedPhotoStoreScope()
    let message = try reportStoreScope()
    let upload = try reviewStoreScope()
    #expect(scope.owner == message.owner && scope.owner == upload.owner)
    #expect(Set([scope.digest, message.digest, upload.digest]).count == 3)
    #expect(
        Set([
            KeychainGatewayAvatarReportReviewJournalStorage.service,
            KeychainGatewayReportReviewJournalStorage.service,
            KeychainGatewayAvatarReviewJournalStorage.service,
            KeychainGatewayAvatarReportJournalStorage.service,
        ]).count == 4)
    let storage = ReportJournalMemoryStorage()
    let journal = GatewayReportReviewJournal(storage: storage)
    let lease = try await journal.open(scope: message)
    _ = try await journal.prepare(reportStoreIntent(), lease: lease)
    let target = ReportedPhotoJournalMemoryStorage()
    let wrong = try #require(storage.records[message.digest])
    target.records[scope.digest] = wrong
    await #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
        try await GatewayAvatarReportReviewJournal(storage: target).peek(scope: scope)
    }
    #expect(target.records[scope.digest] == wrong && target.writes == 0)
    #expect(throws: GatewayAvatarReportReviewJournalFailure.unavailable) {
        try KeychainGatewayAvatarReportReviewJournalStorage().write(
            Data(repeating: 0, count: 4097), scope: scope)
    }
}
