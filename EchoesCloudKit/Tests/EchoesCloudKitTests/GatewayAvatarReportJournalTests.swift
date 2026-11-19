import Foundation
import Security
import Testing

@testable import EchoesCloudKit

final class PhotoReportJournalMemoryStorage: GatewayAvatarReportJournalStorage, @unchecked Sendable {
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
    func read(scope: GatewayAvatarReportScope) throws -> Data? {
        lock.withLock {
            state.reads += 1
            state.mainThreadIO = state.mainThreadIO || Thread.isMainThread
            return state.records[scope.digest]
        }
    }
    func write(_ data: Data, scope: GatewayAvatarReportScope) throws {
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
@MainActor func photoStoreScope(
    account: String = reviewModeratorA, cloud: String = "synthetic-review-cloud",
    apple: String = "synthetic-review-apple",
    origin: String = "https://review-host.example.invalid"
) throws -> GatewayAvatarReportScope {
    let config = try CloudKitConfiguration(
        containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
    return try .init(
        configuration: .init(origin: URL(string: origin)!),
        owner: .init(configuration: config, accountID: account, cloudKitRecordName: cloud),
        binding: .init(appleUserID: apple, cloudKitRecordName: cloud))
}
func photoStoreIntent(_ scope: GatewayAvatarReportScope) throws -> GatewayAvatarReportIdentity {
    try .init(accountID: scope.owner.accountID, requestID: UUID().uuidString.lowercased())
}

@Test @MainActor func avatarReportJournalReopensExactDispatchedIdentityAndFencesOldInstance() async throws {
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let identity = try photoStoreIntent(scope)
    let first = GatewayAvatarReportJournal(storage: storage)
    let lease = try await first.open(scope: scope)
    let dispatched = try await first.dispatched(first.prepare(identity, lease: lease), lease: lease)
    let second = GatewayAvatarReportJournal(storage: storage)
    let next = try await second.open(scope: scope)
    #expect(try await second.pending(lease: next) == dispatched)
    await #expect(throws: GatewayAvatarReportJournalFailure.inactive) {
        try await first.pending(lease: lease)
    }
    let data = try #require(storage.records[scope.digest])
    let text = try #require(String(data: data, encoding: .utf8))
    for forbidden in [
        identity.accountID, identity.reportID, "reason", "coordinate", "latitude", "longitude", "ownerID",
        "versionID", "image", "Bearer", "synthetic-review-apple", "synthetic-review-cloud",
    ] { #expect(!text.contains(forbidden)) }
    #expect(text.contains(identity.requestID))
    #expect(!storage.mainThreadIO)
}
@Test @MainActor func avatarReportJournalNeverReplacesPendingOrAcknowledgesUnconfirmedOutcome() async throws {
    for dispatch in [false, true] {
        let storage = PhotoReportJournalMemoryStorage()
        let scope = try photoStoreScope()
        let identity = try photoStoreIntent(scope)
        let journal = GatewayAvatarReportJournal(storage: storage)
        let lease = try await journal.open(scope: scope)
        let prepared = try await journal.prepare(identity, lease: lease)
        let entry = dispatch ? try await journal.dispatched(prepared, lease: lease) : prepared
        let unknown = try await journal.resolve(
            entry, result: .init(identity: identity, outcome: .unconfirmed), lease: lease)
        #expect(unknown.phase == .dispatched && unknown.outcome == .unconfirmed && unknown.intent == identity)
        await #expect(throws: GatewayAvatarReportJournalFailure.pendingExists) {
            try await journal.prepare(photoStoreIntent(scope), lease: lease)
        }
        await #expect(throws: GatewayAvatarReportJournalFailure.invalidTransition) {
            try await journal.acknowledge(unknown, lease: lease)
        }
        await #expect(throws: GatewayAvatarReportJournalFailure.invalidTransition) {
            try await journal.dispatched(unknown, lease: lease)
        }
        #expect(try await journal.pending(lease: lease) == unknown)
    }
}
@Test @MainActor func avatarReportJournalOnlyExactAcceptedResultCanBeAcknowledgedAndCannotBeDowngraded()
    async throws
{
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let identity = try photoStoreIntent(scope)
    let journal = GatewayAvatarReportJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let prepared = try await journal.prepare(identity, lease: lease)
    let unknown = try await journal.resolve(
        prepared, result: .init(identity: identity, outcome: .unconfirmed), lease: lease)
    let resolved = try await journal.resolve(
        unknown, result: .init(identity: identity, outcome: .accepted), lease: lease)
    #expect(resolved.phase == .resolved && resolved.outcome == .accepted)
    await #expect(throws: GatewayAvatarReportJournalFailure.inactive) {
        try await journal.acknowledge(unknown, lease: lease)
    }
    await #expect(throws: GatewayAvatarReportJournalFailure.invalidTransition) {
        try await journal.resolve(
            resolved, result: .init(identity: identity, outcome: .unconfirmed), lease: lease)
    }
    try await journal.acknowledge(resolved, lease: lease)
    #expect(try await journal.pending(lease: lease) == nil)
    _ = try await journal.prepare(photoStoreIntent(scope), lease: lease)
}
@Test @MainActor func avatarReportJournalRejectsAnotherReporterOrRequestBeforeChangingSavedEntry()
    async throws
{
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let identity = try photoStoreIntent(scope)
    let journal = GatewayAvatarReportJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let other = try GatewayAvatarReportIdentity(
        accountID: UUID().uuidString.lowercased(), requestID: identity.requestID)
    let writes = storage.writes
    await #expect(throws: GatewayAvatarReportJournalFailure.invalidTransition) {
        try await journal.prepare(other, lease: lease)
    }
    #expect(storage.writes == writes)
    let entry = try await journal.prepare(identity, lease: lease)
    for wrong in [other, try photoStoreIntent(scope)] {
        await #expect(throws: GatewayAvatarReportJournalFailure.invalidTransition) {
            try await journal.resolve(entry, result: .init(identity: wrong, outcome: .accepted), lease: lease)
        }
    }
    #expect(try await journal.pending(lease: lease) == entry)
}
@Test @MainActor func avatarReportJournalScopeSeparatesNativeIdentityOriginAndGatewayAccount()
    async throws
{
    let scopes = try [
        photoStoreScope(), photoStoreScope(account: reviewModeratorB), photoStoreScope(cloud: "other-cloud"),
        photoStoreScope(apple: "other-apple"), photoStoreScope(origin: "https://other.example.invalid"),
    ]
    #expect(Set(scopes.map(\.digest)).count == scopes.count)
    let storage = PhotoReportJournalMemoryStorage()
    let journal = GatewayAvatarReportJournal(storage: storage)
    for scope in scopes {
        let lease = try await journal.open(scope: scope)
        #expect(try await journal.pending(lease: lease) == nil)
        _ = try await journal.prepare(photoStoreIntent(scope), lease: lease)
    }
    for scope in scopes {
        let entry = try #require(await journal.peek(scope: scope))
        #expect(entry.intent.accountID == scope.owner.accountID)
    }
    #expect(throws: GatewayFailure.accountMismatch) {
        try GatewayAvatarReportScope(
            configuration: .init(origin: photoReportOrigin), owner: scopes[0].owner,
            binding: .init(appleUserID: scopes[0].binding.appleUserID, cloudKitRecordName: "wrong"))
    }
}
@Test @MainActor func avatarReportJournalCorruptionOversizeAndCrossScopeNeverRepairOrDeleteTheSavedAttempt()
    async throws
{
    let scope = try photoStoreScope()
    let storage = PhotoReportJournalMemoryStorage()
    let journal = GatewayAvatarReportJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(photoStoreIntent(scope), lease: lease)
    let original = try #require(storage.records[scope.digest])
    let root = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    for mode in [
        "bad", "large", "extra", "scope", "identity", "resolvedUnknown", "preparedAccepted", "wrongOutcome",
        "badLease",
    ] {
        var value = root
        var entry = try #require(value["entry"] as? [String: Any])
        switch mode {
        case "extra": value["reason"] = "PRIVATE_REASON"
        case "scope": value["scope"] = String(repeating: "a", count: 64)
        case "identity": entry["intent"] = ["requestID": "bad"]
        case "resolvedUnknown":
            entry["phase"] = "resolved"
            entry["outcome"] = "unconfirmed"
        case "preparedAccepted": entry["outcome"] = "accepted"
        case "wrongOutcome":
            entry["phase"] = "dispatched"
            entry["outcome"] = "not-applied"
        case "badLease": value["lease"] = "bad"
        default: break
        }
        value["entry"] = entry
        let bad =
            mode == "bad"
            ? Data([0])
            : mode == "large"
                ? Data(repeating: 32, count: 4097) : try JSONSerialization.data(withJSONObject: value)
        storage.records[scope.digest] = bad
        await #expect(throws: GatewayAvatarReportJournalFailure.unavailable) {
            try await GatewayAvatarReportJournal(storage: storage).open(scope: scope)
        }
        #expect(storage.records[scope.digest] == bad)
    }
    storage.records[scope.digest] = original
    #expect(
        try await GatewayAvatarReportJournal(storage: storage).peek(scope: scope)?.intent.requestID != nil)
}
@Test @MainActor func avatarReportJournalAmbiguousPreparationDispatchAndResolutionKeepOriginalIDOnReopen()
    async throws
{
    for phase in ["prepare", "dispatch", "resolve"] {
        let storage = PhotoReportJournalMemoryStorage()
        let scope = try photoStoreScope()
        let identity = try photoStoreIntent(scope)
        let journal = GatewayAvatarReportJournal(storage: storage)
        let lease = try await journal.open(scope: scope)
        var entry: GatewayAvatarReportJournalEntry?
        if phase != "prepare" { entry = try await journal.prepare(identity, lease: lease) }
        storage.failAt = storage.writes + 1
        storage.afterWrite = true
        await #expect(throws: GatewayAvatarReportJournalFailure.unavailable) {
            if phase == "prepare" {
                _ = try await journal.prepare(identity, lease: lease)
            } else if phase == "dispatch" {
                _ = try await journal.dispatched(entry!, lease: lease)
            } else {
                _ = try await journal.resolve(
                    entry!, result: .init(identity: identity, outcome: .accepted), lease: lease)
            }
        }
        storage.failAt = nil
        let restarted = GatewayAvatarReportJournal(storage: storage)
        let next = try await restarted.open(scope: scope)
        let saved = try #require(await restarted.pending(lease: next))
        #expect(saved.intent == identity)
        #expect(
            saved.phase == (phase == "prepare" ? .prepared : phase == "dispatch" ? .dispatched : .resolved))
    }
}
@Test @MainActor func avatarReportJournalReadbackMismatchFailsClosedAndNeverSubstitutesEmptyPending()
    async throws
{
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let journal = GatewayAvatarReportJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    storage.corruptWrite = true
    await #expect(throws: GatewayAvatarReportJournalFailure.unavailable) {
        try await journal.prepare(photoStoreIntent(scope), lease: lease)
    }
    storage.corruptWrite = false
    await #expect(throws: GatewayAvatarReportJournalFailure.unavailable) {
        try await journal.pending(lease: lease)
    }
    #expect(storage.records[scope.digest] == Data([0]))
}

@Test @MainActor func avatarReportJournalPeekIsReadOnlyAndLateFenceCannotInvalidateNewLease() async throws {
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let journal = GatewayAvatarReportJournal(storage: storage)
    #expect(try await journal.peek(scope: scope) == nil && storage.writes == 0)
    let old = try await journal.open(scope: scope)
    let entry = try await journal.prepare(photoStoreIntent(scope), lease: old)
    let fresh = try await journal.open(scope: scope)
    let writes = storage.writes
    #expect(try await journal.peek(scope: scope) == entry && storage.writes == writes)
    journal.fence(old)
    #expect(journal.isActive(fresh))
    #expect(try await journal.pending(lease: fresh) == entry)
    await #expect(throws: GatewayAvatarReportJournalFailure.inactive) {
        try await journal.pending(lease: old)
    }
}
@Test @MainActor func avatarReportJournalSlowWriteDoesNotBlockMainActorAndCannotReturnAfterScopeFence()
    async throws
{
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let other = try photoStoreScope(account: reviewModeratorB)
    let journal = GatewayAvatarReportJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let identity = try photoStoreIntent(scope)
    storage.gate.arm()
    let running = Task { try await journal.prepare(identity, lease: lease) }
    defer { storage.gate.release() }
    try await photoJournalEventually { storage.gate.hasEntered() }
    journal.fence(lease)
    let reopen = Task { try await journal.open(scope: other) }
    storage.gate.release()
    await #expect(throws: GatewayAvatarReportJournalFailure.inactive) { try await running.value }
    let current = try await reopen.value
    #expect(try await journal.pending(lease: current) == nil)
    #expect(try await journal.peek(scope: scope)?.intent == identity && !storage.mainThreadIO)
}
@Test @MainActor func avatarReportJournalCancelledWriteKeepsOriginalIdentityForExplicitRecovery() async throws
{
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let journal = GatewayAvatarReportJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let identity = try photoStoreIntent(scope)
    storage.gate.arm()
    let running = Task { try await journal.prepare(identity, lease: lease) }
    defer { storage.gate.release() }
    try await photoJournalEventually { storage.gate.hasEntered() }
    running.cancel()
    storage.gate.release()
    await #expect(throws: GatewayFailure.cancelled) { try await running.value }
    let restored = GatewayAvatarReportJournal(storage: storage)
    let next = try await restored.open(scope: scope)
    #expect(try await restored.pending(lease: next)?.intent == identity)
    await #expect(throws: GatewayAvatarReportJournalFailure.pendingExists) {
        try await restored.prepare(photoStoreIntent(scope), lease: next)
    }
}
@Test @MainActor func avatarReportJournalPreCancelledCallsNeverReadWriteOrRotateLiveLease() async throws {
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let journal = GatewayAvatarReportJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let identity = try photoStoreIntent(scope)
    let entry = try await journal.prepare(identity, lease: lease)
    let reads = storage.reads
    let writes = storage.writes
    for command in ["open", "peek", "pending", "prepare", "dispatch", "resolve", "acknowledge"] {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            switch command {
            case "open": _ = try await journal.open(scope: scope)
            case "peek": _ = try await journal.peek(scope: scope)
            case "pending": _ = try await journal.pending(lease: lease)
            case "prepare": _ = try await journal.prepare(identity, lease: lease)
            case "dispatch": _ = try await journal.dispatched(entry, lease: lease)
            case "resolve":
                _ = try await journal.resolve(
                    entry, result: .init(identity: identity, outcome: .accepted), lease: lease)
            default: try await journal.acknowledge(entry, lease: lease)
            }
        }
        await #expect(throws: GatewayFailure.cancelled) { try await task.value }
        #expect(journal.isActive(lease) && storage.reads == reads && storage.writes == writes)
    }
}
@Test @MainActor func avatarReportJournalErasesAllOriginsForExactOwnerAndPreservesOtherAccount() async throws
{
    let storage = PhotoReportJournalMemoryStorage()
    let a = try photoStoreScope()
    let alternate = try photoStoreScope(origin: "https://alternate.example.invalid")
    let b = try photoStoreScope(account: reviewModeratorB)
    let journal = GatewayAvatarReportJournal(storage: storage)
    for scope in [a, alternate, b] {
        let lease = try await journal.open(scope: scope)
        _ = try await journal.prepare(photoStoreIntent(scope), lease: lease)
    }
    try await journal.erase(owner: a.owner)
    #expect(
        storage.records[a.digest] == nil && storage.records[alternate.digest] == nil
            && storage.records[b.digest] != nil)
    #expect(try await journal.peek(scope: b)?.intent.accountID == b.owner.accountID)
    await #expect(throws: GatewayAvatarReportJournalFailure.inactive) { try await journal.open(scope: a) }
    try await journal.erase(owner: a.owner)
}
@Test @MainActor func avatarReportJournalDeletionFenceSurvivesFailedCleanupWithoutRevokingOtherAccount()
    async throws
{
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let other = try photoStoreScope(account: reviewModeratorB)
    let journal = GatewayAvatarReportJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(photoStoreIntent(scope), lease: lease)
    storage.failErase = true
    try journal.fenceForAccountDeletion(binding: scope.binding, accountID: scope.owner.accountID)
    await #expect(throws: GatewayAvatarReportJournalFailure.unavailable) {
        try await journal.erase(owner: scope.owner)
    }
    await #expect(throws: GatewayAvatarReportJournalFailure.inactive) { try await journal.open(scope: scope) }
    let foreign = try await journal.open(scope: other)
    #expect(journal.isActive(foreign))
    #expect(throws: GatewayAvatarReportJournalFailure.unavailable) {
        try journal.fenceForAccountDeletion(binding: scope.binding, accountID: "bad")
    }
    #expect(journal.isActive(foreign))
    storage.failErase = false
    try await journal.erase(owner: scope.owner)
    #expect(storage.records[scope.digest] == nil)
}
@Test @MainActor func avatarReportJournalFenceCapacityFailsClosedWhileExactCleanupStillWorks() async throws {
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let journal = GatewayAvatarReportJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(photoStoreIntent(scope), lease: lease)
    for n in 0..<33 {
        let cloud = "synthetic-photo-fence-" + String(n)
        try journal.fenceForAccountDeletion(
            binding: .init(appleUserID: "synthetic-" + String(n), cloudKitRecordName: cloud), accountID: nil)
    }
    #expect(!journal.isActive(lease))
    await #expect(throws: GatewayAvatarReportJournalFailure.inactive) { try await journal.open(scope: scope) }
    try await journal.erase(owner: scope.owner)
    #expect(storage.records[scope.digest] == nil)
}
@Test @MainActor func avatarReportJournalErasureCapacityNeverForgetsAnEarlierOwnerAndAllowsCleanupRetry()
    async throws
{
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let journal = GatewayAvatarReportJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(photoStoreIntent(scope), lease: lease)
    for n in 0..<32 {
        let other = try photoStoreScope(
            account: UUID().uuidString.lowercased(), cloud: "synthetic-photo-erased-" + String(n))
        try await journal.erase(owner: other.owner)
    }
    storage.failErase = true
    await #expect(throws: GatewayAvatarReportJournalFailure.unavailable) {
        try await journal.erase(owner: scope.owner)
    }
    #expect(!journal.isActive(lease))
    await #expect(throws: GatewayAvatarReportJournalFailure.inactive) { try await journal.open(scope: scope) }
    storage.failErase = false
    try await journal.erase(owner: scope.owner)
    #expect(storage.records[scope.digest] == nil)
}
@Test @MainActor func avatarReportJournalNewRecoveryRevisionRejectsLateResultAndOldAcknowledgement()
    async throws
{
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let journal = GatewayAvatarReportJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let identity = try photoStoreIntent(scope)
    let prepared = try await journal.prepare(identity, lease: lease)
    let first = try await journal.resolve(
        prepared, result: .init(identity: identity, outcome: .unconfirmed), lease: lease)
    let second = try await journal.resolve(
        first, result: .init(identity: identity, outcome: .unconfirmed), lease: lease)
    #expect(first != second)
    await #expect(throws: GatewayAvatarReportJournalFailure.inactive) {
        try await journal.resolve(first, result: .init(identity: identity, outcome: .accepted), lease: lease)
    }
    let accepted = try await journal.resolve(
        second, result: .init(identity: identity, outcome: .accepted), lease: lease)
    await #expect(throws: GatewayAvatarReportJournalFailure.inactive) {
        try await journal.acknowledge(second, lease: lease)
    }
    #expect(try await journal.pending(lease: lease) == accepted)
}
@Test @MainActor func avatarReportJournalConcreteServerNativeRecoveryPersistsSameOwnAttempt() async throws {
    let f = try PhotoReportWireFixture()
    let scope = try photoStoreScope(account: f.submission.identity.accountID)
    let storage = PhotoReportJournalMemoryStorage()
    let journal = GatewayAvatarReportJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    let prepared = try await journal.prepare(f.submission.identity, lease: lease)
    let dispatched = try await journal.dispatched(prepared, lease: lease)
    let result = try await photoReportClient(
        PhotoReportStub(f.cases["recover-accepted"]!), clock: ReviewClock(f.now)
    ).recover(f.submission.identity, token: f.token)
    let resolved = try await journal.resolve(dispatched, result: result, lease: lease)
    let reopened = GatewayAvatarReportJournal(storage: storage)
    let next = try await reopened.open(scope: scope)
    #expect(try await reopened.pending(lease: next) == resolved)
    try await reopened.acknowledge(resolved, lease: next)
    #expect(try await reopened.pending(lease: next) == nil)
}
@Test @MainActor func avatarReportJournalNamespaceCannotReadModeratorJournalAndKeychainIsDeviceOnly()
    async throws
{
    let scope = try photoStoreScope()
    let moderator = try reportStoreScope()
    let storage = PhotoReportJournalMemoryStorage()
    let journal = GatewayAvatarReportJournal(storage: storage)
    #expect(scope.owner == moderator.owner && scope.digest != moderator.digest)
    let old = ReportJournalMemoryStorage()
    let otherJournal = GatewayReportReviewJournal(storage: old)
    _ = try await otherJournal.prepare(reportStoreIntent(), lease: otherJournal.open(scope: moderator))
    storage.records[scope.digest] = try #require(old.records[moderator.digest])
    await #expect(throws: GatewayAvatarReportJournalFailure.unavailable) {
        try await journal.open(scope: scope)
    }
    let keychain = KeychainGatewayAvatarReportJournalStorage()
    let query = keychain.query(scope)
    #expect(
        KeychainGatewayAvatarReportJournalStorage.service != KeychainGatewayReportReviewJournalStorage.service
    )
    #expect(query[kSecAttrAccount as String] as? String == scope.digest)
    #expect(query[kSecAttrGeneric as String] as? Data == Data(scope.owner.digest.utf8))
    #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(
        KeychainGatewayAvatarReportJournalStorage.accessibility
            == kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    #expect(KeychainGatewayAvatarReportJournalStorage.maximumRecords == 32)
}
@Test @MainActor func avatarReportJournalClosedStoredIntentCannotContainOtherAccountOrTargetMetadata()
    async throws
{
    let scope = try photoStoreScope()
    let storage = PhotoReportJournalMemoryStorage()
    let journal = GatewayAvatarReportJournal(storage: storage)
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(photoStoreIntent(scope), lease: lease)
    let original = try #require(storage.records[scope.digest])
    let root = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    for key in ["accountID", "reportID", "ownerID", "versionID", "reason", "coordinate"] {
        var changed = root
        var entry = try #require(root["entry"] as? [String: Any])
        var intent = try #require(entry["intent"] as? [String: Any])
        intent[key] = "PRIVATE_METADATA"
        entry["intent"] = intent
        changed["entry"] = entry
        let bad = try JSONSerialization.data(withJSONObject: changed)
        storage.records[scope.digest] = bad
        await #expect(throws: GatewayAvatarReportJournalFailure.unavailable) {
            try await GatewayAvatarReportJournal(storage: storage).peek(scope: scope)
        }
        #expect(storage.records[scope.digest] == bad)
    }
}
@Test @MainActor
func avatarReportJournalAccountDeletionDuringWriteWithholdsLateEntryAndPreservesOtherAccount() async throws {
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let other = try photoStoreScope(account: reviewModeratorB)
    let journal = GatewayAvatarReportJournal(storage: storage)
    let foreignLease = try await journal.open(scope: other)
    let foreign = try await journal.prepare(photoStoreIntent(other), lease: foreignLease)
    let lease = try await journal.open(scope: scope)
    storage.gate.arm()
    let running = Task { try await journal.prepare(photoStoreIntent(scope), lease: lease) }
    defer { storage.gate.release() }
    try await photoJournalEventually { storage.gate.hasEntered() }
    try journal.fenceForAccountDeletion(binding: scope.binding, accountID: scope.owner.accountID)
    let cleanup = Task { try await journal.erase(owner: scope.owner) }
    storage.gate.release()
    await #expect(throws: GatewayAvatarReportJournalFailure.inactive) { try await running.value }
    try await cleanup.value
    #expect(storage.records[scope.digest] == nil)
    #expect(try await journal.pending(lease: journal.open(scope: other)) == foreign)
}

private func photoJournalEventually(_ predicate: @Sendable () -> Bool) async throws {
    for _ in 0..<5000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw GatewayAvatarReportJournalFailure.unavailable
}

@Test @MainActor func avatarReportJournalCancellationSurvivesReopenWithoutSensitiveMaterial() async throws {
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let journal = GatewayAvatarReportJournal(storage: storage)
    let identity = try photoStoreIntent(scope)
    let lease = try await journal.open(scope: scope)
    let entry = try await journal.cancelling(journal.prepare(identity, lease: lease), lease: lease)
    #expect(entry.phase == .cancelling && entry.outcome == nil)
    let restored = GatewayAvatarReportJournal(storage: storage)
    let next = try await restored.open(scope: scope)
    #expect(try await restored.pending(lease: next) == entry)
    await #expect(throws: GatewayAvatarReportJournalFailure.invalidTransition) {
        try await restored.dispatched(entry, lease: next)
    }
    await #expect(throws: GatewayAvatarReportJournalFailure.invalidTransition) {
        try await restored.acknowledge(entry, lease: next)
    }
    let data = try #require(storage.records[scope.digest])
    let text = try #require(String(data: data, encoding: .utf8))
    for value in [identity.accountID, identity.reportID, "reason", "coordinate", "versionID", "Bearer"] {
        #expect(!text.contains(value))
    }
}
@Test @MainActor func avatarReportJournalAcceptedOrUnknownDuringCancellationCannotReleaseOrResendAttempt()
    async throws
{
    for outcome in [GatewayAvatarReportOutcome.accepted, .unconfirmed] {
        let storage = PhotoReportJournalMemoryStorage()
        let scope = try photoStoreScope()
        let journal = GatewayAvatarReportJournal(storage: storage)
        let identity = try photoStoreIntent(scope)
        let lease = try await journal.open(scope: scope)
        let entry = try await journal.cancelling(
            journal.dispatched(journal.prepare(identity, lease: lease), lease: lease), lease: lease)
        let recovered = try await journal.resolve(
            entry, result: .init(identity: identity, outcome: outcome), lease: lease)
        #expect(recovered.phase == .cancelling && recovered.outcome == outcome)
        await #expect(throws: GatewayAvatarReportJournalFailure.invalidTransition) {
            try await journal.acknowledge(recovered, lease: lease)
        }
        await #expect(throws: GatewayAvatarReportJournalFailure.invalidTransition) {
            try await journal.dispatched(recovered, lease: lease)
        }
        await #expect(throws: GatewayAvatarReportJournalFailure.pendingExists) {
            try await journal.prepare(photoStoreIntent(scope), lease: lease)
        }
        let restored = GatewayAvatarReportJournal(storage: storage)
        let next = try await restored.open(scope: scope)
        #expect(try await restored.pending(lease: next) == recovered)
    }
}
@Test @MainActor func avatarReportJournalOnlyExactCancelledResultClosesCancellationThenAcknowledges()
    async throws
{
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let journal = GatewayAvatarReportJournal(storage: storage)
    let identity = try photoStoreIntent(scope)
    let lease = try await journal.open(scope: scope)
    let entry = try await journal.cancelling(journal.prepare(identity, lease: lease), lease: lease)
    await #expect(throws: GatewayAvatarReportJournalFailure.invalidTransition) {
        try await journal.resolve(
            entry, result: .init(identity: photoStoreIntent(scope), outcome: .cancelled), lease: lease)
    }
    let terminal = try await journal.resolve(
        entry, result: .init(identity: identity, outcome: .cancelled), lease: lease)
    #expect(terminal.phase == .resolved && terminal.outcome == .cancelled)
    await #expect(throws: GatewayAvatarReportJournalFailure.invalidTransition) {
        try await journal.cancelling(terminal, lease: lease)
    }
    try await journal.acknowledge(terminal, lease: lease)
    #expect(try await journal.pending(lease: lease) == nil)
}
@Test @MainActor
func avatarReportJournalCancellationRetryRotatesRevisionSameIdentityAndRejectsStaleCallbacks() async throws {
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let journal = GatewayAvatarReportJournal(storage: storage)
    let identity = try photoStoreIntent(scope)
    let lease = try await journal.open(scope: scope)
    let original = try await journal.dispatched(journal.prepare(identity, lease: lease), lease: lease)
    let first = try await journal.cancelling(original, lease: lease)
    let retry = try await journal.cancelling(first, lease: lease)
    #expect(first.intent == retry.intent && first.revision != retry.revision && retry.phase == .cancelling)
    for stale in [original, first] {
        await #expect(throws: GatewayAvatarReportJournalFailure.inactive) {
            try await journal.resolve(
                stale, result: .init(identity: identity, outcome: .accepted), lease: lease)
        }
        await #expect(throws: GatewayAvatarReportJournalFailure.inactive) {
            try await journal.resolve(
                stale, result: .init(identity: identity, outcome: .cancelled), lease: lease)
        }
    }
    #expect(try await journal.pending(lease: lease) == retry)
}
@Test @MainActor func avatarReportJournalCancellationWriteFailureCannotAuthorizeIOAndKeepsDurableMetadata()
    async throws
{
    for afterWrite in [false, true] {
        let storage = PhotoReportJournalMemoryStorage()
        let scope = try photoStoreScope()
        let journal = GatewayAvatarReportJournal(storage: storage)
        let identity = try photoStoreIntent(scope)
        let lease = try await journal.open(scope: scope)
        let original = try await journal.dispatched(journal.prepare(identity, lease: lease), lease: lease)
        storage.failAt = storage.writes + 1
        storage.afterWrite = afterWrite
        await #expect(throws: GatewayAvatarReportJournalFailure.unavailable) {
            try await journal.cancelling(original, lease: lease)
        }
        storage.failAt = nil
        let restored = GatewayAvatarReportJournal(storage: storage)
        let next = try await restored.open(scope: scope)
        let pending = try #require(try await restored.pending(lease: next))
        #expect(pending.intent == identity && pending.phase == (afterWrite ? .cancelling : .dispatched))
    }
}
@Test @MainActor func avatarReportJournalCancelledRecoveryCanCloseDispatchedAttemptWithoutNewCancelMutation()
    async throws
{
    let storage = PhotoReportJournalMemoryStorage()
    let scope = try photoStoreScope()
    let journal = GatewayAvatarReportJournal(storage: storage)
    let identity = try photoStoreIntent(scope)
    let lease = try await journal.open(scope: scope)
    let entry = try await journal.dispatched(journal.prepare(identity, lease: lease), lease: lease)
    let resolved = try await journal.resolve(
        entry, result: .init(identity: identity, outcome: .cancelled), lease: lease)
    #expect(resolved.phase == .resolved && resolved.outcome == .cancelled)
    try await journal.acknowledge(resolved, lease: lease)
}
