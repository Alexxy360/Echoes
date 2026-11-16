import CloudKit
import Foundation
import Testing

@testable import EchoesCloudKit

@MainActor private final class ProfileAccount: CloudKitAccountSource {
    var name = "A"
    func availability() async throws -> CloudKitAccountAvailability { .available }
    func userRecordName() async throws -> String { name }
}

@MainActor private final class ProfileDatabase: PrivateProfileDatabase {
    var stored: CKRecord?
    var fetchError: (any Error)?
    var saveError: (any Error)?
    var deleteError: (any Error)?
    var saveCount = 0
    var fetchCount = 0
    var suspendFetch = false
    var pendingFetch: CheckedContinuation<CKRecord?, Never>?
    var loseSave = false
    var suspendDelete = false
    var pendingDelete: CheckedContinuation<Void, Never>?
    var suspendSave = false
    var pendingSave: CheckedContinuation<CKRecord, Never>?
    func fetchProfile(scope: PrivateAccountScope) async throws -> CKRecord? {
        fetchCount += 1
        if let fetchError { throw fetchError }
        if suspendFetch { return await withCheckedContinuation { pendingFetch = $0 } }
        return stored
    }
    func saveProfile(_ record: CKRecord, scope: PrivateAccountScope) async throws -> CKRecord {
        saveCount += 1
        if let saveError { throw saveError }
        if suspendSave { return await withCheckedContinuation { pendingSave = $0 } }
        stored = record
        if loseSave {
            loseSave = false
            throw CKError(.networkFailure)
        }
        return record
    }
    func deleteProfile(scope: PrivateAccountScope) async throws {
        if let deleteError { throw deleteError }
        stored = nil
        if suspendDelete { await withCheckedContinuation { pendingDelete = $0 } }
    }
}

@MainActor private func profileScope(
    _ name: String, accountID: String = "40000000-0000-4000-8000-000000000001"
) throws -> PrivateAccountScope {
    try .init(
        configuration: CloudKitConfiguration(
            containerIdentifier: "iCloud.example.test", environment: .development),
        accountID: accountID, cloudKitRecordName: name)
}
@MainActor private func makeStore(account: CloudKitAccountSession, database: ProfileDatabase)
    -> PrivateProfileStore
{
    .init(
        account: account,
        scope: {
            guard let name = account.userRecordName else { return nil }
            return try? profileScope(name)
        }, database: database, authorizeRead: { _ in })
}

@MainActor private func record(_ name: String) throws -> CKRecord {
    try PrivateProfileRecordCodec.encode(
        .init(displayName: name), updating: nil, scope: try profileScope("A"))
}

@Test @MainActor func newProfileRequiresLoadAndExplicitSave() async throws {
    let source = ProfileAccount()
    let database = ProfileDatabase()
    let account = CloudKitAccountSession(source: source)
    await account.refresh()
    let store = makeStore(account: account, database: database)
    #expect(await store.save(displayName: "Anna") == false)
    #expect(database.saveCount == 0)
    await store.load()
    #expect(store.didLoad && store.profile == nil)
    #expect(await store.save(displayName: "  Anna  "))
    #expect(store.profile?.displayName == "Anna")
    #expect(database.stored?.allKeys().sorted() == ["displayName", "schemaVersion"])
}

@Test @MainActor func conflictKeepsOriginalSnapshotAndDoesNotRetryWrite() async throws {
    let database = ProfileDatabase()
    database.stored = try record("Anna")
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let store = makeStore(account: account, database: database)
    await store.load()
    database.saveError = CKError(.serverRecordChanged)
    #expect(await store.save(displayName: "Nowa nazwa") == false)
    #expect(store.profile?.displayName == "Anna")
    #expect(database.stored?["displayName"] as? String == "Anna")
    #expect(database.saveCount == 1)
    #expect(store.errorMessage == CloudKitFailure.conflict.localizedDescription)
}

@Test @MainActor func invalidAndNewerRecordsCannotBeOverwritten() async throws {
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let database = ProfileDatabase()
    database.stored = try record("Anna")
    database.stored?["schemaVersion"] = 2 as NSNumber
    let store = makeStore(account: account, database: database)
    await store.load()
    #expect(!store.didLoad && store.profile == nil)
    #expect(await store.save(displayName: "Nadpisanie") == false)
    #expect(database.saveCount == 0)
    #expect(store.errorMessage == PrivateProfileFailure.unsupportedSchema.localizedDescription)
}

@Test @MainActor func offlineLoadDoesNotBecomeAnEmptyProfileToOverwrite() async {
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let database = ProfileDatabase()
    database.fetchError = CKError(.networkUnavailable)
    let store = makeStore(account: account, database: database)
    await store.load()
    #expect(!store.didLoad)
    #expect(await store.save(displayName: "Anna") == false)
    #expect(database.saveCount == 0)
}

@Test @MainActor func unknownFieldsSurviveProfileEdits() async throws {
    let database = ProfileDatabase()
    database.stored = try record("Anna")
    database.stored?["futureField"] = "preserve" as NSString
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let store = makeStore(account: account, database: database)
    await store.load()
    #expect(await store.save(displayName: "Nowa nazwa"))
    #expect(database.stored?["futureField"] as? String == "preserve")
}

@Test @MainActor func previousProfileCannotLeakThroughSaveOrDeleteFailureOnNewAccount() async throws {
    let source = ProfileAccount()
    let database = ProfileDatabase()
    database.stored = try record("Prywatna Anna")
    let account = CloudKitAccountSession(source: source)
    await account.refresh()
    let store = makeStore(account: account, database: database)
    await store.load()
    source.name = "B"
    await account.refresh()
    #expect(store.profile == nil)
    #expect(await store.save(displayName: "Bartek") == false)
    #expect(store.profile == nil)
    database.deleteError = CKError(.networkUnavailable)
    #expect(await store.delete() == false)
    #expect(store.profile == nil)
}

@Test @MainActor func lateProfileReadCannotEnterAnotherAccount() async throws {
    let source = ProfileAccount()
    let database = ProfileDatabase()
    let account = CloudKitAccountSession(source: source)
    await account.refresh()
    let store = makeStore(account: account, database: database)
    database.suspendFetch = true
    let request = Task { await store.load() }
    while database.pendingFetch == nil { await Task.yield() }
    source.name = "B"
    await account.refresh()
    database.pendingFetch?.resume(returning: try record("Prywatna Anna"))
    await request.value
    #expect(store.profile == nil && !store.didLoad)
}

@Test @MainActor func lateProfileWriteCannotEnterAnotherAccount() async throws {
    let source = ProfileAccount()
    let database = ProfileDatabase()
    let account = CloudKitAccountSession(source: source)
    await account.refresh()
    let store = makeStore(account: account, database: database)
    await store.load()
    database.suspendSave = true
    let request = Task { await store.save(displayName: "Anna") }
    while database.pendingSave == nil { await Task.yield() }
    source.name = "B"
    await account.refresh()
    database.pendingSave?.resume(returning: try record("Anna"))
    #expect(await request.value == false)
    #expect(store.profile == nil)
}

@Test @MainActor func deletingOwnProfileDoesNotDeleteAppleIdentity() async throws {
    let database = ProfileDatabase()
    database.stored = try record("Anna")
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let store = makeStore(account: account, database: database)
    await store.load()
    #expect(await store.delete())
    #expect(database.stored == nil && store.profile == nil && store.didLoad)
    #expect(account.userRecordName == "A" && account.state == .ready)
}

@MainActor private final class ProfileScopeSelection {
    var accountID = "40000000-0000-4000-8000-000000000001"
}

@Test @MainActor func switchingEchoesAccountWithinTheSameICloudHidesThePreviousProfileImmediately()
    async throws
{
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let database = ProfileDatabase()
    database.stored = try record("Konto pierwsze")
    let selection = ProfileScopeSelection()
    let store = PrivateProfileStore(
        account: account,
        scope: {
            guard let name = account.userRecordName else { return nil }
            return try? profileScope(name, accountID: selection.accountID)
        }, database: database, authorizeRead: { _ in })
    await store.load()
    #expect(store.profile?.displayName == "Konto pierwsze")
    let revision = account.identityRevision
    selection.accountID = "40000000-0000-4000-8000-000000000002"
    #expect(store.profile == nil && !store.didLoad)
    #expect(await store.save(displayName: "Konto drugie") == false)
    database.stored = nil
    await store.load()
    #expect(await store.save(displayName: "Konto drugie"))
    #expect(database.stored?.recordID == (try profileScope("A", accountID: selection.accountID)).profileID)
    #expect(account.identityRevision == revision)
}

@Test @MainActor func detectedTransportOwnerMismatchClearsPrivateCacheAndInvalidatesTheAccountSnapshot()
    async throws
{
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let database = ProfileDatabase()
    database.stored = try record("Prywatne dane")
    let store = makeStore(account: account, database: database)
    await store.load()
    database.saveError = PrivateDataFailure.invalidScope
    #expect(await store.save(displayName: "Zapis") == false)
    #expect(store.profile == nil && !store.didLoad)
    #expect(account.state == .idle && account.userRecordName == nil)
}

@MainActor private final class ProfileReadAuthorization {
    var hold = false
    var failure: GatewayFailure?
    var waiting: CheckedContinuation<Void, Never>?
    var calls = 0
    func authorize(_ scope: PrivateAccountScope) async throws {
        calls += 1
        if let failure { throw failure }
        if hold {
            hold = false
            await withCheckedContinuation { waiting = $0 }
        }
    }
}
@MainActor private func awaitProfileCondition(_ condition: () -> Bool) async throws {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
    throw CloudKitFailure.unavailable
}
@Test @MainActor func privateProfileReadRequiresFreshAuthorizationBeforeProvider() async throws {
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let database = ProfileDatabase()
    let access = ProfileReadAuthorization()
    access.failure = .signInRequired
    let store = PrivateProfileStore(
        account: account, scope: { try? profileScope("A") },
        database: database, authorizeRead: access.authorize)
    await store.load()
    #expect(!store.didLoad && store.profile == nil && !store.isBusy)
    #expect(database.fetchCount == 0 && access.calls == 1)
    #expect(store.errorMessage == GatewayFailure.signInRequired.localizedDescription)
}
@Test @MainActor func clearDuringPrivateReadAuthorizationPreventsLateProviderDispatch() async throws {
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let database = ProfileDatabase()
    let access = ProfileReadAuthorization()
    access.hold = true
    let store = PrivateProfileStore(
        account: account, scope: { try? profileScope("A") },
        database: database, authorizeRead: access.authorize)
    let old = Task { await store.load() }
    try await awaitProfileCondition { access.waiting != nil }
    store.clearCache()
    database.stored = try record("New read")
    await store.load()
    access.waiting?.resume()
    await old.value
    #expect(database.fetchCount == 1 && store.profile?.displayName == "New read")
    #expect(store.didLoad && !store.isBusy && store.errorMessage == nil)
}
@Test @MainActor func clearCacheFencesSameScopeReadAndItsDeferDuringAnotherRead() async throws {
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let database = ProfileDatabase()
    let store = makeStore(account: account, database: database)
    database.suspendFetch = true
    let old = Task { await store.load() }
    try await awaitProfileCondition { database.pendingFetch != nil }
    let first = try #require(database.pendingFetch)
    database.pendingFetch = nil
    store.clearCache()
    let next = Task { await store.load() }
    try await awaitProfileCondition { database.pendingFetch != nil }
    let second = try #require(database.pendingFetch)
    first.resume(returning: try record("Stale read"))
    await old.value
    #expect(store.profile == nil && !store.didLoad && store.isBusy)
    second.resume(returning: try record("Current read"))
    await next.value
    #expect(store.profile?.displayName == "Current read" && store.didLoad && !store.isBusy)
}
@Test @MainActor func clearedSameScopeWriteCannotReplaceReloadedPrivateSnapshot() async throws {
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let database = ProfileDatabase()
    database.stored = try record("Before")
    let store = makeStore(account: account, database: database)
    await store.load()
    database.suspendSave = true
    let old = Task { await store.save(displayName: "Late write") }
    try await awaitProfileCondition { database.pendingSave != nil }
    store.clearCache()
    database.stored = try record("Reloaded")
    await store.load()
    database.pendingSave?.resume(returning: try record("Late write"))
    #expect(await old.value == false)
    #expect(store.profile?.displayName == "Reloaded" && store.didLoad && !store.isBusy)
    #expect(store.errorMessage == nil)
}
@Test @MainActor func lateSameScopeDeleteDoesNotClearReloadedProfile() async throws {
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let database = ProfileDatabase()
    database.stored = try record("Before")
    let store = makeStore(account: account, database: database)
    await store.load()
    database.suspendDelete = true
    let old = Task { await store.delete() }
    try await awaitProfileCondition { database.pendingDelete != nil }
    store.clearCache()
    database.stored = try record("Reloaded after delete")
    await store.load()
    database.pendingDelete?.resume()
    #expect(await old.value == false)
    #expect(store.profile?.displayName == "Reloaded after delete" && store.didLoad && !store.isBusy)
}
@Test @MainActor func unknownPrivateSaveRequiresReloadAndNeverAutomaticallyRetries() async throws {
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let database = ProfileDatabase()
    database.stored = try record("Before")
    let store = makeStore(account: account, database: database)
    await store.load()
    database.loseSave = true
    #expect(await store.save(displayName: "Possibly saved") == false)
    #expect(!store.didLoad && store.profile?.displayName == "Before" && database.saveCount == 1)
    #expect(await store.save(displayName: "Another edit") == false)
    #expect(database.saveCount == 1)
    await store.load()
    #expect(store.profile?.displayName == "Possibly saved" && store.didLoad)
    #expect(await store.save(displayName: "Explicit new edit"))
    #expect(database.saveCount == 2 && store.profile?.displayName == "Explicit new edit")
}
@Test @MainActor func invalidPrivateNameDoesNotConsumeLoadedSnapshotOrDispatch() async throws {
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let database = ProfileDatabase()
    let store = makeStore(account: account, database: database)
    await store.load()
    #expect(await store.save(displayName: "   ") == false)
    #expect(store.didLoad && database.saveCount == 0)
    #expect(await store.save(displayName: "Valid"))
}
@Test @MainActor func cancelledPrivateReadAuthorizationCannotFetchOrClaimAnEmptyProfile() async throws {
    let account = CloudKitAccountSession(source: ProfileAccount())
    await account.refresh()
    let database = ProfileDatabase()
    let access = ProfileReadAuthorization()
    access.hold = true
    let store = PrivateProfileStore(
        account: account, scope: { try? profileScope("A") },
        database: database, authorizeRead: access.authorize)
    let task = Task { await store.load() }
    try await awaitProfileCondition { access.waiting != nil }
    task.cancel()
    access.waiting?.resume()
    await task.value
    #expect(database.fetchCount == 0 && !store.didLoad && !store.isBusy)
}
