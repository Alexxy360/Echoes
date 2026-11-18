import CryptoKit
import Darwin
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EchoesCloudKit

private final class UploadJournalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 1_794_900_000
    func now() -> Date { lock.withLock { Date(timeIntervalSince1970: time) } }
    func advance(_ value: Double) { lock.withLock { time += value } }
}
private final class UploadJournalFault: @unchecked Sendable {
    private let lock = NSLock()
    private var point: AvatarUploadJournalFiles.WritePoint?
    func install(_ value: AvatarUploadJournalFiles.WritePoint?) { lock.withLock { point = value } }
    func check(_ value: AvatarUploadJournalFiles.WritePoint) throws {
        if lock.withLock({ point == value }) { throw NSError(domain: "PRIVATE-PATH-DO-NOT-EXPOSE", code: 1) }
    }
}
private struct UploadJournalFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "echoes-avatar-upload-" + UUID().uuidString)
    let clock = UploadJournalClock()
    let fault = UploadJournalFault()
    let configuration: GatewayConfiguration
    let cloudKit: CloudKitConfiguration
    let binding: GatewayIdentityBinding
    let owner: PrivateAccountScope
    let scope: GatewayAvatarUploadScope
    let journal: GatewayAvatarUploadJournal
    let avatar: PreparedAvatar
    init() throws {
        configuration = try .init(origin: URL(string: "https://upload-journal.example.invalid")!)
        cloudKit = try .init(containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
        binding = try .init(
            appleUserID: "synthetic-upload-apple", cloudKitRecordName: "synthetic-upload-cloud")
        owner = try .init(
            configuration: cloudKit, accountID: "6a000000-0000-4000-8000-000000000001",
            cloudKitRecordName: "synthetic-upload-cloud")
        scope = try .init(configuration: configuration, privateScope: owner, binding: binding)
        avatar = try AvatarPreparer.prepare(MutationWireFixture().image)
        journal = try .init(
            root: root, clock: { [clock] in clock.now() }, fault: { [fault] in try fault.check($0) })
    }
    var namespace: URL { root.appendingPathComponent(AvatarUploadJournalFiles.namespace) }
    func directory(_ scope: GatewayAvatarUploadScope) -> URL {
        namespace.appendingPathComponent(scope.privateScope.digest).appendingPathComponent(scope.digest)
    }
    func file(_ scope: GatewayAvatarUploadScope) -> URL {
        directory(scope).appendingPathComponent("record.bin")
    }
    func intent(_ id: String = "6a000000-0000-4000-8000-000000000003") throws -> GatewayAvatarUploadIntent {
        try .init(requestID: id, versionID: "6a000000-0000-4000-8000-000000000004", expectedGeneration: 0)
    }
    func publication(revision: String = "6a000000-0000-4000-8000-000000000005") throws
        -> GatewayAvatarPublishIntent
    {
        let selected = try intent()
        return try .init(
            requestID: selected.requestID, versionID: selected.versionID, generation: 1,
            reviewRevision: revision)
    }
    func alternate(
        account: String? = nil, origin: URL? = nil, apple: String = "synthetic-upload-apple",
        cloud: String = "synthetic-upload-cloud"
    ) throws -> GatewayAvatarUploadScope {
        let binding = try GatewayIdentityBinding(appleUserID: apple, cloudKitRecordName: cloud)
        let owner = try PrivateAccountScope(
            configuration: cloudKit, accountID: account ?? self.owner.accountID, cloudKitRecordName: cloud)
        return try .init(
            configuration: origin.map { try GatewayConfiguration(origin: $0) } ?? configuration,
            privateScope: owner, binding: binding)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func avatarPublicationJournalStoresOnlyMetadataAndSurvivesRestartWithoutTTL() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let choice = try f.publication()
    let prepared = try await f.journal.preparePublication(intent: choice, lease: lease)
    #expect(prepared.intent == .publish(choice) && prepared.phase == .prepared && !prepared.hasSource)
    #expect(prepared.sourceSHA256 == nil && prepared.sourceByteCount == nil)
    let bytes = try Data(contentsOf: f.file(f.scope))
    let decoded = try AvatarUploadRecordCodec.decode(bytes, scope: f.scope)
    #expect(bytes.count < 4096 && decoded.source.isEmpty)
    #expect(decoded.record.entry?.reviewRevision == choice.reviewRevision)
    await #expect(throws: GatewayAvatarUploadJournalFailure.sourceUnavailable) {
        try await f.journal.source(for: prepared, lease: lease)
    }
    let dispatched = try await f.journal.transition(prepared, to: .publishing, lease: lease)
    f.clock.advance(30 * 86400)
    #expect(try await f.journal.pending(lease: lease) == dispatched)
    await f.journal.close()
    let reopened = try GatewayAvatarUploadJournal(root: f.root, clock: { f.clock.now() })
    let fresh = try await reopened.open(scope: f.scope)
    #expect(fresh.id != lease.id)
    #expect(try await reopened.pending(lease: fresh) == dispatched)
    await reopened.close()
}

@Test func avatarPublicationJournalAtomicallyReplacesOnlyTheExactStagedUploadAndDropsJPEG() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let source = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    let sent = try await f.journal.transition(source, to: .dispatched, lease: lease)
    let staged = try await f.journal.transition(sent, to: .staged, lease: lease)
    let metadata = try await f.journal.preparePublication(
        intent: f.publication(), replacing: staged, lease: lease)
    #expect(metadata.phase == .prepared && !metadata.hasSource && metadata.sourceSHA256 == nil)
    let bytes = try Data(contentsOf: f.file(f.scope))
    #expect(bytes.count < 4096 && bytes.range(of: f.avatar.image) == nil)
    #expect(try AvatarUploadRecordCodec.decode(bytes, scope: f.scope).source.isEmpty)
    await #expect(throws: GatewayAvatarUploadJournalFailure.superseded) {
        try await f.journal.source(for: staged, lease: lease)
    }
}

@Test func avatarPublicationJournalRefusesUnsettledUploadsClearAndMismatchedPublication() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let prepared = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    await #expect(throws: GatewayAvatarUploadJournalFailure.pendingExists) {
        try await f.journal.preparePublication(intent: f.publication(), replacing: prepared, lease: lease)
    }
    let dispatched = try await f.journal.transition(prepared, to: .dispatched, lease: lease)
    await #expect(throws: GatewayAvatarUploadJournalFailure.pendingExists) {
        try await f.journal.preparePublication(intent: f.publication(), replacing: dispatched, lease: lease)
    }
    let staged = try await f.journal.transition(dispatched, to: .staged, lease: lease)
    let choice = try f.publication()
    let other = try GatewayAvatarPublishIntent(
        requestID: choice.requestID, versionID: UUID().uuidString.lowercased(), generation: 1,
        reviewRevision: choice.reviewRevision)
    await #expect(throws: GatewayAvatarUploadJournalFailure.pendingExists) {
        try await f.journal.preparePublication(intent: other, replacing: staged, lease: lease)
    }
    #expect(try await f.journal.pending(lease: lease) == staged)
    let clear = try await f.journal.prepareClear(
        requestID: UUID().uuidString.lowercased(), expectedGeneration: 1, replacing: staged, lease: lease)
    await #expect(throws: GatewayAvatarUploadJournalFailure.pendingExists) {
        try await f.journal.preparePublication(intent: choice, replacing: clear, lease: lease)
    }
}

@Test func avatarPublicationJournalNeverRenewsUnknownChoiceOrAllowsUploadTransitions() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let choice = try f.publication()
    let prepared = try await f.journal.preparePublication(intent: choice, lease: lease)
    #expect(
        try await f.journal.preparePublication(intent: choice, replacing: prepared, lease: lease) == prepared)
    for phase in [GatewayAvatarJournalPhase.dispatched, .staged] {
        await #expect(throws: GatewayAvatarUploadJournalFailure.invalidTransition) {
            try await f.journal.transition(prepared, to: phase, lease: lease)
        }
    }
    let pending = try await f.journal.transition(prepared, to: .publishing, lease: lease)
    let changed = try f.publication(revision: UUID().uuidString.lowercased())
    await #expect(throws: GatewayAvatarUploadJournalFailure.pendingExists) {
        try await f.journal.preparePublication(intent: changed, replacing: pending, lease: lease)
    }
    let retry = try await f.journal.transition(pending, to: .publishing, lease: lease)
    #expect(
        retry.intent == pending.intent && retry.revision != pending.revision
            && retry.createdAt == pending.createdAt)
    await #expect(throws: GatewayAvatarUploadJournalFailure.superseded) {
        try await f.journal.remove(pending, lease: lease)
    }
    #expect(try await f.journal.pending(lease: lease) == retry)
}

@Test func avatarPublicationJournalClosedVariantRejectsInventedSourceAndCorruptMetadata() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    _ = try await f.journal.preparePublication(intent: f.publication(), lease: lease)
    let original = try Data(contentsOf: f.file(f.scope))
    let start = AvatarUploadRecordCodec.magic.count + 4
    let root = try #require(
        JSONSerialization.jsonObject(with: original.subdata(in: start..<original.count)) as? [String: Any])
    for change: [String: Any] in [
        ["sourcePresent": false], ["sourceSHA256": String(repeating: "a", count: 64)],
        ["sourceByteCount": 0], ["reviewRevision": "bad"], ["consentVersion": 0], ["phase": "staged"],
        ["unknown": true],
    ] {
        var corrupted = root
        corrupted["entry"] = try #require(root["entry"] as? [String: Any]).merging(change) { _, new in new }
        let body = try JSONSerialization.data(withJSONObject: corrupted)
        let count = UInt32(body.count)
        var bytes = AvatarUploadRecordCodec.magic
        bytes.append(contentsOf: [
            UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255),
        ])
        bytes.append(body)
        #expect(throws: GatewayAvatarUploadJournalFailure.invalidData) {
            try AvatarUploadRecordCodec.decode(bytes, scope: f.scope)
        }
    }
    #expect(throws: GatewayAvatarUploadJournalFailure.invalidData) {
        try AvatarUploadRecordCodec.decode(original + Data([0xff, 0xd8, 0xff, 0xd9]), scope: f.scope)
    }
    #expect(try Data(contentsOf: f.file(f.scope)) == original)
}

@Test func avatarPublicationJournalOwnerErasureRemovesEveryOriginAndPreservesAnotherAccount() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let originB = try f.alternate(origin: URL(string: "https://other-upload.example.invalid")!)
    let other = try f.alternate(account: "6a000000-0000-4000-8000-000000000099")
    for scope in [f.scope, originB, other] {
        let lease = try await f.journal.open(scope: scope)
        _ = try await f.journal.preparePublication(intent: f.publication(), lease: lease)
    }
    try await f.journal.fenceForAccountDeletion(binding: f.binding, accountID: f.owner.accountID)
    try await f.journal.erase(scope: f.owner)
    #expect(!FileManager.default.fileExists(atPath: f.file(f.scope).path))
    #expect(!FileManager.default.fileExists(atPath: f.file(originB).path))
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) {
        try await f.journal.open(scope: f.scope)
    }
    let lease = try await f.journal.open(scope: other)
    #expect(try await f.journal.pending(lease: lease)?.intent == .publish(f.publication()))
}

@Test func avatarPublicationJournalInterruptedPreparationKeepsOnlyOldOrNewWholeMetadata() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let choice = try f.publication()
    let empty = try Data(contentsOf: f.file(f.scope))
    f.fault.install(.beforeRename)
    await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) {
        try await f.journal.preparePublication(intent: choice, lease: lease)
    }
    #expect(try Data(contentsOf: f.file(f.scope)) == empty)
    #expect(try await f.journal.pending(lease: lease) == nil)
    f.fault.install(.afterRename)
    await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) {
        try await f.journal.preparePublication(intent: choice, lease: lease)
    }
    f.fault.install(nil)
    let unknown = try #require(await f.journal.pending(lease: lease))
    #expect(unknown.intent == .publish(choice) && unknown.phase == .prepared && !unknown.hasSource)
    await f.journal.close()
    let reopened = try GatewayAvatarUploadJournal(root: f.root, clock: { f.clock.now() })
    let fresh = try await reopened.open(scope: f.scope)
    #expect(try await reopened.pending(lease: fresh) == unknown)
    await reopened.close()
}

@Test func avatarUploadJournalAtomicallyStoresPreparedJPEGAndPreservesIDsAcrossEveryPhase() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let intent = try f.intent()
    let prepared = try await f.journal.prepareUpload(intent: intent, avatar: f.avatar, lease: lease)
    #expect(prepared.intent == .upload(intent) && prepared.phase == .prepared && prepared.hasSource)
    #expect(prepared.sourceByteCount == f.avatar.image.count)
    #expect(prepared.sourceSHA256 == AvatarUploadRecordCodec.digest(f.avatar.image))
    #expect(try await f.journal.source(for: prepared, lease: lease) == f.avatar.image)
    let dispatched = try await f.journal.transition(prepared, to: .dispatched, lease: lease)
    let staged = try await f.journal.transition(dispatched, to: .staged, lease: lease)
    let publishing = try await f.journal.transition(staged, to: .publishing, lease: lease)
    let restored = try await f.journal.transition(publishing, to: .staged, lease: lease)
    #expect(restored.intent == prepared.intent && restored.createdAt == prepared.createdAt)
    #expect(restored.revision != prepared.revision && restored.sourceSHA256 == prepared.sourceSHA256)
    try await f.journal.remove(restored, lease: lease)
    #expect(try await f.journal.pending(lease: lease) == nil)
    #expect(try Data(contentsOf: f.file(f.scope)).range(of: f.avatar.image) == nil)
}

@Test func avatarUploadJournalReopenKeepsPendingSourceAndOldStoreCannotWriteAfterClose() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let first = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    let dispatched = try await f.journal.transition(first, to: .dispatched, lease: lease)
    await f.journal.close()
    let reopened = try GatewayAvatarUploadJournal(root: f.root, clock: { f.clock.now() })
    let newer = try await reopened.open(scope: f.scope)
    let pending = try #require(await reopened.pending(lease: newer))
    #expect(pending == dispatched && pending.phase == .dispatched)
    #expect(try await reopened.source(for: pending, lease: newer) == f.avatar.image)
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) {
        try await f.journal.open(scope: f.scope)
    }
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) {
        try await f.journal.remove(dispatched, lease: lease)
    }
}

@Test func avatarUploadJournalLifetimeLockRejectsCompetingInstancesWithoutUnlockingTheFirst() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    #expect(throws: GatewayAvatarUploadJournalFailure.busy) { try GatewayAvatarUploadJournal(root: f.root) }
    let lease = try await f.journal.open(scope: f.scope)
    _ = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    #expect(throws: GatewayAvatarUploadJournalFailure.busy) { try GatewayAvatarUploadJournal(root: f.root) }
    #expect(try await f.journal.pending(lease: lease)?.hasSource == true)
}

@Test func avatarUploadJournalSeparatesAccountOriginNativeIdentityAndICloudWithLateFenceProtection()
    async throws
{
    for change in 0..<4 {
        let f = try UploadJournalFixture()
        defer { f.cleanup() }
        let old = try await f.journal.open(scope: f.scope)
        let entry = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: old)
        let other: GatewayAvatarUploadScope
        switch change {
        case 0: other = try f.alternate(account: "6a000000-0000-4000-8000-000000000002")
        case 1: other = try f.alternate(origin: URL(string: "https://other-upload.example.invalid")!)
        case 2: other = try f.alternate(apple: "other-native")
        default: other = try f.alternate(cloud: "other-icloud")
        }
        let otherLease = try await f.journal.open(scope: other)
        #expect(try await f.journal.pending(lease: otherLease) == nil)
        await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) {
            try await f.journal.source(for: entry, lease: old)
        }
        let fresh = try await f.journal.open(scope: f.scope)
        await f.journal.fence(old)
        #expect(try await f.journal.source(for: entry, lease: fresh) == f.avatar.image)
    }
}

@Test func avatarUploadJournalDoesNotOverwritePendingIntentOrAcceptStaleAcknowledgements() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let original = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    let bytes = try Data(contentsOf: f.file(f.scope))
    await #expect(throws: GatewayAvatarUploadJournalFailure.pendingExists) {
        try await f.journal.prepareUpload(
            intent: f.intent(UUID().uuidString.lowercased()), avatar: f.avatar, lease: lease)
    }
    #expect(try Data(contentsOf: f.file(f.scope)) == bytes)
    let next = try await f.journal.transition(original, to: .dispatched, lease: lease)
    await #expect(throws: GatewayAvatarUploadJournalFailure.superseded) {
        try await f.journal.remove(original, lease: lease)
    }
    await #expect(throws: GatewayAvatarUploadJournalFailure.superseded) {
        try await f.journal.transition(original, to: .staged, lease: lease)
    }
    #expect(try await f.journal.pending(lease: lease) == next)
}

@Test func avatarUploadJournalExplicitClearAtomicallyReplacesExactPendingSourceWithoutReusingUploadID()
    async throws
{
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let original = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    await #expect(throws: GatewayAvatarUploadJournalFailure.superseded) {
        try await f.journal.prepareClear(
            requestID: UUID().uuidString.lowercased(), expectedGeneration: 1, lease: lease)
    }
    await #expect(throws: GatewayAvatarUploadJournalFailure.invalidData) {
        try await f.journal.prepareClear(
            requestID: f.intent().requestID, expectedGeneration: 1, replacing: original, lease: lease)
    }
    let id = UUID().uuidString.lowercased()
    let clear = try await f.journal.prepareClear(
        requestID: id, expectedGeneration: 1, replacing: original, lease: lease)
    #expect(
        clear.intent == .clear(requestID: id, expectedGeneration: 1) && !clear.hasSource
            && clear.sourceSHA256 == nil)
    #expect(try Data(contentsOf: f.file(f.scope)).range(of: f.avatar.image) == nil)
    #expect(
        try await f.journal.prepareClear(requestID: id, expectedGeneration: 1, replacing: clear, lease: lease)
            == clear)
    await #expect(throws: GatewayAvatarUploadJournalFailure.sourceUnavailable) {
        try await f.journal.source(for: clear, lease: lease)
    }
    await #expect(throws: GatewayAvatarUploadJournalFailure.invalidTransition) {
        try await f.journal.transition(clear, to: .staged, lease: lease)
    }
    await #expect(throws: GatewayAvatarUploadJournalFailure.superseded) {
        try await f.journal.transition(original, to: .dispatched, lease: lease)
    }
}

@Test func avatarUploadJournalSourceExpiryKeepsUnknownOperationAndItsOriginalCommitment() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let first = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    let sent = try await f.journal.transition(first, to: .dispatched, lease: lease)
    f.clock.advance(7 * 86400)
    let expired = try #require(await f.journal.pending(lease: lease))
    #expect(!expired.hasSource && expired.intent == sent.intent && expired.phase == .dispatched)
    #expect(
        expired.createdAt == sent.createdAt && expired.sourceSHA256 == sent.sourceSHA256
            && expired.sourceByteCount == sent.sourceByteCount)
    await #expect(throws: GatewayAvatarUploadJournalFailure.sourceUnavailable) {
        try await f.journal.source(for: expired, lease: lease)
    }
    await #expect(throws: GatewayAvatarUploadJournalFailure.sourceUnavailable) {
        try await f.journal.transition(expired, to: .dispatched, lease: lease)
    }
    #expect(try Data(contentsOf: f.file(f.scope)).count < 4096)
    let recovered = try await f.journal.transition(expired, to: .staged, lease: lease)
    #expect(recovered.intent == sent.intent)
    f.clock.advance(86400)
    #expect(try await f.journal.pending(lease: lease) == recovered)
}

@Test func avatarUploadJournalClockRollbackFailsClosedWithoutRenewingOrDiscardingTheSource() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    _ = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    let bytes = try Data(contentsOf: f.file(f.scope))
    f.clock.advance(-301)
    await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) {
        try await f.journal.pending(lease: lease)
    }
    #expect(try Data(contentsOf: f.file(f.scope)) == bytes)
}

@Test func avatarUploadJournalInterruptedAtomicReplacementPreservesOldOrNewWholeRecordAndSameIDs()
    async throws
{
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let entry = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    let old = try Data(contentsOf: f.file(f.scope))
    f.fault.install(.beforeRename)
    await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) {
        try await f.journal.transition(entry, to: .dispatched, lease: lease)
    }
    #expect(try Data(contentsOf: f.file(f.scope)) == old)
    #expect(try await f.journal.pending(lease: lease) == entry)
    f.fault.install(.afterRename)
    await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) {
        try await f.journal.transition(entry, to: .dispatched, lease: lease)
    }
    let unknown = try #require(await f.journal.pending(lease: lease))
    #expect(
        unknown.phase == .dispatched && unknown.intent == entry.intent && unknown.revision != entry.revision)
    f.fault.install(nil)
    await f.journal.close()
    let reopened = try GatewayAvatarUploadJournal(root: f.root, clock: { f.clock.now() })
    let fresh = try await reopened.open(scope: f.scope)
    #expect(try await reopened.pending(lease: fresh) == unknown)
}

@Test func avatarUploadJournalRejectsCorruptionWithoutDiscardingTheUnknownOperation() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let entry = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    let original = try Data(contentsOf: f.file(f.scope))
    for index in [0, AvatarUploadRecordCodec.magic.count, original.count - 10] {
        var damaged = original
        damaged[index] ^= 255
        try damaged.write(to: f.file(f.scope))
        await #expect(throws: GatewayAvatarUploadJournalFailure.invalidData) {
            try await f.journal.pending(lease: lease)
        }
        #expect(try Data(contentsOf: f.file(f.scope)) == damaged)
    }
    try original.write(to: f.file(f.scope))
    #expect(try await f.journal.pending(lease: lease) == entry)
}

private func journalHeaderReplacing(
    _ bytes: Data, change: (inout [String: Any]) throws -> Void
) throws -> Data {
    let offset = AvatarUploadRecordCodec.magic.count
    let length = bytes[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }
    var object = try #require(
        JSONSerialization.jsonObject(with: bytes.subdata(in: (offset + 4)..<(offset + 4 + length)))
            as? [String: Any])
    try change(&object)
    let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let n = UInt32(json.count)
    var result = AvatarUploadRecordCodec.magic
    result.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
    result.append(json)
    result.append(bytes.suffix(from: offset + 4 + length))
    return result
}

@Test func avatarUploadJournalRejectsForeignMetadataAndWrongSourceCommitments() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    _ = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    let original = try Data(contentsOf: f.file(f.scope))
    let changes: [(String, Any)] = [
        ("token", "MUST-NOT-STORE"), ("expectedGeneration", true), ("phase", "unknown"),
        ("kind", "other"), ("sourcePresent", false), ("sourceSHA256", String(repeating: "0", count: 64)),
        ("sourceByteCount", 4), ("width", 513), ("createdAt", -1),
    ]
    for (key, value) in changes {
        let damaged = try journalHeaderReplacing(original) { raw in
            var entry = try #require(raw["entry"] as? [String: Any])
            entry[key] = value
            raw["entry"] = entry
        }
        try damaged.write(to: f.file(f.scope))
        await #expect(throws: GatewayAvatarUploadJournalFailure.invalidData) {
            try await f.journal.pending(lease: lease)
        }
        #expect(try Data(contentsOf: f.file(f.scope)) == damaged)
    }
    for key in ["scope", "privateScope", "lease", "unexpected"] {
        let damaged = try journalHeaderReplacing(original) { $0[key] = "foreign" }
        try damaged.write(to: f.file(f.scope))
        await #expect(throws: GatewayAvatarUploadJournalFailure.invalidData) {
            try await f.journal.pending(lease: lease)
        }
    }
}

@Test func avatarUploadJournalRefusesTransplantedScopeFilesAndPreservesOriginalAccount() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let entry = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    let bytes = try Data(contentsOf: f.file(f.scope))
    let other = try f.alternate(account: "6a000000-0000-4000-8000-000000000002")
    _ = try await f.journal.open(scope: other)
    try bytes.write(to: f.file(other))
    await #expect(throws: GatewayAvatarUploadJournalFailure.invalidData) {
        try await f.journal.open(scope: other)
    }
    let restored = try await f.journal.open(scope: f.scope)
    #expect(try await f.journal.source(for: entry, lease: restored) == f.avatar.image)
}

@Test func avatarUploadJournalRejectsSymlinksHardlinksAndFIFOsWithoutTouchingTarget() async throws {
    for kind in 0..<3 {
        let f = try UploadJournalFixture()
        defer { f.cleanup() }
        let lease = try await f.journal.open(scope: f.scope)
        _ = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
        let target = f.root.appendingPathComponent("outside-target")
        let bytes = try Data(contentsOf: f.file(f.scope))
        try bytes.write(to: target)
        try FileManager.default.removeItem(at: f.file(f.scope))
        switch kind {
        case 0: try FileManager.default.createSymbolicLink(at: f.file(f.scope), withDestinationURL: target)
        case 1: try FileManager.default.linkItem(at: target, to: f.file(f.scope))
        default: #expect(mkfifo(f.file(f.scope).path, 0o600) == 0)
        }
        await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) {
            try await f.journal.pending(lease: lease)
        }
        await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) {
            try await f.journal.open(scope: f.scope)
        }
        try await f.journal.erase(scope: f.owner)
        #expect(try Data(contentsOf: target) == bytes)
    }
}

@Test func avatarUploadJournalUnknownFilesFailErasureAndFenceQueuedOpens() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let entry = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    let unknown = f.directory(f.scope).appendingPathComponent("future-format")
    try Data([1]).write(to: unknown)
    await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) {
        try await f.journal.erase(scope: f.owner)
    }
    #expect(FileManager.default.fileExists(atPath: unknown.path))
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) {
        try await f.journal.open(scope: f.scope)
    }
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) {
        try await f.journal.transition(entry, to: .dispatched, lease: lease)
    }
    try FileManager.default.removeItem(at: unknown)
    try await f.journal.erase(scope: f.owner)
    #expect(!FileManager.default.fileExists(atPath: f.directory(f.scope).path))
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) {
        try await f.journal.open(scope: f.scope)
    }
}

@Test func avatarUploadJournalDeletionFenceBlocksReopenBeforeCleanupAndPreservesOtherAccounts() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let entry = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    try await f.journal.fenceForAccountDeletion(binding: f.binding, accountID: f.owner.accountID)
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) {
        try await f.journal.open(scope: f.scope)
    }
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) {
        try await f.journal.remove(entry, lease: lease)
    }
    let other = try f.alternate(account: "6a000000-0000-4000-8000-000000000002")
    let newer = try await f.journal.open(scope: other)
    let pending = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: newer)
    try await f.journal.erase(scope: f.owner)
    #expect(try await f.journal.source(for: pending, lease: newer) == f.avatar.image)
    try await f.journal.fenceForAccountDeletion(binding: f.binding, accountID: nil)
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) {
        try await f.journal.open(scope: other)
    }
}

@Test func avatarUploadJournalCapsDirectoriesWithoutEvictingPendingSource() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let entry = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    _ = try await f.journal.open(scope: f.alternate(origin: URL(string: "https://second.example.invalid")!))
    await #expect(throws: GatewayAvatarUploadJournalFailure.capacity) {
        try await f.journal.open(scope: f.alternate(origin: URL(string: "https://third.example.invalid")!))
    }
    for suffix in 2...8 {
        _ = try await f.journal.open(
            scope: f.alternate(account: String(format: "6a000000-0000-4000-8000-%012d", suffix)))
    }
    await #expect(throws: GatewayAvatarUploadJournalFailure.capacity) {
        try await f.journal.open(scope: f.alternate(account: "6a000000-0000-4000-8000-000000000009"))
    }
    let restored = try await f.journal.open(scope: f.scope)
    #expect(try await f.journal.source(for: entry, lease: restored) == f.avatar.image)
}

@Test func avatarUploadJournalRemovesOwnedCrashTempsAndRejectsOversizedRecords() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let entry = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    let temporary = f.directory(f.scope).appendingPathComponent(".tmp-" + UUID().uuidString.lowercased())
    try Data([1, 2, 3]).write(to: temporary)
    #expect(try await f.journal.pending(lease: lease) == entry)
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
    try Data(repeating: 0, count: AvatarUploadRecordCodec.maximumFileBytes + 1).write(to: f.file(f.scope))
    await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) {
        try await f.journal.pending(lease: lease)
    }
    #expect(try Data(contentsOf: f.file(f.scope)).count == AvatarUploadRecordCodec.maximumFileBytes + 1)
}

@Test func avatarUploadJournalRefusesNamespaceAndStoreLockReplacement() async throws {
    for replaceNamespace in [false, true] {
        let f = try UploadJournalFixture()
        defer { f.cleanup() }
        let lease = try await f.journal.open(scope: f.scope)
        _ = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
        if replaceNamespace {
            try FileManager.default.moveItem(at: f.namespace, to: f.root.appendingPathComponent("saved"))
            try FileManager.default.createDirectory(at: f.namespace, withIntermediateDirectories: false)
        } else {
            let file = f.namespace.appendingPathComponent(".store.lock")
            try FileManager.default.removeItem(at: file)
            try Data().write(to: file)
        }
        await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) {
            try await f.journal.pending(lease: lease)
        }
        await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) {
            try await f.journal.erase(scope: f.owner)
        }
    }
}

@Test func avatarUploadJournalJPEGValidationRejectsGPSAndCameraMetadata() throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    _ = try AvatarUploadRecordCodec.image(f.avatar.image)
    for metadata in [
        [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 52.0, kCGImagePropertyGPSLatitudeRef: "N",
            ]
        ],
        [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "PRIVATE-CAMERA"]],
        [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "PRIVATE-COMMENT"]],
    ] as [[CFString: Any]] {
        let source = try #require(CGImageSourceCreateWithData(f.avatar.image as CFData, nil))
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        #expect(throws: GatewayAvatarUploadJournalFailure.invalidData) {
            try AvatarUploadRecordCodec.image(output as Data)
        }
    }
}

@Test func avatarUploadJournalUsesPrivatePermissionsBackupExclusionAndRedactedMetadata() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let lease = try await f.journal.open(scope: f.scope)
    let entry = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    for (url, mode) in [(f.namespace, 0o700), (f.directory(f.scope), 0o700), (f.file(f.scope), 0o600)] {
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((info[.posixPermissions] as? NSNumber)?.intValue == mode)
    }
    #expect(try f.namespace.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    for value in [
        String(describing: f.scope), String(reflecting: f.scope), String(describing: lease),
        String(reflecting: entry),
    ] {
        #expect(!value.contains(f.owner.accountID) && !value.contains(f.binding.appleUserID))
        #expect(!value.contains(try f.intent().requestID) && !value.contains(f.root.path))
    }
    let data = try Data(contentsOf: f.file(f.scope))
    #expect(data.range(of: Data(f.owner.accountID.utf8)) == nil)
    #expect(data.range(of: Data(f.binding.appleUserID.utf8)) == nil)
    #expect(data.range(of: Data(f.avatar.thumbnail)) == nil)
}

@Test func avatarUploadJournalCancellationStopsBeforeAccountFileCreation() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    let operation = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await f.journal.open(scope: f.scope)
    }
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(!FileManager.default.fileExists(atPath: f.directory(f.scope).path))
    let foreign = try GatewayIdentityBinding(appleUserID: "other", cloudKitRecordName: "wrong-cloud")
    #expect(throws: GatewayFailure.self) {
        try GatewayAvatarUploadScope(configuration: f.configuration, privateScope: f.owner, binding: foreign)
    }
}

@Test @MainActor func avatarUploadJournalCleanupFailurePreventsPrivateACKAndPreservesOtherOwner() async throws
{
    let f = try UploadJournalFixture()
    let flow = try DeletionFlowFixture()
    defer { f.cleanup() }
    let owner = try PrivateAccountScope(
        configuration: flow.config, accountID: flowAccountID, cloudKitRecordName: flow.owner.name)
    let scope = try GatewayAvatarUploadScope(
        configuration: f.configuration, privateScope: owner, binding: flow.binding)
    let otherLease = try await f.journal.open(scope: f.scope)
    let otherEntry = try await f.journal.prepareUpload(
        intent: f.intent(), avatar: f.avatar, lease: otherLease)
    let lease = try await f.journal.open(scope: scope)
    let entry = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
    let unknown = f.directory(scope).appendingPathComponent("future-format")
    try Data([1]).write(to: unknown)
    flow.fenceHook = { try await f.journal.fenceForAccountDeletion(binding: $0, accountID: $1) }
    flow.localHook = { try await f.journal.erase(scope: owner) }
    flow.cleanup.complete = true
    let controller = flow.controller()
    let started = try await flow.request(controller)
    await #expect(throws: GatewayAvatarUploadJournalFailure.unavailable) {
        try await controller.advance(journalID: started.journalID)
    }
    let pending = try #require(flow.storage.journal().requests.first)
    #expect(pending.contentDeleted && !pending.localDataDeleted && flow.api.ackCalls == 0)
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) {
        try await f.journal.open(scope: scope)
    }
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) {
        try await f.journal.remove(entry, lease: lease)
    }
    try FileManager.default.removeItem(at: unknown)
    controller.suspend()
    let completed = try await flow.controller().advance(journalID: started.journalID)
    #expect(completed.completed && flow.api.ackCalls == 1 && flow.cleanup.calls == 1)
    #expect(!FileManager.default.fileExists(atPath: f.directory(scope).path))
    let restored = try await f.journal.open(scope: f.scope)
    #expect(try await f.journal.source(for: otherEntry, lease: restored) == f.avatar.image)
}

@Test func avatarUploadJournalDeletionFenceSaturationFailsClosedWithBoundedMemory() async throws {
    let f = try UploadJournalFixture()
    defer { f.cleanup() }
    for index in 0...32 {
        let binding = try GatewayIdentityBinding(
            appleUserID: "fence-\(index)", cloudKitRecordName: "fence-\(index)")
        try await f.journal.fenceForAccountDeletion(binding: binding, accountID: nil)
    }
    await #expect(throws: GatewayAvatarUploadJournalFailure.inactive) {
        try await f.journal.open(scope: f.scope)
    }
    #expect(!FileManager.default.fileExists(atPath: f.directory(f.scope).path))
}

#if os(iOS) && !targetEnvironment(simulator)
    private let avatarUploadJournalPhysicalDevice = true
#else
    private let avatarUploadJournalPhysicalDevice = false
#endif

@Test(
    .enabled(
        if: avatarUploadJournalPhysicalDevice,
        "FileProtection requires a physical iOS device; Simulator is not encryption evidence."))
func avatarUploadJournalPhysicalFileProtectionIsComplete() async throws {
    #if os(iOS)
        let f = try UploadJournalFixture()
        defer { f.cleanup() }
        let lease = try await f.journal.open(scope: f.scope)
        _ = try await f.journal.prepareUpload(intent: f.intent(), avatar: f.avatar, lease: lease)
        let attributes = try FileManager.default.attributesOfItem(atPath: f.file(f.scope).path)
        let protection =
            (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? attributes[.protectionKey]
            as? String
        #expect(protection == FileProtectionType.complete.rawValue)
    #endif
}
