import Foundation

public struct CloudKitConfiguration: Equatable, Sendable {
    public enum Environment: String, Sendable {
        case development = "Development"
        case production = "Production"
    }
    public let containerIdentifier: String
    public let environment: Environment

    /// The identifier must come from the owner's Apple Developer account, not a generated fallback.
    public init(containerIdentifier: String, environment: Environment) throws {
        let suffix = containerIdentifier.dropFirst("iCloud.".count)
        guard containerIdentifier.hasPrefix("iCloud."), !suffix.isEmpty,
            !suffix.hasPrefix("."), !suffix.hasSuffix("."), !suffix.contains(".."),
            containerIdentifier.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 46
            })
        else { throw CloudKitFailure.configuration }
        self.containerIdentifier = containerIdentifier
        self.environment = environment
    }

    /// Checks signed app/profile entitlements supplied by build tooling. Does not grant capabilities.
    public func validateEntitlements(_ entitlements: [String: Any]) throws {
        guard let services = entitlements["com.apple.developer.icloud-services"] as? [String],
            services.contains("CloudKit"),
            let containers = entitlements["com.apple.developer.icloud-container-identifiers"]
                as? [String],
            containers.contains(containerIdentifier),
            entitlements["com.apple.developer.icloud-container-environment"] as? String
                == environment.rawValue
        else { throw CloudKitFailure.configuration }
    }
}
