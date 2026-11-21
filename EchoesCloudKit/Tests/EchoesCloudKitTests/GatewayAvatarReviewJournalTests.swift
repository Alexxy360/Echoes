import Foundation
import Security
import Testing

@testable import EchoesCloudKit

let reviewModeratorA = "6c000000-0000-4000-8000-000000000001"
let reviewModeratorB = "6c000000-0000-4000-8000-000000000002"
final class ReviewStorageGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false, entered = false
    func arm() {
        lock.withLock {
            armed = true
            entered = false
        }
    }
    func blockIfArmed() {
        let hold = lock.withLock {
            if !armed { return false }
            armed = false
            entered = true
            return true
        }
        if hold { semaphore.wait() }
    }
    func hasEntered() -> Bool { lock.withLock { entered } }
    func release() { semaphore.signal() }
}
final class ReviewMemoryStorage: GatewayAvatarReviewJournalStorage, @unchecked Sendable {
    private struct State {
        var records: [String: Data] = [:], owners: [String: String] = [:]
        var writes = 0
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
    func read(scope: GatewayAvatarReviewScope) throws -> Data? {
        lock.withLock {
            state.mainThreadIO = state.mainThreadIO || Thread.isMainThread
            return state.records[scope.digest]
        }
    }
    func write(_ data: Data, scope: GatewayAvatarReviewScope) throws {
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
@MainActor func reviewStoreScope(
    account: String = reviewModeratorA, cloud: String = "synthetic-review-cloud",
    apple: String = "synthetic-review-apple",
    origin: String = "https://review-host.example.invalid"
) throws -> GatewayAvatarReviewScope {
    let config = try CloudKitConfiguration(
        containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
    return try .init(
        configuration: .init(origin: URL(string: origin)!),
        owner: .init(configuration: config, accountID: account, cloudKitRecordName: cloud),
        binding: .init(appleUserID: apple, cloudKitRecordName: cloud))
}
func reviewStoreIntent() throws -> GatewayAvatarReviewRecoveryIntent {
    try #require(ReviewRecoveryWireFixture().rows.first).intent
}

@Test @MainActor func avatarReviewJournalPreservesExactPendingMetadataAcrossRestartAndRotatesLease()
    async throws
{
    let storage = ReviewMemoryStorage()
    let scope = try reviewStoreScope()
    let intent = try reviewStoreIntent()
    let first = GatewayAvatarReviewJournal(storage: storage)
    let lease = try await first.open(scope: scope)
    let prepared = try await first.prepare(intent, lease: lease)
    let dispatched = try await first.dispatched(prepared, lease: lease)
    let second = GatewayAvatarReviewJournal(storage: storage)
    let replacement = try await second.open(scope: scope)
    #expect(try await second.pending(lease: replacement) == dispatched)
    await #expect(throws: GatewayAvatarReviewJournalFailure.inactive) {
        try await first.pending(lease: lease)
    }
    #expect(dispatched.intent == intent && dispatched.phase == .dispatched)
    let text = String(data: try #require(storage.records[scope.digest]), encoding: .utf8)!
    for forbidden in [
        "Bearer", "inspectionID", "expiresAt", "sessionFingerprint", "sha256", "image",
        "synthetic-review-apple", "synthetic-review-cloud",
    ] { #expect(!text.contains(forbidden)) }
}

@Test @MainActor func avatarReviewJournalNeverOverwritesPendingOrRemovesUnresolvedDecision() async throws {
    let storage = ReviewMemoryStorage()
    let journal = GatewayAvatarReviewJournal(storage: storage)
    let scope = try reviewStoreScope()
    let lease = try await journal.open(scope: scope)
    let intent = try reviewStoreIntent()
    let prepared = try await journal.prepare(intent, lease: lease)
    await #expect(throws: GatewayAvatarReviewJournalFailure.pendingExists) {
        try await journal.prepare(intent, lease: lease)
    }
    await #expect(throws: GatewayAvatarReviewJournalFailure.invalidTransition) {
        try await journal.acknowledge(prepared, lease: lease)
    }
    let dispatched = try await journal.dispatched(prepared, lease: lease)
    await #expect(throws: GatewayAvatarReviewJournalFailure.inactive) {
        try await journal.dispatched(prepared, lease: lease)
    }
    await #expect(throws: GatewayAvatarReviewJournalFailure.invalidTransition) {
        try await journal.dispatched(dispatched, lease: lease)
    }
    #expect(try await journal.pending(lease: lease) == dispatched)
}

@Test @MainActor func avatarReviewJournalResolvesAllOutcomesAndOnlyExactResolvedEntryCanBeAcknowledged()
    async throws
{
    for outcome in [
        GatewayAvatarReviewOutcome.confirmed(revision: UUID().uuidString.lowercased()), .retired,
        .superseded,
    ] {
        let storage = ReviewMemoryStorage()
        let journal = GatewayAvatarReviewJournal(storage: storage)
        let scope = try reviewStoreScope()
        let lease = try await journal.open(scope: scope)
        let intent = try reviewStoreIntent()
        let prepared = try await journal.prepare(intent, lease: lease)
        let result = GatewayAvatarReviewRecoveryResult(intent: intent, outcome: outcome)
        let resolved = try await journal.resolve(prepared, result: result, lease: lease)
        #expect(resolved.phase == .resolved && resolved.outcome == outcome)
        await #expect(throws: GatewayAvatarReviewJournalFailure.inactive) {
            try await journal.acknowledge(prepared, lease: lease)
        }
        try await journal.acknowledge(resolved, lease: lease)
        #expect(try await journal.pending(lease: lease) == nil)
    }
}

@Test @MainActor func avatarReviewJournalScopesSeparateOriginNativeAppleICloudAndGatewayAccount() async throws
{
    let scopes = try [
        reviewStoreScope(), reviewStoreScope(account: reviewModeratorB),
        reviewStoreScope(cloud: "other-cloud"),
        reviewStoreScope(apple: "other-apple"),
        reviewStoreScope(origin: "https://other-review.example.invalid"),
    ]
    #expect(Set(scopes.map(\.digest)).count == scopes.count)
    let storage = ReviewMemoryStorage()
    let journal = GatewayAvatarReviewJournal(storage: storage)
    let intent = try reviewStoreIntent()
    var original: GatewayAvatarReviewJournalEntry?
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

@Test @MainActor func avatarReviewJournalRejectsCorruptOverlongCrossScopeAndExtraFieldsWithoutDeletingIntent()
    async throws
{
    let scope = try reviewStoreScope()
    let other = try reviewStoreScope(account: reviewModeratorB)
    let storage = ReviewMemoryStorage()
    let first = GatewayAvatarReviewJournal(storage: storage)
    let lease = try await first.open(scope: scope)
    _ = try await first.prepare(reviewStoreIntent(), lease: lease)
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
        await #expect(throws: GatewayAvatarReviewJournalFailure.unavailable) {
            try await GatewayAvatarReviewJournal(storage: storage).open(scope: scope)
        }
        #expect(storage.records[scope.digest] == data)
    }
    storage.records[scope.digest] = good
    let restored = GatewayAvatarReviewJournal(storage: storage)
    #expect(try await restored.pending(lease: restored.open(scope: scope)) != nil)
}

@Test @MainActor func avatarReviewJournalAmbiguousWritesPreserveIDsAndReadbackMismatchFailsClosed()
    async throws
{
    for after in [false, true] {
        let storage = ReviewMemoryStorage()
        let scope = try reviewStoreScope()
        let intent = try reviewStoreIntent()
        let journal = GatewayAvatarReviewJournal(storage: storage)
        let lease = try await journal.open(scope: scope)
        storage.failAt = storage.writes + 1
        storage.afterWrite = after
        await #expect(throws: GatewayAvatarReviewJournalFailure.unavailable) {
            try await journal.prepare(intent, lease: lease)
        }
        storage.failAt = nil
        let restored = GatewayAvatarReviewJournal(storage: storage)
        let newLease = try await restored.open(scope: scope)
        #expect(try await restored.pending(lease: newLease)?.intent == (after ? intent : nil))
    }
    let storage = ReviewMemoryStorage()
    let journal = GatewayAvatarReviewJournal(storage: storage)
    storage.corruptWrite = true
    await #expect(throws: GatewayAvatarReviewJournalFailure.unavailable) {
        try await journal.open(scope: reviewStoreScope())
    }
}

@Test @MainActor func avatarReviewJournalDeletionFenceSurvivesFailedEraseAndBlocksQueuedReopen() async throws
{
    let scope = try reviewStoreScope()
    let storage = ReviewMemoryStorage()
    let journal = GatewayAvatarReviewJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(reviewStoreIntent(), lease: lease)
    try journal.fenceForAccountDeletion(binding: scope.binding, accountID: scope.owner.accountID)
    await #expect(throws: GatewayAvatarReviewJournalFailure.inactive) { try await journal.open(scope: scope) }
    storage.failErase = true
    await #expect(throws: GatewayAvatarReviewJournalFailure.unavailable) {
        try await journal.erase(owner: scope.owner)
    }
    #expect(storage.records[scope.digest] != nil)
    await #expect(throws: GatewayAvatarReviewJournalFailure.inactive) { try await journal.open(scope: scope) }
    storage.failErase = false
    try await journal.erase(owner: scope.owner)
    #expect(storage.records[scope.digest] == nil)
    await #expect(throws: GatewayAvatarReviewJournalFailure.inactive) {
        try await journal.pending(lease: lease)
    }
}

@Test @MainActor func avatarReviewJournalErasesAllOriginsForExactOwnerWithoutTouchingOtherAccount()
    async throws
{
    let storage = ReviewMemoryStorage()
    let journal = GatewayAvatarReviewJournal(storage: storage)
    let scopes = try [
        reviewStoreScope(), reviewStoreScope(origin: "https://other-review.example.invalid"),
        reviewStoreScope(account: reviewModeratorB),
    ]
    for scope in scopes {
        let lease = try await journal.open(scope: scope)
        _ = try await journal.prepare(reviewStoreIntent(), lease: lease)
    }
    try await journal.erase(owner: scopes[0].owner)
    #expect(storage.records.count == 1 && storage.records[scopes[2].digest] != nil)
    await #expect(throws: GatewayAvatarReviewJournalFailure.inactive) {
        try await journal.open(scope: scopes[1])
    }
    #expect(try await journal.pending(lease: journal.open(scope: scopes[2])) != nil)
}

@Test @MainActor func avatarReviewJournalRejectsMismatchedResolutionAndInvalidConfirmedRevision() async throws
{
    let storage = ReviewMemoryStorage()
    let journal = GatewayAvatarReviewJournal(storage: storage)
    let scope = try reviewStoreScope()
    let lease = try await journal.open(scope: scope)
    let intent = try reviewStoreIntent()
    let entry = try await journal.prepare(intent, lease: lease)
    let other = try GatewayAvatarReviewRecoveryIntent(
        item: intent.item, decisionID: UUID().uuidString.lowercased(), verdict: intent.verdict)
    await #expect(throws: GatewayAvatarReviewJournalFailure.invalidTransition) {
        try await journal.resolve(entry, result: .init(intent: other, outcome: .notApplied), lease: lease)
    }
    for revision in ["bad", intent.item.reviewRevision] {
        await #expect(throws: GatewayAvatarReviewJournalFailure.unavailable) {
            try await journal.resolve(
                entry, result: .init(intent: intent, outcome: .confirmed(revision: revision)), lease: lease)
        }
    }
    #expect(try await journal.pending(lease: lease) == entry)
}

@Test @MainActor func avatarReviewKeychainNamespaceAccessibilityAndOwnerEraseScopeAreExplicit() async throws {
    let storage = KeychainGatewayAvatarReviewJournalStorage()
    let scope = try reviewStoreScope()
    let query = storage.query(scope)
    let erase = storage.ownerQuery(scope.owner)
    #expect(query[kSecAttrService as String] as? String == "mpvEcho.Echo.gateway.avatar-review.v1")
    #expect(query[kSecAttrAccount as String] as? String == scope.digest)
    #expect(query[kSecAttrGeneric as String] as? Data == Data(scope.owner.digest.utf8))
    #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(
        erase[kSecAttrAccount as String] == nil
            && erase[kSecAttrGeneric as String] as? Data == Data(scope.owner.digest.utf8))
    #expect(
        KeychainGatewayAvatarReviewJournalStorage.accessibility as String
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
}

@Test @MainActor func avatarReviewJournalPeekDoesNotCreateRecordOrRotateLiveLease() async throws {
    let storage = ReviewMemoryStorage()
    let journal = GatewayAvatarReviewJournal(storage: storage)
    let scope = try reviewStoreScope()
    #expect(try await journal.peek(scope: scope) == nil)
    #expect(storage.records.isEmpty && storage.writes == 0)
    let lease = try await journal.open(scope: scope)
    let intent = try reviewStoreIntent()
    let entry = try await journal.prepare(intent, lease: lease)
    let writes = storage.writes
    #expect(try await journal.peek(scope: scope) == entry)
    #expect(storage.writes == writes && journal.isActive(lease))
    let recreated = GatewayAvatarReviewJournal(storage: storage)
    #expect(try await recreated.peek(scope: scope) == entry)
    #expect(storage.writes == writes)
}
@Test @MainActor func avatarReviewJournalPeekRejectsErasedAndCorruptScopeWithoutRepair() async throws {
    let storage = ReviewMemoryStorage()
    let journal = GatewayAvatarReviewJournal(storage: storage)
    let scope = try reviewStoreScope()
    storage.records[scope.digest] = Data([0])
    let writes = storage.writes
    await #expect(throws: GatewayAvatarReviewJournalFailure.unavailable) {
        try await journal.peek(scope: scope)
    }
    #expect(storage.records[scope.digest] == Data([0]) && storage.writes == writes)
    try await journal.erase(owner: scope.owner)
    await #expect(throws: GatewayAvatarReviewJournalFailure.inactive) { try await journal.peek(scope: scope) }
}
