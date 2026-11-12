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
    var suspendFetch = false
    var pendingFetch: CheckedContinuation<CKRecord?, Never>?
    var suspendSave = false
    var pendingSave: CheckedContinuation<CKRecord, Never>?
    func fetchProfile() async throws -> CKRecord? {
        if let fetchError { throw fetchError }
        if suspendFetch { return await withCheckedContinuation { pendingFetch = $0 } }
        return stored
    }
    func saveProfile(_ record: CKRecord) async throws -> CKRecord {
        saveCount += 1
        if let saveError { throw saveError }
        if suspendSave { return await withCheckedContinuation { pendingSave = $0 } }
        stored = record
        return record
    }
    func deleteProfile() async throws {
        if let deleteError { throw deleteError }
        stored = nil
    }
}

@MainActor private func record(_ name: String) throws -> CKRecord {
    try PrivateProfileRecordCodec.encode(.init(displayName: name), updating: nil)
}

@Test @MainActor func newProfileRequiresLoadAndExplicitSave() async throws {
    let source = ProfileAccount()
    let database = ProfileDatabase()
    let account = CloudKitAccountSession(source: source)
    await account.refresh()
    let store = PrivateProfileStore(account: account, database: database)
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
    let store = PrivateProfileStore(account: account, database: database)
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
    let store = PrivateProfileStore(account: account, database: database)
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
    let store = PrivateProfileStore(account: account, database: database)
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
    let store = PrivateProfileStore(account: account, database: database)
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
    let store = PrivateProfileStore(account: account, database: database)
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
    let store = PrivateProfileStore(account: account, database: database)
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
    let store = PrivateProfileStore(account: account, database: database)
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
    let store = PrivateProfileStore(account: account, database: database)
    await store.load()
    #expect(await store.delete())
    #expect(database.stored == nil && store.profile == nil && store.didLoad)
    #expect(account.userRecordName == "A" && account.state == .ready)
}
