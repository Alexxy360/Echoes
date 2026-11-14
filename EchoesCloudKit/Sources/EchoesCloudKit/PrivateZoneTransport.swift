import CloudKit
import Foundation

public struct PrivateZonePage: Sendable {
    public let changedIDs: [CKRecord.ID]
    public let token: Data
    public let moreComing: Bool
    public init(changedIDs: [CKRecord.ID], token: Data, moreComing: Bool) {
        self.changedIDs = changedIDs
        self.token = token
        self.moreComing = moreComing
    }
}

/// Trusted adapter dependency. Native implementations must verify the owner and use private DB only.
@MainActor public protocol PrivateZoneTransport {
    func ensureAtomicZone(scope: PrivateAccountScope) async throws
    func fetch(_ id: CKRecord.ID, scope: PrivateAccountScope, metadataOnly: Bool) async throws -> CKRecord?
    /// All-or-nothing in ONE atomic zone, with ifServerRecordUnchanged for every saved record.
    func modify(saving: [CKRecord], deleting: [CKRecord.ID], scope: PrivateAccountScope) async throws
        -> [CKRecord.ID: CKRecord]
    func changes(scope: PrivateAccountScope, token: Data?) async throws -> PrivateZonePage
}

/// Only initialize in a correctly provisioned host. No public/shared database fallback.
@MainActor public final class NativePrivateZoneTransport: PrivateZoneTransport {
    private let configuration: CloudKitConfiguration
    private let container: CKContainer
    private let database: CKDatabase
    public init(configuration: CloudKitConfiguration) {
        self.configuration = configuration
        container = CKContainer(identifier: configuration.containerIdentifier)
        database = container.privateCloudDatabase
    }
    private func verify(_ scope: PrivateAccountScope) async throws {
        guard scope.configuration == configuration, !Task.isCancelled else {
            throw PrivateDataFailure.invalidScope
        }
        guard try await container.accountStatus() == .available else {
            throw CloudKitFailure.notAuthenticated
        }
        let current = try await container.userRecordID().recordName
        guard scope.matchesCloudKitRecordName(current), !Task.isCancelled else {
            throw PrivateDataFailure.invalidScope
        }
    }
    private func requireAtomic(_ scope: PrivateAccountScope) async throws {
        let zones = try await database.recordZones(for: [scope.zoneID])
        guard let result = zones[scope.zoneID] else { throw CloudKitFailure.partialFailure }
        let zone = try result.get()
        guard zone.zoneID == scope.zoneID, zone.capabilities.contains(.atomic) else {
            throw PrivateDataFailure.atomicZoneRequired
        }
    }
    public func ensureAtomicZone(scope: PrivateAccountScope) async throws {
        try await verify(scope)
        let zone = try await database.save(CKRecordZone(zoneID: scope.zoneID))
        try await verify(scope)
        guard zone.zoneID == scope.zoneID, zone.capabilities.contains(.atomic) else {
            throw PrivateDataFailure.atomicZoneRequired
        }
    }
    public func fetch(_ id: CKRecord.ID, scope: PrivateAccountScope, metadataOnly: Bool) async throws
        -> CKRecord?
    {
        guard
            id.zoneID == scope.zoneID || (metadataOnly && id == NativePrivateProfileDatabase.legacyProfileID)
        else {
            throw PrivateDataFailure.invalidScope
        }
        try await verify(scope)
        let results = try await database.records(for: [id], desiredKeys: metadataOnly ? [] : nil)
        try await verify(scope)
        guard let result = results[id] else { throw CloudKitFailure.partialFailure }
        do { return try result.get() } catch let error as CKError
            where error.code == .unknownItem || error.code == .zoneNotFound
        { return nil }
    }
    public func modify(saving: [CKRecord], deleting: [CKRecord.ID], scope: PrivateAccountScope) async throws
        -> [CKRecord.ID: CKRecord]
    {
        guard saving.count <= 2, deleting.count <= 100,
            saving.allSatisfy({ $0.recordID.zoneID == scope.zoneID }),
            deleting.allSatisfy({ $0.zoneID == scope.zoneID })
        else { throw PrivateDataFailure.invalidScope }
        try await verify(scope)
        try await requireAtomic(scope)
        try await verify(scope)
        let results = try await database.modifyRecords(
            saving: saving, deleting: deleting,
            savePolicy: .ifServerRecordUnchanged, atomically: true)
        try await verify(scope)
        guard Set(results.saveResults.keys) == Set(saving.map(\.recordID)),
            Set(results.deleteResults.keys) == Set(deleting)
        else {
            throw CloudKitFailure.partialFailure
        }
        var saved: [CKRecord.ID: CKRecord] = [:]
        for (id, result) in results.saveResults { saved[id] = try result.get() }
        for result in results.deleteResults.values { try result.get() }
        return saved
    }
    public func changes(scope: PrivateAccountScope, token: Data?) async throws -> PrivateZonePage {
        let previous: CKServerChangeToken?
        if let token {
            guard token.count <= 16_384,
                let decoded = try? NSKeyedUnarchiver.unarchivedObject(
                    ofClass: CKServerChangeToken.self, from: token)
            else { throw PrivateDataFailure.invalidCursor }
            previous = decoded
        } else {
            previous = nil
        }
        try await verify(scope)
        let page = try await database.recordZoneChanges(
            inZoneWith: scope.zoneID, since: previous, desiredKeys: [], resultsLimit: 100)
        try await verify(scope)
        guard page.modificationResultsByID.count + page.deletions.count <= 100 else {
            throw CloudKitFailure.partialFailure
        }
        for (id, result) in page.modificationResultsByID {
            let modification = try result.get()
            guard id.zoneID == scope.zoneID, modification.record.recordID == id else {
                throw PrivateDataFailure.invalidScope
            }
        }
        guard page.deletions.allSatisfy({ $0.recordID.zoneID == scope.zoneID }) else {
            throw PrivateDataFailure.invalidScope
        }
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: page.changeToken, requiringSecureCoding: true)
        guard !data.isEmpty, data.count <= 16_384 else { throw PrivateDataFailure.invalidCursor }
        return .init(
            changedIDs: Array(page.modificationResultsByID.keys), token: data, moreComing: page.moreComing)
    }
}
