#if DEBUG
    import Foundation
    import Testing
    @testable import EchoesCloudKit

    private let probeNow = Date(timeIntervalSince1970: 1_800_000_000)
    private func probePayload(_ changes: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = [
            "version": 1, "container": "iCloud.mpvEcho.Echo", "environment": "development",
            "runID": "50000000-0000-4000-8000-000000000001",
            "accountIDs": ["50000000-0000-4000-8000-000000000002", "50000000-0000-4000-8000-000000000003"],
            "notBefore": 1_800_000_000, "expiresAt": 1_800_000_900,
        ]
        value.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
    @Test func sdkProbePlanRequiresSignedAppClosedBoundedConfiguration() throws {
        let data = try probePayload()
        #expect(throws: GatewayFailure.configuration) {
            try PrivateProfileProbePlan(data: data, bundleIdentifier: "other", now: probeNow)
        }
        for bytes in [
            Data(), Data(repeating: 32, count: 2049), try probePayload(["extra": true]),
            try probePayload(["version": true]), try probePayload(["environment": "production"]),
            try probePayload(["container": "iCloud.other"]),
        ] {
            #expect(throws: GatewayFailure.configuration) {
                try PrivateProfileProbePlan(data: bytes, bundleIdentifier: "mpvEcho.Echo", now: probeNow)
            }
        }
    }
    @Test func sdkProbePlanDeniesExpiredFutureAndLongWindows() throws {
        for changes in [
            ["expiresAt": 1_800_000_000], ["expiresAt": 1_800_001_801], ["notBefore": 1_800_000_001],
            ["notBefore": 1_800_000_900, "expiresAt": 1_800_000_899],
        ] {
            let data = try probePayload(changes)
            #expect(throws: GatewayFailure.configuration) {
                try PrivateProfileProbePlan(data: data, bundleIdentifier: "mpvEcho.Echo", now: probeNow)
            }
        }
    }
    @Test func sdkProbePlanRejectsDuplicateUnboundedOrMalformedAccounts() throws {
        let first = "50000000-0000-4000-8000-000000000002"
        for ids in [
            [first], [first, first], [first, "../outside"], [first, "50000000-0000-4000-8000-000000000001"],
            [first, first, first],
        ] {
            let data = try probePayload(["accountIDs": ids])
            #expect(throws: GatewayFailure.configuration) {
                try PrivateProfileProbePlan(data: data, bundleIdentifier: "mpvEcho.Echo", now: probeNow)
            }
        }
    }
    @Test func sdkProbePlanPermitsOnlyOwnTwoNamespacesInLiveDevelopmentWindow() throws {
        let plan = try PrivateProfileProbePlan(
            data: probePayload(), bundleIdentifier: "mpvEcho.Echo", now: probeNow)
        let scopes = try plan.scopes(cloudKitRecordName: "synthetic-owner")
        #expect(scopes.count == 2 && scopes[0].zoneID != scopes[1].zoneID)
        for scope in scopes {
            #expect(plan.permits(scope, cloudKitRecordName: "synthetic-owner", at: probeNow))
            #expect(!plan.permits(scope, cloudKitRecordName: "different-owner", at: probeNow))
            #expect(!plan.permits(scope, cloudKitRecordName: "synthetic-owner", at: plan.expiresAt))
        }
        let foreign = try PrivateAccountScope(
            configuration: plan.configuration, accountID: UUID().uuidString.lowercased(),
            cloudKitRecordName: "synthetic-owner")
        #expect(!plan.permits(foreign, cloudKitRecordName: "synthetic-owner", at: probeNow))
        let production = try PrivateAccountScope(
            configuration: .init(containerIdentifier: "iCloud.mpvEcho.Echo", environment: .production),
            accountID: plan.accountIDs[0], cloudKitRecordName: "synthetic-owner")
        #expect(!plan.permits(production, cloudKitRecordName: "synthetic-owner", at: probeNow))
    }

    @MainActor private func claimDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "echoes-sdk-claim-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    @Test @MainActor func sdkProbeClaimIsExclusiveAcrossNewObjectsAndHasPrivatePermissions() throws {
        let root = try claimDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try PrivateProfileProbePlan(
            data: probePayload(), bundleIdentifier: "mpvEcho.Echo", now: probeNow)
        try PrivateProfileProbeClaim(directory: root).claim(plan, at: probeNow)
        #expect(throws: PrivateProfileProbeClaimFailure.replayed) {
            try PrivateProfileProbeClaim(directory: root).claim(plan, at: probeNow)
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(plan.runID + ".claim").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.size] as? NSNumber)?.intValue == 0)
    }
    @Test @MainActor func expiredSDKClaimDoesNotCreateAMarker() throws {
        let root = try claimDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try PrivateProfileProbePlan(
            data: probePayload(), bundleIdentifier: "mpvEcho.Echo", now: probeNow)
        #expect(throws: PrivateProfileProbeClaimFailure.inactive) {
            try PrivateProfileProbeClaim(directory: root).claim(plan, at: plan.expiresAt)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @Test @MainActor func sdkClaimDoesNotFollowDirectoryOrMarkerSymlinks() throws {
        let root = try claimDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("keep.txt")
        try Data("preserve".utf8).write(to: target)
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
        let plan = try PrivateProfileProbePlan(
            data: probePayload(), bundleIdentifier: "mpvEcho.Echo", now: probeNow)
        #expect(throws: PrivateProfileProbeClaimFailure.storage) {
            try PrivateProfileProbeClaim(directory: linked).claim(plan, at: probeNow)
        }
        let marker = root.appendingPathComponent(plan.runID + ".claim")
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
        #expect(throws: PrivateProfileProbeClaimFailure.replayed) {
            try PrivateProfileProbeClaim(directory: root).claim(plan, at: probeNow)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "preserve")
    }
    @Test @MainActor func sdkClaimRequiresARealTrustedDirectory() throws {
        #expect(throws: PrivateProfileProbeClaimFailure.storage) {
            try PrivateProfileProbeClaim(directory: URL(string: "https://example.invalid")!)
        }
        #expect(throws: PrivateProfileProbeClaimFailure.storage) {
            try PrivateProfileProbeClaim(directory: URL(fileURLWithPath: "/"))
        }
        let root = try claimDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try PrivateProfileProbePlan(
            data: probePayload(), bundleIdentifier: "mpvEcho.Echo", now: probeNow)
        #expect(throws: PrivateProfileProbeClaimFailure.storage) {
            try PrivateProfileProbeClaim(directory: root.appendingPathComponent("missing")).claim(
                plan, at: probeNow)
        }
    }
#endif
