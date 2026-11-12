import CloudKit
import EchoesCore
import Foundation
import Observation

public struct PrivateProfile: Equatable, Sendable {
    public let displayName: String
    public init(displayName: String) throws {
        self.displayName = try InputValidation.name(displayName)
    }
}

public enum PrivateProfileFailure: Error, Equatable, LocalizedError {
    case unsupportedSchema, malformedRecord, loadRequired
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "Ten profil wymaga nowszej wersji aplikacji."
        case .malformedRecord: "Nie udało się odczytać profilu."
        case .loadRequired: "Wczytaj profil przed zapisaniem zmian."
        }
    }
}

@MainActor
public enum PrivateProfileRecordCodec {
    public static let recordType = "EchoesPrivateProfileV1"
    public static var recordID: CKRecord.ID { .init(recordName: "private-profile.v1") }

    public static func decode(_ record: CKRecord) throws -> PrivateProfile {
        guard record.recordType == recordType, record.recordID == recordID else {
            throw PrivateProfileFailure.malformedRecord
        }
        guard let version = record["schemaVersion"] as? NSNumber else {
            throw PrivateProfileFailure.malformedRecord
        }
        guard version.doubleValue == 1 else { throw PrivateProfileFailure.unsupportedSchema }
        guard let name = record["displayName"] as? String else {
            throw PrivateProfileFailure.malformedRecord
        }
        return try PrivateProfile(displayName: name)
    }

    /// Copies the fetched record to preserve change tags and unknown fields without mutating cache on failure.
    public static func encode(_ profile: PrivateProfile, updating record: CKRecord?) throws -> CKRecord {
        let result: CKRecord
        if let record {
            _ = try decode(record)
            guard let copy = record.copy() as? CKRecord else { throw PrivateProfileFailure.malformedRecord }
            result = copy
        } else {
            result = CKRecord(recordType: recordType, recordID: recordID)
        }
        result["schemaVersion"] = 1 as NSNumber
        result["displayName"] = profile.displayName as NSString
        return result
    }
}

@MainActor
public protocol PrivateProfileDatabase {
    func fetchProfile() async throws -> CKRecord?
    func saveProfile(_ record: CKRecord) async throws -> CKRecord
    func deleteProfile() async throws
}

/// The private database is fixed here; callers cannot redirect a private profile into the public database.
@MainActor
public final class NativePrivateProfileDatabase: PrivateProfileDatabase {
    private let database: CKDatabase

    /// Requires a verified container and signed host, just like NativeCloudKitAccountSource.
    public init(configuration: CloudKitConfiguration) {
        database = CKContainer(identifier: configuration.containerIdentifier).privateCloudDatabase
    }

    public func fetchProfile() async throws -> CKRecord? {
        do { return try await database.record(for: PrivateProfileRecordCodec.recordID) } catch let error
            as CKError where error.code == .unknownItem
        { return nil }
    }

    public func saveProfile(_ record: CKRecord) async throws -> CKRecord {
        _ = try PrivateProfileRecordCodec.decode(record)
        let result = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
        guard let saved = result.saveResults[record.recordID] else { throw CloudKitFailure.partialFailure }
        return try saved.get()
    }

    public func deleteProfile() async throws {
        do { _ = try await database.deleteRecord(withID: PrivateProfileRecordCodec.recordID) } catch let error
            as CKError where error.code == .unknownItem
        { return }
    }
}

@MainActor
@Observable
public final class PrivateProfileStore {
    private struct Scope: Equatable {
        let revision: UInt64
        let name: String
    }
    private let account: CloudKitAccountSession
    @ObservationIgnored private let database: any PrivateProfileDatabase
    private var cachedProfile: PrivateProfile?
    @ObservationIgnored private var cachedRecord: CKRecord?
    private var cachedError: String?
    private var loaded = false
    private var cacheScope: Scope?
    private var busyScope: Scope?

    public init(account: CloudKitAccountSession, database: any PrivateProfileDatabase) {
        self.account = account
        self.database = database
    }

    private var currentScope: Scope? {
        guard account.state == .ready, let name = account.userRecordName else { return nil }
        return .init(revision: account.identityRevision, name: name)
    }
    public var profile: PrivateProfile? { cacheScope == currentScope ? cachedProfile : nil }
    public var errorMessage: String? { cacheScope == currentScope ? cachedError : nil }
    public var didLoad: Bool { currentScope != nil && cacheScope == currentScope && loaded }
    public var isBusy: Bool { currentScope != nil && busyScope == currentScope }

    public func clearCache() {
        cacheScope = nil
        cachedRecord = nil
        cachedProfile = nil
        cachedError = nil
        loaded = false
    }

    public func load() async {
        guard !isBusy, let scope = currentScope else { return }
        clearCache()
        cacheScope = scope
        busyScope = scope
        defer { if busyScope == scope { busyScope = nil } }
        do {
            let record = try await database.fetchProfile()
            guard scope == currentScope, !Task.isCancelled else { return }
            cachedProfile = try record.map(PrivateProfileRecordCodec.decode)
            cachedRecord = record
            loaded = true
        } catch { recordFailure(error, scope: scope) }
    }

    @discardableResult
    public func save(displayName: String) async -> Bool {
        guard !isBusy, let scope = currentScope else { return false }
        prepareCache(for: scope)
        guard didLoad else {
            cachedError = cachedError ?? PrivateProfileFailure.loadRequired.localizedDescription
            return false
        }
        busyScope = scope
        cachedError = nil
        defer { if busyScope == scope { busyScope = nil } }
        do {
            let draft = try PrivateProfile(displayName: displayName)
            let record = try PrivateProfileRecordCodec.encode(draft, updating: cachedRecord)
            let saved = try await database.saveProfile(record)
            guard scope == currentScope, !Task.isCancelled else { return false }
            cachedProfile = try PrivateProfileRecordCodec.decode(saved)
            cachedRecord = saved
            return true
        } catch {
            recordFailure(error, scope: scope)
            return false
        }
    }

    @discardableResult
    public func delete() async -> Bool {
        guard !isBusy, let scope = currentScope else { return false }
        prepareCache(for: scope)
        busyScope = scope
        defer { if busyScope == scope { busyScope = nil } }
        do {
            try await database.deleteProfile()
            guard scope == currentScope, !Task.isCancelled else { return false }
            clearCache()
            cacheScope = scope
            loaded = true
            return true
        } catch {
            recordFailure(error, scope: scope)
            return false
        }
    }

    private func recordFailure(_ error: any Error, scope: Scope) {
        guard scope == currentScope, !Task.isCancelled else { return }
        prepareCache(for: scope)
        if let error = error as? PrivateProfileFailure {
            cachedError = error.localizedDescription
        } else if let error = error as? ValidationError {
            cachedError = error.localizedDescription
        } else {
            cachedError = CloudKitFailure.classify(error).localizedDescription
        }
    }

    private func prepareCache(for scope: Scope) {
        if cacheScope != scope {
            clearCache()
            cacheScope = scope
        }
    }
}
