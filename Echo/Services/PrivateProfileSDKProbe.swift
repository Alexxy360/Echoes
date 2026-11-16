#if DEBUG
    import CloudKit
    import EchoesCloudKit
    import Foundation
    import Observation

    private enum SDKProbeFailure: Error {
        case inactive, replayed, namespaceCollision, unexpected, conflictNotObserved
    }

    @MainActor @Observable final class PrivateProfileSDKProbe {
        struct Report: Codable {
            let runID: String
            let startedAt: Date
            var accountAvailable = false
            var namespacesInitiallyAbsent = false
            var createdAndRestored = false
            var changeTagsPresent = false
            var staleWriteRejectedByServer = false
            var sameICloudNamespacesIsolated = false
            var deletionGuardEnforced = false
            var cleanedZoneCount = 0
            var cleanupVerified = false
            var codes: [Int] = []
            var failedStage: String?
            var error: String?
            var cleanupError: String?
        }
        private(set) var running = false
        private(set) var report: Report?
        private(set) var configurationFailed = false
        private(set) var reportWriteFailed = false
        private let plan: PrivateProfileProbePlan?
        private var attempted = false

        init() {
            do {
                guard
                    let url = Bundle.main.url(
                        forResource: "EchoesPrivateProfileProbe", withExtension: "json"),
                    (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 2049) <= 2048
                else { throw SDKProbeFailure.inactive }
                plan = try PrivateProfileProbePlan(
                    data: Data(contentsOf: url), bundleIdentifier: Bundle.main.bundleIdentifier)
            } catch {
                plan = nil
                configurationFailed = true
            }
        }
        var canRun: Bool { !attempted && !running && plan?.isActive() == true }
        private func directory() throws -> URL {
            let documents = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let root = documents.appendingPathComponent("PrivateProfileSDKProbe", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SDKProbeFailure.inactive
            }
            return root
        }
        private func claim(_ plan: PrivateProfileProbePlan) throws {
            try PrivateProfileProbeClaim(directory: directory()).claim(plan)
        }
        private func errorCodes(_ error: any Error, depth: Int = 0) -> [Int] {
            guard depth < 4, let value = error as? CKError else { return [] }
            var codes = [value.code.rawValue]
            if let nestedErrors = value.partialErrorsByItemID {
                for nested in nestedErrors.values.prefix(8) {
                    codes += errorCodes(nested, depth: depth + 1)
                }
            }
            return codes
        }
        func run() async {
            guard canRun, let plan else { return }
            attempted = true
            running = true
            defer { running = false }
            var result = Report(runID: plan.runID, startedAt: Date())
            var stage = "claim"
            do { try claim(plan) } catch {
                result.failedStage = stage
                result.error = "Test nie został uruchomiony: konfiguracja wygasła lub próba była już użyta."
                finish(result)
                return
            }
            // Construct the native source only after the signed, bounded configuration and durable claim.
            let source = NativeCloudKitAccountSource(configuration: plan.configuration)
            let account = CloudKitAccountSession(source: source)
            account.startMonitoring()
            defer { account.stopMonitoring() }
            await account.refresh()
            guard account.state == .ready, let owner = account.userRecordName else {
                result.failedStage = "account"
                result.error = account.failure?.localizedDescription ?? "Konto iCloud jest niedostępne."
                finish(result)
                return
            }
            result.accountAvailable = true
            let revision = account.identityRevision
            let cloud = CKContainer(identifier: plan.configuration.containerIdentifier).privateCloudDatabase
            let scopes: [PrivateAccountScope]
            do { scopes = try plan.scopes(cloudKitRecordName: owner) } catch {
                result.failedStage = "scope"
                finish(result)
                return
            }
            let check: @MainActor (PrivateAccountScope) async throws -> Void = { scope in
                guard plan.permits(scope, cloudKitRecordName: owner), account.state == .ready,
                    account.identityRevision == revision, account.userRecordName == owner,
                    try await source.availability() == .available,
                    try await source.userRecordName() == owner,
                    plan.permits(scope, cloudKitRecordName: owner), !Task.isCancelled
                else { throw SDKProbeFailure.inactive }
            }
            let native = NativePrivateProfileDatabase(
                configuration: plan.configuration, account: account, authorizeWrite: check)
            let trace = SDKProbeProfileDatabase(base: native)
            let scopeProvider: @MainActor (PrivateAccountScope) -> PrivateAccountScope? = { scope in
                plan.permits(scope, cloudKitRecordName: owner) && account.state == .ready
                    && account.identityRevision == revision && account.userRecordName == owner ? scope : nil
            }
            func store(_ scope: PrivateAccountScope) -> PrivateProfileStore {
                PrivateProfileStore(
                    account: account, scope: { scopeProvider(scope) }, database: trace, authorizeRead: check)
            }
            var mayClean = [false, false]
            do {
                stage = "absent-namespaces"
                for (index, scope) in scopes.enumerated() {
                    try await check(scope)
                    do {
                        _ = try await cloud.recordZone(for: scope.zoneID)
                        throw SDKProbeFailure.namespaceCollision
                    } catch let error as CKError
                        where error.code == .zoneNotFound || error.code == .unknownItem
                    {
                        mayClean[index] = true
                    }
                    try await check(scope)
                }
                result.namespacesInitiallyAbsent = true
                stage = "create-and-restore"
                let first = store(scopes[0])
                await first.load()
                guard first.didLoad, first.profile == nil,
                    await first.save(displayName: "SDK A " + plan.runID.prefix(8))
                else { throw SDKProbeFailure.unexpected }
                let restored = store(scopes[0])
                await restored.load()
                guard restored.profile == first.profile else { throw SDKProbeFailure.unexpected }
                result.createdAndRestored = true
                let original = try await native.fetchProfile(scope: scopes[0])
                guard let original, original.recordChangeTag?.isEmpty == false else {
                    throw SDKProbeFailure.unexpected
                }
                result.changeTagsPresent = true
                stage = "server-conflict"
                guard await restored.save(displayName: "SDK changed " + plan.runID.prefix(8)) else {
                    throw SDKProbeFailure.unexpected
                }
                let stale = try PrivateProfileRecordCodec.encode(
                    .init(displayName: "SDK stale"), updating: original, scope: scopes[0])
                do {
                    _ = try await native.saveProfile(stale, scope: scopes[0])
                    throw SDKProbeFailure.conflictNotObserved
                } catch {
                    let codes = errorCodes(error)
                    guard codes.contains(CKError.Code.serverRecordChanged.rawValue) else { throw error }
                    result.codes += codes
                }
                let verification = store(scopes[0])
                await verification.load()
                guard verification.profile?.displayName == "SDK changed " + plan.runID.prefix(8) else {
                    throw SDKProbeFailure.unexpected
                }
                result.staleWriteRejectedByServer = true
                stage = "same-icloud-namespace-isolation"
                let other = store(scopes[1])
                await other.load()
                guard other.didLoad, other.profile == nil,
                    await other.save(displayName: "SDK B " + plan.runID.prefix(8))
                else { throw SDKProbeFailure.unexpected }
                await verification.load()
                guard verification.profile?.displayName == "SDK changed " + plan.runID.prefix(8) else {
                    throw SDKProbeFailure.unexpected
                }
                result.sameICloudNamespacesIsolated = true
                stage = "deletion-guard"
                let deletion = UUID().uuidString.lowercased()
                var cursor: PrivateCleanupCursor?
                var erased = false
                for _ in 0..<4 {
                    let step = try await native.eraseAccountContentStep(
                        scope: scopes[0], deletionID: deletion, cursor: cursor, authorizeDeletion: check)
                    cursor = step.cursor
                    if step.contentDeleted {
                        erased = true
                        break
                    }
                }
                guard erased else { throw SDKProbeFailure.unexpected }
                do {
                    _ = try await native.saveProfile(stale, scope: scopes[0])
                    throw SDKProbeFailure.unexpected
                } catch PrivateDataFailure.accountDeleted {
                    result.deletionGuardEnforced = true
                }
            } catch {
                result.failedStage = stage
                result.error = "Diagnostyka nie potwierdziła etapu: " + stage
                result.codes += errorCodes(trace.lastError ?? error)
            }
            // Cleanup only exact namespaces confirmed absent before this one claimed attempt.
            for (index, scope) in scopes.enumerated() where mayClean[index] {
                do {
                    try await check(scope)
                    do { _ = try await cloud.deleteRecordZone(withID: scope.zoneID) } catch let error
                        as CKError where error.code == .zoneNotFound || error.code == .unknownItem
                    {}
                    try await check(scope)
                    do {
                        _ = try await cloud.recordZone(for: scope.zoneID)
                        throw SDKProbeFailure.unexpected
                    } catch let error as CKError
                        where error.code == .zoneNotFound || error.code == .unknownItem
                    {
                        result.cleanedZoneCount += 1
                    }
                } catch {
                    result.cleanupError =
                        "Nie potwierdzono sprzątania własnej strefy. Zachowaj runID do odzyskania."
                    result.codes += errorCodes(error)
                }
            }
            result.cleanupVerified = result.cleanedZoneCount == 2 && result.namespacesInitiallyAbsent
            result.codes = Array(Set(result.codes)).sorted()
            finish(result)
        }
        private func finish(_ result: Report) {
            report = result
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(result).write(
                    to: directory().appendingPathComponent("result-" + result.runID + ".json"),
                    options: [.atomic, .completeFileProtection])
                let compact = JSONEncoder()
                compact.dateEncodingStrategy = .iso8601
                FileHandle.standardOutput.write(
                    Data("ECHOES_PRIVATE_PROFILE_SDK_RESULT ".utf8) + (try compact.encode(result))
                        + Data("\n".utf8))
            } catch { reportWriteFailed = true }
        }
    }
    @MainActor private final class SDKProbeProfileDatabase: PrivateProfileDatabase {
        let base: any PrivateProfileDatabase
        private(set) var lastError: (any Error)?
        init(base: any PrivateProfileDatabase) { self.base = base }
        func fetchProfile(scope: PrivateAccountScope) async throws -> CKRecord? {
            do { return try await base.fetchProfile(scope: scope) } catch {
                lastError = error
                throw error
            }
        }
        func saveProfile(_ record: CKRecord, scope: PrivateAccountScope) async throws -> CKRecord {
            do { return try await base.saveProfile(record, scope: scope) } catch {
                lastError = error
                throw error
            }
        }
        func deleteProfile(scope: PrivateAccountScope) async throws {
            do { try await base.deleteProfile(scope: scope) } catch {
                lastError = error
                throw error
            }
        }
    }
#endif
