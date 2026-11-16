#if DEBUG
    import Foundation

    /// Bundled, signed, short-lived authorization for synthetic SDK diagnostics, never a user URL.
    public struct PrivateProfileProbePlan: Sendable {
        public let runID: String
        public let accountIDs: [String]
        public let notBefore: Date
        public let expiresAt: Date
        public static let maximumLifetime: TimeInterval = 1800
        public let configuration: CloudKitConfiguration
        private struct Payload: Decodable {
            let version: Int
            let container: String
            let environment: String
            let runID: String
            let accountIDs: [String]
            let notBefore: Int64
            let expiresAt: Int64
        }
        public init(data: Data, bundleIdentifier: String?, now: Date = Date()) throws {
            do {
                guard data.count <= 2048, bundleIdentifier == "mpvEcho.Echo",
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    Set(object.keys)
                        == Set([
                            "version", "container", "environment", "runID", "accountIDs", "notBefore",
                            "expiresAt",
                        ])
                else { throw GatewayFailure.configuration }
                let value = try JSONDecoder().decode(Payload.self, from: data)
                guard value.version == 1, value.container == "iCloud.mpvEcho.Echo",
                    value.environment == "development", gatewayUUID(value.runID),
                    value.accountIDs.count == 2, Set(value.accountIDs).count == 2,
                    value.accountIDs.allSatisfy({ gatewayUUID($0) && $0 != value.runID })
                else { throw GatewayFailure.configuration }
                runID = value.runID
                accountIDs = value.accountIDs
                notBefore = Date(timeIntervalSince1970: Double(value.notBefore))
                expiresAt = Date(timeIntervalSince1970: Double(value.expiresAt))
                configuration = try CloudKitConfiguration(
                    containerIdentifier: value.container, environment: .development)
                guard expiresAt > notBefore, expiresAt.timeIntervalSince(notBefore) <= Self.maximumLifetime,
                    isActive(at: now)
                else { throw GatewayFailure.configuration }
            } catch { throw GatewayFailure.configuration }
        }
        public func isActive(at now: Date = Date()) -> Bool { now >= notBefore && now < expiresAt }
        public func scopes(cloudKitRecordName: String) throws -> [PrivateAccountScope] {
            try accountIDs.map {
                try .init(configuration: configuration, accountID: $0, cloudKitRecordName: cloudKitRecordName)
            }
        }
        public func permits(_ scope: PrivateAccountScope, cloudKitRecordName: String, at now: Date = Date())
            -> Bool
        {
            isActive(at: now) && scope.configuration == configuration && accountIDs.contains(scope.accountID)
                && scope.matchesCloudKitRecordName(cloudKitRecordName)
        }
    }
#endif
