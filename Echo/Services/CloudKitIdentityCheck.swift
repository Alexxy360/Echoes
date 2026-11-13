#if DEBUG
    import CryptoKit
    import EchoesCloudKit
    import Foundation
    import Observation

    /// Read-only account comparison. Never fetches profiles or reads/writes application records.
    @MainActor @Observable
    final class CloudKitIdentityCheck {
        struct Report: Codable {
            var runIdentifier = UUID().uuidString
            var startedAt = Date()
            var mode = "account-identity-only"
            var environment = "Development"
            var container = "iCloud.mpvEcho.Echo"
            var accountAvailable = false
            var accountMatchesServiceIdentity: Bool?
            var error: String?
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
                guard let expected = ProcessInfo.processInfo.environment["ECHOES_CLOUDKIT_SERVICE_ID_HASH"],
                    expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
                else { throw CloudKitFailure.configuration }
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
                let actual = SHA256.hash(data: Data(identity.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                result.accountMatchesServiceIdentity = actual == expected
            } catch {
                result.error = CloudKitFailure.classify(error).localizedDescription
            }
            report = result
            do {
                let directory = try FileManager.default.url(
                    for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(result).write(
                    to: directory.appendingPathComponent("cloudkit-identity-result.json"), options: .atomic)
            } catch { reportFileError = true }
        }
    }
#endif
