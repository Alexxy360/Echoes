import Foundation
import Testing

@testable import EchoesCloudKit

private struct LocalDataFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "echoes-local-" + UUID().uuidString, isDirectory: true)
    let scope: PrivateAccountScope
    let otherScope: PrivateAccountScope
    let binding: GatewayIdentityBinding
    let store: GatewayLocalAccountData
    init() throws {
        let config = try CloudKitConfiguration(
            containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
        scope = try .init(
            configuration: config, accountID: "70000000-0000-4000-8000-000000000007",
            cloudKitRecordName: "local-owner")
        otherScope = try .init(
            configuration: config, accountID: "80000000-0000-4000-8000-000000000008",
            cloudKitRecordName: "local-owner")
        binding = try .init(appleUserID: "local-native-apple", cloudKitRecordName: "local-owner")
        store = try .init(root: root)
    }
    var namespace: URL { root.appendingPathComponent("EchoesCloudKitData", isDirectory: true) }
    var directory: URL { namespace.appendingPathComponent(scope.digest, isDirectory: true) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func scopedLocalFilesRoundTripAndErasureInvalidatesLateWritesWithoutDeletingAnotherAccount()
    async throws
{
    let f = try LocalDataFixture()
    defer { f.cleanup() }
    let old = try await f.store.activate(scope: f.scope, binding: f.binding)
    for kind in GatewayLocalDataKind.allCases {
        try await f.store.write(Data("private-A".utf8), kind: kind, lease: old)
    }
    #expect(try await f.store.read(kind: .profile, lease: old) == Data("private-A".utf8))
    let other = try await f.store.activate(scope: f.otherScope, binding: f.binding)
    try await f.store.write(Data("private-B".utf8), kind: .profile, lease: other)
    await #expect(throws: GatewayLocalDataFailure.inactive) {
        try await f.store.write(Data("late-A".utf8), kind: .avatar, lease: old)
    }
    try await f.store.erase(scope: f.scope)
    #expect(!FileManager.default.fileExists(atPath: f.directory.path))
    #expect(try await f.store.read(kind: .profile, lease: other) == Data("private-B".utf8))
    try await f.store.erase(scope: f.scope)
}

@Test func localAccessFenceOnlyInvalidatesItsMatchingAccountAndBinding() async throws {
    let f = try LocalDataFixture()
    defer { f.cleanup() }
    let lease = try await f.store.activate(scope: f.scope, binding: f.binding)
    try await f.store.write(Data("cached".utf8), kind: .profile, lease: lease)
    await f.store.fence(binding: f.binding, accountID: f.otherScope.accountID)
    #expect(try await f.store.read(kind: .profile, lease: lease) != nil)
    await f.store.fence(binding: f.binding, accountID: f.scope.accountID)
    await #expect(throws: GatewayLocalDataFailure.inactive) {
        try await f.store.read(kind: .profile, lease: lease)
    }
}

@Test func scopedCacheRejectsOversizedAndLinkedFilesWithoutTruncatingTheirTarget() async throws {
    let f = try LocalDataFixture()
    defer { f.cleanup() }
    let lease = try await f.store.activate(scope: f.scope, binding: f.binding)
    await #expect(throws: GatewayLocalDataFailure.invalidData) {
        try await f.store.write(Data(repeating: 1, count: 262145), kind: .avatar, lease: lease)
    }
    try await f.store.write(Data("valid".utf8), kind: .profile, lease: lease)
    let target = f.root.appendingPathComponent("outside-owned-target")
    try Data("must-remain".utf8).write(to: target)
    let avatar = f.directory.appendingPathComponent("avatar.jpg")
    try FileManager.default.createSymbolicLink(at: avatar, withDestinationURL: target)
    await #expect(throws: GatewayLocalDataFailure.unavailable) {
        try await f.store.write(Data("wrong".utf8), kind: .avatar, lease: lease)
    }
    await #expect(throws: GatewayLocalDataFailure.unavailable) {
        try await f.store.read(kind: .avatar, lease: lease)
    }
    try FileManager.default.removeItem(at: avatar)
    try FileManager.default.linkItem(at: target, to: avatar)
    await #expect(throws: GatewayLocalDataFailure.unavailable) {
        try await f.store.write(Data("wrong".utf8), kind: .avatar, lease: lease)
    }
    #expect(try Data(contentsOf: target) == Data("must-remain".utf8))
    try await f.store.erase(scope: f.scope)
    #expect(try Data(contentsOf: target) == Data("must-remain".utf8))
}

@Test func symlinkedScopeOrNamespaceNeverRedirectsLocalCleanupOutsideItsRoot() async throws {
    let f = try LocalDataFixture()
    defer { f.cleanup() }
    try FileManager.default.createDirectory(at: f.namespace, withIntermediateDirectories: true)
    let outside = f.root.appendingPathComponent("outside-owned-directory", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let target = outside.appendingPathComponent("profile.json")
    try Data("outside".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: f.directory, withDestinationURL: outside)
    await #expect(throws: GatewayLocalDataFailure.unavailable) { try await f.store.erase(scope: f.scope) }
    #expect(try Data(contentsOf: target) == Data("outside".utf8))
    try FileManager.default.removeItem(at: f.directory)
    try FileManager.default.removeItem(at: f.namespace)
    try FileManager.default.createSymbolicLink(at: f.namespace, withDestinationURL: outside)
    await #expect(throws: GatewayLocalDataFailure.unavailable) { try await f.store.erase(scope: f.scope) }
    #expect(try Data(contentsOf: target) == Data("outside".utf8))
}

@Test func unexpectedLocalFilesFailCleanupInsteadOfFalselyAcknowledgingAnEmptyScope() async throws {
    let f = try LocalDataFixture()
    defer { f.cleanup() }
    let lease = try await f.store.activate(scope: f.scope, binding: f.binding)
    try await f.store.write(Data("profile".utf8), kind: .profile, lease: lease)
    let unknown = f.directory.appendingPathComponent("unmigrated-future-format")
    try Data("unknown".utf8).write(to: unknown)
    await #expect(throws: GatewayLocalDataFailure.unavailable) { try await f.store.erase(scope: f.scope) }
    #expect(FileManager.default.fileExists(atPath: unknown.path))
    await #expect(throws: GatewayLocalDataFailure.inactive) {
        try await f.store.read(kind: .profile, lease: lease)
    }
    try FileManager.default.removeItem(at: unknown)
    try await f.store.erase(scope: f.scope)
}
