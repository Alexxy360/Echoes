#if DEBUG
    import CloudKit
    import EchoesCloudKit
    import Foundation
    import Observation

    /// Developer-only synthetic test. Never reads names, GPS, Music or existing profile contents.
    @MainActor @Observable
    final class CloudKitProbe {
        struct Report: Codable {
            var runIdentifier = UUID().uuidString
            var startedAt = Date()
            var environment = "Development"
            var container = "iCloud.mpvEcho.Echo"
            var accountAvailable = false
            var writeSucceeded = false
            var readBackSucceeded = false
            var creatorPresent = false
            var creatorMatchesResolvedIdentity = false
            var creatorUsesCurrentUserAlias = false
            var creatorVerified = false
            var cleanupSucceeded = false
            var error: String?
            var cleanupError: String?
            var cloudKitErrorCode: Int?
            var syntheticRecordName: String?
        }
        private(set) var running = false
        private(set) var report: Report?
        private(set) var reportFileError = false

        func run() async {
            guard !running else { return }
            running = true
            reportFileError = false
            defer { running = false }
            var result = Report()
            do {
                let configuration = try CloudKitConfiguration(
                    containerIdentifier: result.container, environment: .development)
                let account = CloudKitAccountSession(
                    source: NativeCloudKitAccountSource(configuration: configuration))
                account.startMonitoring()
                defer { account.stopMonitoring() }
                await account.refresh()
                guard account.state == .ready, let identity = account.userRecordName else {
                    throw account.failure ?? CloudKitFailure.unavailable
                }
                result.accountAvailable = true
                let revision = account.identityRevision
                let database = CKContainer(identifier: result.container).privateCloudDatabase
                let id = CKRecord.ID(recordName: "echoes-probe-" + UUID().uuidString)
                let nonce = UUID().uuidString
                let record = CKRecord(recordType: "EchoesAccessProbeV1", recordID: id)
                record["nonce"] = nonce as NSString
                record["schemaVersion"] = 1 as NSNumber
                result.syntheticRecordName = id.recordName
                do {
                    let saved = try await database.modifyRecords(
                        saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged,
                        atomically: false)
                    guard let response = saved.saveResults[id] else { throw CloudKitFailure.partialFailure }
                    _ = try response.get()
                    result.writeSucceeded = true
                    let fetched = try await database.record(for: id)
                    result.readBackSucceeded = fetched["nonce"] as? String == nonce
                    result.creatorPresent = fetched.creatorUserRecordID != nil
                    result.creatorMatchesResolvedIdentity =
                        fetched.creatorUserRecordID?.recordName == identity
                    // Apple's current-user alias is meaningful within this private database only.
                    result.creatorUsesCurrentUserAlias =
                        fetched.creatorUserRecordID?.recordName == CKCurrentUserDefaultName
                    result.creatorVerified =
                        result.creatorMatchesResolvedIdentity || result.creatorUsesCurrentUserAlias
                } catch {
                    result.error = CloudKitFailure.classify(error).localizedDescription
                    result.cloudKitErrorCode = (error as? CKError)?.code.rawValue
                }
                // Try cleanup even when the write response/read failed. Never touch any other record.
                do {
                    guard account.identityRevision == revision, account.userRecordName == identity else {
                        result.creatorVerified = false
                        throw CloudKitFailure.notAuthenticated
                    }
                    do { _ = try await database.deleteRecord(withID: id) } catch let error as CKError
                        where error.code == .unknownItem
                    { /* Already absent. */  }
                    result.cleanupSucceeded = true
                } catch {
                    result.cleanupError = CloudKitFailure.classify(error).localizedDescription
                }
            } catch {
                result.error = CloudKitFailure.classify(error).localizedDescription
                result.cloudKitErrorCode = (error as? CKError)?.code.rawValue
            }
            report = result
            do {
                let directory = try FileManager.default.url(
                    for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(result).write(
                    to: directory.appendingPathComponent("cloudkit-probe-result.json"), options: .atomic)
            } catch { reportFileError = true }
        }
    }
#endif
