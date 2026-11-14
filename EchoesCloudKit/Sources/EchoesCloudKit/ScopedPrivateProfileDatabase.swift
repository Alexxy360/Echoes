import CloudKit
import Foundation

@MainActor enum PrivateScopeGuard {
    static let recordType = "EchoesPrivateScopeV1"
    static func isDeleted(_ record: CKRecord, scope: PrivateAccountScope) throws -> Bool {
        guard record.recordType == recordType, record.recordID == scope.guardID,
            (record["schemaVersion"] as? NSNumber)?.doubleValue == 1,
            record["scopeDigest"] as? String == scope.digest,
            let deleted = record["deleted"] as? NSNumber, [0.0, 1.0].contains(deleted.doubleValue),
            let mutation = record["mutation"] as? String, gatewayUUID(mutation)
        else { throw PrivateDataFailure.malformedGuard }
        if deleted.boolValue {
            guard let deletionID = record["deletionID"] as? String, gatewayUUID(deletionID) else {
                throw PrivateDataFailure.malformedGuard
            }
        } else if record["deletionID"] != nil {
            throw PrivateDataFailure.malformedGuard
        }
        return deleted.boolValue
    }
    static func update(
        _ old: CKRecord?, scope: PrivateAccountScope, deleting: Bool, deletionID: String? = nil
    ) throws -> CKRecord {
        if deleting {
            guard let deletionID, gatewayUUID(deletionID) else { throw PrivateDataFailure.malformedGuard }
        }
        let result: CKRecord
        if let old {
            let deleted = try isDeleted(old, scope: scope)
            guard deleting || !deleted else { throw PrivateDataFailure.accountDeleted }
            if deleted, old["deletionID"] as? String != deletionID { throw PrivateDataFailure.invalidScope }
            guard let copy = old.copy() as? CKRecord else { throw PrivateDataFailure.malformedGuard }
            result = copy
        } else {
            result = CKRecord(recordType: recordType, recordID: scope.guardID)
        }
        result["schemaVersion"] = 1 as NSNumber
        result["scopeDigest"] = scope.digest as NSString
        result["deleted"] = (deleting ? 1 : 0) as NSNumber
        result["deletionID"] = deletionID as NSString?
        // Force a changed tag even when the logical state is unchanged. Old writers must conflict.
        result["mutation"] = UUID().uuidString.lowercased() as NSString
        return result
    }
}

/// Scoped private profile and account-content erasure. Caller supplies real gateway authorization;
/// there is no successful fallback for a missing provider or erasure authorization.
@MainActor public final class NativePrivateProfileDatabase: PrivateProfileDatabase {
    static var legacyProfileID: CKRecord.ID { .init(recordName: "private-profile.v1") }
    private let account: CloudKitAccountSession
    private let transport: any PrivateZoneTransport
    private let authorizeWrite: @MainActor (PrivateAccountScope) async throws -> Void
    public convenience init(
        configuration: CloudKitConfiguration, account: CloudKitAccountSession,
        authorizeWrite: @escaping @MainActor (PrivateAccountScope) async throws -> Void
    ) {
        self.init(
            account: account, transport: NativePrivateZoneTransport(configuration: configuration),
            authorizeWrite: authorizeWrite)
    }
    public init(
        account: CloudKitAccountSession, transport: any PrivateZoneTransport,
        authorizeWrite: @escaping @MainActor (PrivateAccountScope) async throws -> Void
    ) {
        self.account = account
        self.transport = transport
        self.authorizeWrite = authorizeWrite
    }

    private func capture(_ scope: PrivateAccountScope) throws -> UInt64 {
        guard account.state == .ready, let name = account.userRecordName,
            scope.matchesCloudKitRecordName(name), !Task.isCancelled
        else { throw PrivateDataFailure.invalidScope }
        return account.identityRevision
    }
    private func check(_ scope: PrivateAccountScope, revision: UInt64) throws {
        guard try capture(scope) == revision else { throw PrivateDataFailure.invalidScope }
    }
    private func guardRecord(_ scope: PrivateAccountScope, revision: UInt64) async throws -> CKRecord? {
        try check(scope, revision: revision)
        let record = try await transport.fetch(scope.guardID, scope: scope, metadataOnly: false)
        try check(scope, revision: revision)
        if let record { _ = try PrivateScopeGuard.isDeleted(record, scope: scope) }
        return record
    }
    public func fetchProfile(scope: PrivateAccountScope) async throws -> CKRecord? {
        let revision = try capture(scope)
        let guardValue = try await guardRecord(scope, revision: revision)
        if let guardValue, try PrivateScopeGuard.isDeleted(guardValue, scope: scope) {
            throw PrivateDataFailure.accountDeleted
        }
        let record = try await transport.fetch(scope.profileID, scope: scope, metadataOnly: false)
        try check(scope, revision: revision)
        if let record {
            guard guardValue != nil else { throw PrivateDataFailure.malformedGuard }
            _ = try PrivateProfileRecordCodec.decode(record, scope: scope)
        }
        return record
    }
    public func saveProfile(_ record: CKRecord, scope: PrivateAccountScope) async throws -> CKRecord {
        _ = try PrivateProfileRecordCodec.decode(record, scope: scope)
        let revision = try capture(scope)
        try await authorizeWrite(scope)
        try check(scope, revision: revision)
        try await transport.ensureAtomicZone(scope: scope)
        try check(scope, revision: revision)
        let guardValue = try await guardRecord(scope, revision: revision)
        let guardDraft = try PrivateScopeGuard.update(guardValue, scope: scope, deleting: false)
        if guardValue == nil {
            let existing = try await transport.fetch(scope.profileID, scope: scope, metadataOnly: true)
            try check(scope, revision: revision)
            guard existing == nil else { throw PrivateDataFailure.malformedGuard }
        }
        // Repeat just before dispatch; slow zone creation/reads cannot reuse a stale authorization.
        try await authorizeWrite(scope)
        try check(scope, revision: revision)
        let saved = try await transport.modify(saving: [guardDraft, record], deleting: [], scope: scope)
        try check(scope, revision: revision)
        guard let finalGuard = saved[scope.guardID], let profile = saved[scope.profileID],
            try !PrivateScopeGuard.isDeleted(finalGuard, scope: scope)
        else { throw CloudKitFailure.partialFailure }
        _ = try PrivateProfileRecordCodec.decode(profile, scope: scope)
        return profile
    }
    public func deleteProfile(scope: PrivateAccountScope) async throws {
        let revision = try capture(scope)
        try await authorizeWrite(scope)
        try check(scope, revision: revision)
        let guardValue = try await guardRecord(scope, revision: revision)
        let record = try await transport.fetch(scope.profileID, scope: scope, metadataOnly: true)
        try check(scope, revision: revision)
        guard record != nil else { return }
        guard guardValue != nil else { throw PrivateDataFailure.malformedGuard }
        let guardDraft = try PrivateScopeGuard.update(guardValue, scope: scope, deleting: false)
        try await authorizeWrite(scope)
        try check(scope, revision: revision)
        let saved = try await transport.modify(
            saving: [guardDraft], deleting: [scope.profileID], scope: scope)
        try check(scope, revision: revision)
        guard let finalGuard = saved[scope.guardID],
            try !PrivateScopeGuard.isDeleted(finalGuard, scope: scope)
        else {
            throw CloudKitFailure.partialFailure
        }
    }

    /// One bounded page, all record types/CKAssets in this account zone. Authorization must verify
    /// an accepted server deletion ticket for this account, not ordinary access or a client UUID.
    public func eraseAccountContentStep(
        scope: PrivateAccountScope, deletionID: String, cursor: PrivateCleanupCursor?,
        authorizeDeletion: @MainActor (PrivateAccountScope) async throws -> Void
    ) async throws -> PrivateCleanupStep {
        let revision = try capture(scope)
        guard gatewayUUID(deletionID) else { throw PrivateDataFailure.invalidScope }
        if let cursor {
            guard cursor.scopeDigest == scope.digest, cursor.deletionID == deletionID, !cursor.token.isEmpty,
                cursor.token.count <= 16_384
            else {
                throw PrivateDataFailure.invalidCursor
            }
        }
        try await authorizeDeletion(scope)
        try check(scope, revision: revision)
        // The unshipped legacy implementation used one fixed default-zone ID without an Echoes
        // account namespace. Detect it read-only; never guess which app account owns that record.
        let legacy = try await transport.fetch(Self.legacyProfileID, scope: scope, metadataOnly: true)
        try check(scope, revision: revision)
        guard legacy == nil else { throw PrivateDataFailure.legacyDataRequiresMigration }
        try await transport.ensureAtomicZone(scope: scope)
        try check(scope, revision: revision)
        var guardValue = try await guardRecord(scope, revision: revision)
        let alreadyDeleted = try guardValue.map { try PrivateScopeGuard.isDeleted($0, scope: scope) } ?? false
        if !alreadyDeleted {
            guard cursor == nil else { throw PrivateDataFailure.invalidCursor }
            let draft = try PrivateScopeGuard.update(
                guardValue, scope: scope, deleting: true, deletionID: deletionID)
            try await authorizeDeletion(scope)
            try check(scope, revision: revision)
            let saved = try await transport.modify(saving: [draft], deleting: [], scope: scope)
            try check(scope, revision: revision)
            guardValue = saved[scope.guardID]
        }
        guard let guardValue, try PrivateScopeGuard.isDeleted(guardValue, scope: scope) else {
            throw CloudKitFailure.partialFailure
        }
        guard guardValue["deletionID"] as? String == deletionID else { throw PrivateDataFailure.invalidScope }
        let page = try await transport.changes(scope: scope, token: cursor?.token)
        try check(scope, revision: revision)
        guard page.changedIDs.count <= 100, Set(page.changedIDs).count == page.changedIDs.count,
            page.changedIDs.allSatisfy({ $0.zoneID == scope.zoneID })
        else { throw PrivateDataFailure.invalidScope }
        let ids = page.changedIDs.filter { $0 != scope.guardID }
        if !ids.isEmpty {
            let draft = try PrivateScopeGuard.update(
                guardValue, scope: scope, deleting: true, deletionID: deletionID)
            try await authorizeDeletion(scope)
            try check(scope, revision: revision)
            let saved = try await transport.modify(saving: [draft], deleting: ids, scope: scope)
            try check(scope, revision: revision)
            guard let finalGuard = saved[scope.guardID],
                try PrivateScopeGuard.isDeleted(finalGuard, scope: scope)
            else {
                throw CloudKitFailure.partialFailure
            }
        }
        let completed = !page.moreComing && ids.isEmpty
        return .init(
            scope: scope,
            cursor: completed
                ? nil
                : try PrivateCleanupCursor(scope: scope, deletionID: deletionID, opaqueToken: page.token),
            contentDeleted: completed, deletedRecords: ids.count)
    }
}
