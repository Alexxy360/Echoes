import CloudKit
import Foundation
import Testing

@testable import EchoesCloudKit

private let privateAccountID = "50000000-0000-4000-8000-000000000001"
private let privateDeletionID = "60000000-0000-4000-8000-000000000001"
@MainActor final class ZoneOwner: CloudKitAccountSource {
    var name = "owner-A"
    func availability() async throws -> CloudKitAccountAvailability { .available }
    func userRecordName() async throws -> String { name }
}

/// An explicit model of atomic CAS, not CloudKit. testVersion models the server's change tag.
@MainActor final class ZoneModel: PrivateZoneTransport {
    let owner: ZoneOwner
    var records: [CKRecord.ID: CKRecord] = [:]
    var pages: [String: [CKRecord.ID]] = [:]
    var atomic = true
    var modifies = 0, fetches = 0, scans = 0, zoneCreates = 0
    var holdNextProfileSave = false
    var pendingSave: CheckedContinuation<Void, Never>?
    var foreignPage: CKRecord.ID?
    var incompleteEmptyPage = false
    var pageFailure: (any Error)?
    var mutationFailure: (any Error)?
    var loseNextMutationResponse = false
    init(owner: ZoneOwner) { self.owner = owner }
    private func verify(_ scope: PrivateAccountScope) throws {
        guard scope.matchesCloudKitRecordName(owner.name) else { throw PrivateDataFailure.invalidScope }
    }
    func ensureAtomicZone(scope: PrivateAccountScope) async throws {
        try verify(scope)
        guard atomic else { throw PrivateDataFailure.atomicZoneRequired }
        zoneCreates += 1
    }
    func fetch(_ id: CKRecord.ID, scope: PrivateAccountScope, metadataOnly: Bool) async throws -> CKRecord? {
        try verify(scope)
        fetches += 1
        guard let record = records[id] else { return nil }
        if metadataOnly { return CKRecord(recordType: record.recordType, recordID: record.recordID) }
        return record.copy() as? CKRecord
    }
    func modify(saving: [CKRecord], deleting: [CKRecord.ID], scope: PrivateAccountScope) async throws
        -> [CKRecord.ID: CKRecord]
    {
        try verify(scope)
        if holdNextProfileSave && saving.contains(where: { $0.recordID == scope.profileID }) {
            holdNextProfileSave = false
            await withCheckedContinuation { pendingSave = $0 }
        }
        try verify(scope)
        if let mutationFailure { throw mutationFailure }
        guard atomic else { throw PrivateDataFailure.atomicZoneRequired }
        guard saving.allSatisfy({ $0.recordID.zoneID == scope.zoneID }),
            deleting.allSatisfy({ $0.zoneID == scope.zoneID })
        else {
            throw PrivateDataFailure.invalidScope
        }
        // Validate ALL conditions before mutating ANY record, as the native atomic-zone contract requires.
        for record in saving {
            guard
                (record["testVersion"] as? NSNumber)
                    == (records[record.recordID]?["testVersion"] as? NSNumber)
            else {
                throw CKError(.serverRecordChanged)
            }
        }
        var result: [CKRecord.ID: CKRecord] = [:]
        for record in saving {
            guard let saved = record.copy() as? CKRecord else { throw PrivateDataFailure.malformedGuard }
            saved["testVersion"] =
                ((records[record.recordID]?["testVersion"] as? NSNumber)?.intValue ?? 0) + 1 as NSNumber
            records[record.recordID] = saved
            result[record.recordID] = saved.copy() as? CKRecord
        }
        for id in deleting { records.removeValue(forKey: id) }
        modifies += 1
        if loseNextMutationResponse {
            loseNextMutationResponse = false
            throw CKError(.networkFailure)
        }
        return result
    }
    func changes(scope: PrivateAccountScope, token: Data?) async throws -> PrivateZonePage {
        try verify(scope)
        scans += 1
        if let pageFailure { throw pageFailure }
        if let foreignPage {
            return .init(changedIDs: [foreignPage], token: Data("foreign".utf8), moreComing: false)
        }
        if incompleteEmptyPage { return .init(changedIDs: [], token: Data("more".utf8), moreComing: true) }
        let ids: [CKRecord.ID]
        if let token {
            guard let key = String(data: token, encoding: .utf8), let stored = pages[key] else {
                throw PrivateDataFailure.invalidCursor
            }
            ids = stored
        } else {
            ids = records.keys.filter { $0.zoneID == scope.zoneID }.sorted { $0.recordName < $1.recordName }
        }
        let window = Array(ids.prefix(100))
        let remaining = Array(ids.dropFirst(min(ids.count, 100)))
        let key = UUID().uuidString
        pages[key] = remaining
        return .init(
            changedIDs: window.filter { records[$0] != nil }, token: Data(key.utf8),
            moreComing: !remaining.isEmpty)
    }
    func resumeSave() {
        pendingSave?.resume()
        pendingSave = nil
    }
}
@MainActor private final class ZoneAuthorization {
    var writes = 0, erasures = 0
    var allowed = true
    func write(_ scope: PrivateAccountScope) throws {
        writes += 1
        if !allowed { throw GatewayFailure.signInRequired }
    }
    func erase(_ scope: PrivateAccountScope) throws {
        erasures += 1
        if !allowed { throw GatewayFailure.signInRequired }
    }
}
@MainActor private struct ZoneFixture {
    let owner = ZoneOwner()
    let authorization = ZoneAuthorization()
    let account: CloudKitAccountSession
    let model: ZoneModel
    let database: NativePrivateProfileDatabase
    let scope: PrivateAccountScope
    init() throws {
        account = .init(source: owner)
        model = .init(owner: owner)
        database = .init(
            account: account, transport: model,
            authorizeWrite: { [authorization] in try authorization.write($0) })
        scope = try Self.scope()
    }
    static func scope(
        owner: String = "owner-A", accountID: String = privateAccountID, production: Bool = false
    ) throws -> PrivateAccountScope {
        try .init(
            configuration: .init(
                containerIdentifier: "iCloud.example.private",
                environment: production ? .production : .development),
            accountID: accountID, cloudKitRecordName: owner)
    }
    func activate() async { await account.refresh() }
    func draft(_ name: String = "Prywatna nazwa") throws -> CKRecord {
        try PrivateProfileRecordCodec.encode(.init(displayName: name), updating: nil, scope: scope)
    }
    func save() async throws -> CKRecord { try await database.saveProfile(draft(), scope: scope) }
    func erase(cursor: PrivateCleanupCursor? = nil, deletionID: String = privateDeletionID) async throws
        -> PrivateCleanupStep
    {
        try await database.eraseAccountContentStep(
            scope: scope, deletionID: deletionID, cursor: cursor,
            authorizeDeletion: { try authorization.erase($0) })
    }
}

@Test @MainActor func privateNamespaceSeparatesCloudAccountsAppAccountsContainersAndEnvironments() throws {
    let a = try ZoneFixture.scope()
    let variants = [
        try ZoneFixture.scope(owner: "owner-B"),
        try ZoneFixture.scope(accountID: "50000000-0000-4000-8000-000000000002"),
        try ZoneFixture.scope(production: true),
        try PrivateAccountScope(
            configuration: .init(containerIdentifier: "iCloud.example.other", environment: .development),
            accountID: privateAccountID, cloudKitRecordName: "owner-A"),
    ]
    #expect(a.zoneID.zoneName.utf8.count < 255)
    #expect(variants.allSatisfy { $0.zoneID != a.zoneID && $0.profileID != a.profileID })
    #expect(!a.zoneID.zoneName.contains("owner-A"))
    #expect(throws: GatewayFailure.self) { try ZoneFixture.scope(accountID: "arbitrary-owner") }
}

@Test @MainActor func profileAndGuardAreSavedTogetherAfterFreshWriteAuthorization() async throws {
    let f = try ZoneFixture()
    await f.activate()
    #expect(try await f.database.fetchProfile(scope: f.scope) == nil)
    let profile = try await f.save()
    #expect(profile.recordID == f.scope.profileID)
    #expect(f.authorization.writes == 2)
    #expect(f.model.modifies == 1)
    let marker = try #require(f.model.records[f.scope.guardID])
    #expect(try !PrivateScopeGuard.isDeleted(marker, scope: f.scope))
    #expect(try await f.database.fetchProfile(scope: f.scope) != nil)
}

@Test @MainActor func deniedWriteOrNonAtomicZoneNeverCreatesProfileData() async throws {
    for denyAuthorization in [true, false] {
        let f = try ZoneFixture()
        await f.activate()
        if denyAuthorization { f.authorization.allowed = false } else { f.model.atomic = false }
        await #expect(throws: (any Error).self) { try await f.save() }
        #expect(f.model.records.isEmpty)
        #expect(f.model.modifies == 0)
    }
}

@Test @MainActor func wrongRecordScopeAndMissingOrMalformedGuardCannotBeSilentlyOverwritten() async throws {
    let f = try ZoneFixture()
    await f.activate()
    let foreign = try PrivateProfileRecordCodec.encode(
        .init(displayName: "Inne konto"), updating: nil, scope: ZoneFixture.scope(owner: "owner-B"))
    await #expect(throws: PrivateProfileFailure.malformedRecord) {
        try await f.database.saveProfile(foreign, scope: f.scope)
    }
    f.model.records[f.scope.profileID] = try f.draft()
    await #expect(throws: PrivateDataFailure.malformedGuard) {
        try await f.database.fetchProfile(scope: f.scope)
    }
    await #expect(throws: PrivateDataFailure.malformedGuard) { try await f.save() }
    f.model.records[f.scope.guardID] = CKRecord(
        recordType: PrivateScopeGuard.recordType, recordID: f.scope.guardID)
    await #expect(throws: PrivateDataFailure.malformedGuard) { try await f.save() }
    #expect(f.model.modifies == 0)
}

@Test @MainActor func accountSwitchDetectedAtTheTransportBoundaryCannotWriteToTheNewOwner() async throws {
    let f = try ZoneFixture()
    await f.activate()
    f.owner.name = "owner-B"  // Deliberately delay the account notification/session refresh.
    await #expect(throws: PrivateDataFailure.invalidScope) { try await f.save() }
    #expect(f.model.records.isEmpty)
}

@Test @MainActor func erasureRemovesMoreThanTwoPagesOfUnknownFutureRecordsButPreservesOtherScopes()
    async throws
{
    let f = try ZoneFixture()
    await f.activate()
    _ = try await f.save()
    for index in 0..<205 {
        let id = CKRecord.ID(recordName: "future-\(index)", zoneID: f.scope.zoneID)
        f.model.records[id] = CKRecord(recordType: "FuturePrivateType", recordID: id)
    }
    let other = try ZoneFixture.scope(accountID: "50000000-0000-4000-8000-000000000002")
    f.model.records[other.profileID] = try PrivateProfileRecordCodec.encode(
        .init(displayName: "Zachowaj"), updating: nil, scope: other)
    var cursor: PrivateCleanupCursor?
    var deleted = 0
    var completed = false
    for _ in 0..<10 {
        let step = try await f.erase(cursor: cursor)
        #expect(step.deletedRecords <= 100)
        deleted += step.deletedRecords
        cursor = step.cursor
        if step.contentDeleted {
            completed = true
            break
        }
    }
    #expect(completed && deleted == 206)
    #expect(f.model.records[other.profileID] != nil)
    #expect(f.model.records.keys.filter { $0.zoneID == f.scope.zoneID } == [f.scope.guardID])
    #expect(try PrivateScopeGuard.isDeleted(#require(f.model.records[f.scope.guardID]), scope: f.scope))
    await #expect(throws: PrivateDataFailure.accountDeleted) { try await f.save() }
    await #expect(throws: PrivateDataFailure.accountDeleted) {
        try await f.database.fetchProfile(scope: f.scope)
    }
}

@Test @MainActor func anInFlightWriteCannotResurrectDataAfterTheDeletionMarkerCommits() async throws {
    let f = try ZoneFixture()
    await f.activate()
    _ = try await f.save()
    let original = try #require(try await f.database.fetchProfile(scope: f.scope))
    let draft = try PrivateProfileRecordCodec.encode(
        .init(displayName: "Spóźniony zapis"), updating: original, scope: f.scope)
    f.model.holdNextProfileSave = true
    let write = Task { try await f.database.saveProfile(draft, scope: f.scope) }
    while f.model.pendingSave == nil { await Task.yield() }
    let first = try await f.erase()
    f.model.resumeSave()
    await #expect(throws: CKError.self) { try await write.value }
    let final = try await f.erase(cursor: first.cursor)
    #expect(final.contentDeleted)
    #expect(f.model.records[f.scope.profileID] == nil)
}

@Test @MainActor func cleanupRequiresSeparateAuthorizationAndKeepsLegacyDataPending() async throws {
    let f = try ZoneFixture()
    await f.activate()
    _ = try await f.save()
    f.authorization.allowed = false
    await #expect(throws: GatewayFailure.signInRequired) { try await f.erase() }
    f.authorization.allowed = true
    let legacy = CKRecord(
        recordType: PrivateProfileRecordCodec.recordType,
        recordID: NativePrivateProfileDatabase.legacyProfileID)
    legacy["displayName"] = "Starsze prywatne dane" as NSString
    f.model.records[legacy.recordID] = legacy
    let mutations = f.model.modifies
    await #expect(throws: PrivateDataFailure.legacyDataRequiresMigration) { try await f.erase() }
    #expect(f.model.modifies == mutations)
    #expect(f.model.records[legacy.recordID] != nil && f.model.records[f.scope.profileID] != nil)
}

@Test @MainActor func aForeignOrUnboundCursorCannotSkipTheInitialDeletionBarrier() async throws {
    let f = try ZoneFixture()
    await f.activate()
    _ = try await f.save()
    let other = try ZoneFixture.scope(owner: "owner-B")
    let foreign = try PrivateCleanupCursor(
        scope: other, deletionID: privateDeletionID, opaqueToken: Data("foreign".utf8))
    await #expect(throws: PrivateDataFailure.invalidCursor) { try await f.erase(cursor: foreign) }
    let unbound = try PrivateCleanupCursor(
        scope: f.scope, deletionID: privateDeletionID, opaqueToken: Data("not-yet-started".utf8))
    await #expect(throws: PrivateDataFailure.invalidCursor) { try await f.erase(cursor: unbound) }
    #expect(f.model.records[f.scope.profileID] != nil)
}

@Test @MainActor func cleanupCannotAcceptForeignRecordIDsOrAnEmptyIncompletePage() async throws {
    let f = try ZoneFixture()
    await f.activate()
    _ = try await f.save()
    f.model.foreignPage = try ZoneFixture.scope(owner: "owner-B").profileID
    await #expect(throws: PrivateDataFailure.invalidScope) { try await f.erase() }
    #expect(f.model.records[f.scope.profileID] != nil)
    f.model.foreignPage = nil
    f.model.incompleteEmptyPage = true
    let result = try await f.erase()
    #expect(!result.contentDeleted && result.cursor != nil)
}

@Test @MainActor func cleanupResumesAfterLostAcknowledgementAndCursorRoundTripWithoutReopeningWrites()
    async throws
{
    let f = try ZoneFixture()
    await f.activate()
    _ = try await f.save()
    f.model.loseNextMutationResponse = true
    await #expect(throws: CKError.self) { try await f.erase() }
    await #expect(throws: PrivateDataFailure.accountDeleted) { try await f.save() }
    let first = try await f.erase()
    let cursor = try #require(first.cursor)
    let restored = try JSONDecoder().decode(PrivateCleanupCursor.self, from: JSONEncoder().encode(cursor))
    #expect(restored == cursor)
    #expect(!String(reflecting: cursor).contains(cursor.scopeDigest))
    #expect(try await f.erase(cursor: restored).contentDeleted)
}

@Test @MainActor func aDifferentDeletionIDCannotReuseOrReplaceAnEstablishedBarrier() async throws {
    let f = try ZoneFixture()
    await f.activate()
    _ = try await f.save()
    let first = try await f.erase()
    let other = UUID().uuidString.lowercased()
    await #expect(throws: PrivateDataFailure.invalidCursor) {
        try await f.erase(cursor: first.cursor, deletionID: other)
    }
    await #expect(throws: PrivateDataFailure.invalidScope) { try await f.erase(deletionID: other) }
    #expect(f.model.records[f.scope.guardID]?["deletionID"] as? String == privateDeletionID)
}

@Test @MainActor func profileOnlyDeletionDoesNotDeleteTheAccountScopeOrOtherPrivateRecords() async throws {
    let f = try ZoneFixture()
    await f.activate()
    _ = try await f.save()
    let otherID = CKRecord.ID(recordName: "settings", zoneID: f.scope.zoneID)
    f.model.records[otherID] = CKRecord(recordType: "PrivateSettings", recordID: otherID)
    try await f.database.deleteProfile(scope: f.scope)
    #expect(f.model.records[f.scope.profileID] == nil && f.model.records[otherID] != nil)
    _ = try await f.save()  // Profile-only deletion is not an account-deletion tombstone.
}

@Test @MainActor func providerPageErrorsNeverBecomePrivateCleanupCompletion() async throws {
    let f = try ZoneFixture()
    await f.activate()
    _ = try await f.save()
    f.model.pageFailure = CKError(.networkUnavailable)
    await #expect(throws: CKError.self) { try await f.erase() }
    #expect(f.model.records[f.scope.profileID] != nil)
}
