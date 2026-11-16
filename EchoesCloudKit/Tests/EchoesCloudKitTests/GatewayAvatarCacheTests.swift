import CryptoKit
import Darwin
import Foundation
import Testing

@testable import EchoesCloudKit

private final class AvatarCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date().timeIntervalSince1970
    func now() -> Date { lock.withLock { Date(timeIntervalSince1970: time) } }
    func advance(_ seconds: Double) { lock.withLock { time += seconds } }
}
private struct AvatarCacheFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "echoes-avatar-cache-" + UUID().uuidString)
    let clock = AvatarCacheClock()
    let configuration: GatewayConfiguration
    let cloudKit: CloudKitConfiguration
    let binding: GatewayIdentityBinding
    let owner: PrivateAccountScope
    let other: PrivateAccountScope
    let scope: GatewayAvatarCacheScope
    let otherScope: GatewayAvatarCacheScope
    let cache: GatewayAvatarCache
    init(limits: GatewayAvatarCache.Limits = .init()) throws {
        configuration = try .init(origin: URL(string: "https://avatar-cache.example.invalid")!)
        cloudKit = try .init(containerIdentifier: "iCloud.mpvEcho.Echo", environment: .development)
        binding = try .init(
            appleUserID: "synthetic-cache-apple", cloudKitRecordName: "synthetic-cache-icloud")
        owner = try .init(
            configuration: cloudKit, accountID: "66000000-0000-4000-8000-000000000001",
            cloudKitRecordName: "synthetic-cache-icloud")
        other = try .init(
            configuration: cloudKit, accountID: "66000000-0000-4000-8000-000000000002",
            cloudKitRecordName: "synthetic-cache-icloud")
        scope = try .init(configuration: configuration, privateScope: owner, binding: binding)
        otherScope = try .init(configuration: configuration, privateScope: other, binding: binding)
        cache = try .init(root: root, clock: { [clock] in clock.now() }, limits: limits)
    }
    func entry(_ variant: AvatarVariant = .thumbnail, version: String? = nil) throws
        -> GatewayAvatarCacheEntry
    {
        let f = try AvatarWireFixture(variant)
        let raw = try #require(f.downloaded.headers["x-echoes-avatar-manifest"])
        var object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        if let version { object["versionID"] = version }
        let reference = try AvatarReference(
            ownerID: f.query.reference.ownerID, versionID: version ?? f.query.reference.versionID)
        let manifest = try AvatarManifest(
            data: JSONSerialization.data(withJSONObject: object), expected: reference, variant: variant)
        return .init(manifest: manifest, bytes: f.downloaded.body)
    }
    var namespace: URL { root.appendingPathComponent("EchoesAvatarCache") }
    func directory(_ scope: GatewayAvatarCacheScope) -> URL {
        namespace.appendingPathComponent(scope.privateScope.digest).appendingPathComponent(
            scope.communityScope.digest)
    }
    func filename(_ scope: GatewayAvatarCacheScope) throws -> URL {
        try #require(
            FileManager.default.contentsOfDirectory(at: directory(scope), includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "bin" })
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func avatarDiskCacheRoundTripsBothVariantsAndSurvivesANewStoreInstance() async throws {
    let f = try AvatarCacheFixture()
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    for variant in [AvatarVariant.image, .thumbnail] {
        let entry = try f.entry(variant)
        try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
        let read = try #require(
            await f.cache.read(reference: entry.manifest.reference, variant: variant, lease: lease))
        #expect(read.manifest == entry.manifest && read.bytes == entry.bytes)
    }
    let reopened = try GatewayAvatarCache(root: f.root)
    let newLease = await reopened.activate(scope: f.scope)
    let thumb = try f.entry()
    #expect(
        try await reopened.read(reference: thumb.manifest.reference, variant: .thumbnail, lease: newLease)?
            .bytes == thumb.bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory(f.scope).path).count == 2)
}

@Test func avatarDiskCacheSeparatesAccountsOriginsAndNativeBindings() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    let other = await f.cache.activate(scope: f.otherScope)
    #expect(
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: other) == nil)
    await #expect(throws: GatewayAvatarCacheFailure.inactive) {
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: lease)
    }
    let origin = try GatewayConfiguration(origin: URL(string: "https://other-cache.example.invalid")!)
    let differentOrigin = try GatewayAvatarCacheScope(
        configuration: origin, privateScope: f.owner, binding: f.binding)
    let originLease = await f.cache.activate(scope: differentOrigin)
    #expect(
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: originLease)
            == nil)
    let native = try GatewayIdentityBinding(
        appleUserID: "other-native-apple", cloudKitRecordName: "synthetic-cache-icloud")
    let differentNative = try GatewayAvatarCacheScope(
        configuration: f.configuration, privateScope: f.owner, binding: native)
    #expect(differentNative != f.scope)
    #expect(differentNative.communityScope.digest != f.scope.communityScope.digest)
}

@Test func avatarDiskCacheLateFenceCannotInvalidateNewLeaseAndExactDeletionPreservesOtherAccount()
    async throws
{
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    let old = await f.cache.activate(scope: f.scope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: old)
    let current = await f.cache.activate(scope: f.otherScope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: current)
    await f.cache.fence(old)
    try await f.cache.erase(scope: f.owner)
    #expect(!FileManager.default.fileExists(atPath: f.directory(f.scope).deletingLastPathComponent().path))
    #expect(
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: current)
            != nil)
    await #expect(throws: GatewayAvatarCacheFailure.inactive) {
        try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: old)
    }
    try await f.cache.erase(scope: f.owner)
}

@Test func avatarDiskCacheDeletionRemovesAllBindingsOfExactOwnerAndFencesItsWrites() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    let first = await f.cache.activate(scope: f.scope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: first)
    let secondScope = try GatewayAvatarCacheScope(
        configuration: .init(origin: URL(string: "https://binding2.example.invalid")!), privateScope: f.owner,
        binding: f.binding)
    let second = await f.cache.activate(scope: secondScope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: second)
    try await f.cache.erase(scope: f.owner)
    await #expect(throws: GatewayAvatarCacheFailure.inactive) {
        try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: second)
    }
    #expect(!FileManager.default.fileExists(atPath: f.directory(f.scope).deletingLastPathComponent().path))
}

@Test func avatarDiskCacheBindingFenceMustMatchNativeIdentityAndAccount() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    let wrong = try GatewayIdentityBinding(
        appleUserID: "wrong-apple", cloudKitRecordName: "synthetic-cache-icloud")
    await f.cache.fence(binding: wrong, accountID: nil)
    await f.cache.fence(binding: f.binding, accountID: f.other.accountID)
    #expect(
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: lease) != nil)
    await f.cache.fence(binding: f.binding, accountID: f.owner.accountID)
    await #expect(throws: GatewayAvatarCacheFailure.inactive) {
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: lease)
    }
}

@Test func avatarDiskCacheUsesPrivatePermissionsAndExcludesNamespaceFromBackup() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    let file = try f.filename(f.scope)
    for (url, expected) in [(f.namespace, 0o700), (f.directory(f.scope), 0o700), (file, 0o600)] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == expected)
    }
    #expect(try f.namespace.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    #expect(!file.lastPathComponent.contains(entry.manifest.reference.ownerID))
    #expect(!String(describing: lease).contains(f.owner.accountID))
    #expect(Mirror(reflecting: f.scope).children.isEmpty)
    #expect(Mirror(reflecting: entry).children.isEmpty)
}

@Test func avatarDiskCacheExpiryIsNotExtendedByReadsOrRepeatedStore() async throws {
    let f = try AvatarCacheFixture(limits: .init(entries: 64, bytes: 8 * 1024 * 1024, lifetime: 10))
    let entry = try f.entry()
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    let before = try Data(contentsOf: f.filename(f.scope))
    f.clock.advance(5)
    #expect(
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: lease) != nil)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    #expect(try Data(contentsOf: f.filename(f.scope)) == before)
    f.clock.advance(6)
    #expect(
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: lease) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.directory(f.scope).path).isEmpty)
}

@Test func avatarDiskCacheEvictsLeastRecentlyUsedEntryWithinCountAndByteBounds() async throws {
    let f = try AvatarCacheFixture(limits: .init(entries: 2, bytes: 4000, lifetime: 300))
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    let a = try f.entry(version: "66000000-0000-4000-8000-000000000031")
    let b = try f.entry(version: "66000000-0000-4000-8000-000000000032")
    let c = try f.entry(version: "66000000-0000-4000-8000-000000000033")
    for entry in [a, b] { try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease) }
    f.clock.advance(5)
    #expect(try await f.cache.read(reference: a.manifest.reference, variant: .thumbnail, lease: lease) != nil)
    try await f.cache.store(c.bytes, manifest: c.manifest, lease: lease)
    #expect(try await f.cache.read(reference: b.manifest.reference, variant: .thumbnail, lease: lease) == nil)
    #expect(try await f.cache.read(reference: a.manifest.reference, variant: .thumbnail, lease: lease) != nil)
    #expect(try await f.cache.read(reference: c.manifest.reference, variant: .thumbnail, lease: lease) != nil)
    let sizes = try FileManager.default.contentsOfDirectory(
        at: f.directory(f.scope), includingPropertiesForKeys: [.fileSizeKey]
    ).map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
    #expect(sizes.count == 2 && sizes.reduce(0, +) <= 4000)
}

@Test func avatarDiskCacheByteQuotaEvictsEvenBeforeEntryQuotaAndRejectsIndividuallyOversizedEnvelope()
    async throws
{
    let f = try AvatarCacheFixture(limits: .init(entries: 64, bytes: 2000, lifetime: 300))
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    let a = try f.entry(version: "66000000-0000-4000-8000-000000000041")
    let b = try f.entry(version: "66000000-0000-4000-8000-000000000042")
    try await f.cache.store(a.bytes, manifest: a.manifest, lease: lease)
    try await f.cache.store(b.bytes, manifest: b.manifest, lease: lease)
    #expect(try await f.cache.read(reference: a.manifest.reference, variant: .thumbnail, lease: lease) == nil)
    let full = try f.entry(.image)
    await #expect(throws: GatewayAvatarCacheFailure.capacity) {
        try await f.cache.store(full.bytes, manifest: full.manifest, lease: lease)
    }
    #expect(try await f.cache.read(reference: b.manifest.reference, variant: .thumbnail, lease: lease) != nil)
}

@Test func avatarDiskCacheCorruptionIsDiscardedAndFreshBytesRemainRequired() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    let file = try f.filename(f.scope)
    var bytes = try Data(contentsOf: file)
    bytes[bytes.count - 10] ^= 1
    try bytes.write(to: file)
    #expect(
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: lease) == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    await #expect(throws: GatewayAvatarCacheFailure.invalidData) {
        try await f.cache.store(Data([0xff, 0xd8, 0xff, 0xd9]), manifest: entry.manifest, lease: lease)
    }
}

@Test func avatarDiskCacheRejectsSymlinkHardlinkAndFIFOWithoutTouchingExternalTarget() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    let file = try f.filename(f.scope)
    let target = f.root.appendingPathComponent("outside-target")
    try Data("outside-must-stay".utf8).write(to: target)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    await #expect(throws: GatewayAvatarCacheFailure.unavailable) {
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: lease)
    }
    await #expect(throws: GatewayAvatarCacheFailure.unavailable) {
        try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    }
    try FileManager.default.removeItem(at: file)
    try FileManager.default.linkItem(at: target, to: file)
    await #expect(throws: GatewayAvatarCacheFailure.unavailable) {
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: lease)
    }
    try FileManager.default.removeItem(at: file)
    #expect(mkfifo(file.path, mode_t(0o600)) == 0)
    await #expect(throws: GatewayAvatarCacheFailure.unavailable) {
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: lease)
    }
    try await f.cache.erase(scope: f.owner)
    #expect(try Data(contentsOf: target) == Data("outside-must-stay".utf8))
}

@Test func avatarDiskCacheSymlinkedNamespaceOrScopeCannotRedirectCleanup() async throws {
    let f = try AvatarCacheFixture()
    defer { f.cleanup() }
    let outside = f.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let marker = outside.appendingPathComponent("must-stay")
    try Data("outside".utf8).write(to: marker)
    try FileManager.default.createSymbolicLink(at: f.namespace, withDestinationURL: outside)
    await #expect(throws: GatewayAvatarCacheFailure.unavailable) { try await f.cache.erase(scope: f.owner) }
    try FileManager.default.removeItem(at: f.namespace)
    try FileManager.default.createDirectory(at: f.namespace, withIntermediateDirectories: true)
    let owner = f.directory(f.scope).deletingLastPathComponent()
    try FileManager.default.createSymbolicLink(at: owner, withDestinationURL: outside)
    await #expect(throws: GatewayAvatarCacheFailure.unavailable) { try await f.cache.erase(scope: f.owner) }
    #expect(try Data(contentsOf: marker) == Data("outside".utf8))
}

@Test func avatarDiskCacheUnknownFileFailsDeletionAndFencesLateWritesUntilExplicitRetry() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    let unknown = f.directory(f.scope).appendingPathComponent("future-unmigrated-format")
    try Data("must-not-hide".utf8).write(to: unknown)
    await #expect(throws: GatewayAvatarCacheFailure.unavailable) { try await f.cache.erase(scope: f.owner) }
    #expect(FileManager.default.fileExists(atPath: unknown.path))
    await #expect(throws: GatewayAvatarCacheFailure.inactive) {
        try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    }
    try FileManager.default.removeItem(at: unknown)
    try await f.cache.erase(scope: f.owner)
}

@Test func avatarDiskCacheCleansOwnedCrashTemporaryFilesAndRejectsOversizedFiles() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    let temporary = f.directory(f.scope).appendingPathComponent(".tmp-" + UUID().uuidString.lowercased())
    try Data("partial".utf8).write(to: temporary)
    #expect(
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: lease) != nil)
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
    let file = try f.filename(f.scope)
    try Data(repeating: 0, count: 260_097).write(to: file)
    await #expect(throws: GatewayAvatarCacheFailure.unavailable) {
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: lease)
    }
    try await f.cache.erase(scope: f.owner)
}

@Test func avatarDiskCacheCapsOwnerAndBindingDirectoriesWithoutEvictingAnotherAccount() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    for i in 1...8 {
        let account = String(format: "66000000-0000-4000-8000-%012d", i)
        let owner = try PrivateAccountScope(
            configuration: f.cloudKit, accountID: account, cloudKitRecordName: "synthetic-cache-icloud")
        let scope = try GatewayAvatarCacheScope(
            configuration: f.configuration, privateScope: owner, binding: f.binding)
        let lease = await f.cache.activate(scope: scope)
        try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    }
    let ninthOwner = try PrivateAccountScope(
        configuration: f.cloudKit, accountID: "66000000-0000-4000-8000-000000000009",
        cloudKitRecordName: "synthetic-cache-icloud")
    let ninthScope = try GatewayAvatarCacheScope(
        configuration: f.configuration, privateScope: ninthOwner, binding: f.binding)
    let ninth = await f.cache.activate(scope: ninthScope)
    await #expect(throws: GatewayAvatarCacheFailure.capacity) {
        try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: ninth)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.namespace.path).count == 8)
    let first = await f.cache.activate(scope: f.scope)
    #expect(
        try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: first) != nil)
    for i in 2...3 {
        let configuration = try GatewayConfiguration(
            origin: URL(string: "https://binding-\(i).example.invalid")!)
        let scope = try GatewayAvatarCacheScope(
            configuration: configuration, privateScope: f.owner, binding: f.binding)
        let lease = await f.cache.activate(scope: scope)
        if i == 2 {
            try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
        } else {
            await #expect(throws: GatewayAvatarCacheFailure.capacity) {
                try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
            }
        }
    }
}

@Test func avatarDiskCacheRejectsMismatchedICloudScopeAndCancellationBeforeIO() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    let wrong = try GatewayIdentityBinding(
        appleUserID: "synthetic-apple", cloudKitRecordName: "different-icloud")
    #expect(throws: GatewayFailure.accountMismatch) {
        try GatewayAvatarCacheScope(configuration: f.configuration, privateScope: f.owner, binding: wrong)
    }
    let lease = await f.cache.activate(scope: f.scope)
    let operation = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    }
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(!FileManager.default.fileExists(atPath: f.namespace.path))
}

@Test @MainActor func avatarDiskCacheCleanupFailurePreventsPrivateACKAndScopedRetryCompletes() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    let flow = try DeletionFlowFixture()
    defer { f.cleanup() }
    let owner = try PrivateAccountScope(
        configuration: flow.config, accountID: flowAccountID, cloudKitRecordName: flow.owner.name)
    let scope = try GatewayAvatarCacheScope(
        configuration: f.configuration, privateScope: owner, binding: flow.binding)
    let lease = await f.cache.activate(scope: scope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    let unknown = f.directory(scope).appendingPathComponent("future-format")
    try Data("must-not-ack".utf8).write(to: unknown)
    flow.localHook = { try await f.cache.erase(scope: owner) }
    flow.cleanup.complete = true
    let controller = flow.controller()
    let started = try await flow.request(controller)
    await #expect(throws: GatewayAvatarCacheFailure.unavailable) {
        try await controller.advance(journalID: started.journalID)
    }
    let pending = try #require(flow.storage.journal().requests.first)
    #expect(pending.contentDeleted && !pending.localDataDeleted && flow.api.ackCalls == 0)
    await #expect(throws: GatewayAvatarCacheFailure.inactive) {
        try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    }
    try FileManager.default.removeItem(at: unknown)
    controller.suspend()
    let completed = try await flow.controller().advance(journalID: started.journalID)
    #expect(completed.completed && flow.api.ackCalls == 1 && flow.cleanup.calls == 1)
    #expect(!FileManager.default.fileExists(atPath: f.directory(scope).path))
}

@Test func avatarDiskCacheRejectsChangedBytesForAnExistingImmutableVersion() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
    let file = try f.filename(f.scope)
    let original = try Data(contentsOf: file)
    // Valid JPEG with a synthetic comment. Changed bytes must not overwrite the same version key.
    var altered = Data([0xff, 0xd8, 0xff, 0xfe, 0x00, 0x05, 0x61, 0x62, 0x63])
    altered.append(entry.bytes.dropFirst(2))
    let raw: [String: Any] = [
        "schemaVersion": 1, "ownerID": entry.manifest.reference.ownerID,
        "versionID": entry.manifest.reference.versionID,
        "variant": "thumbnail", "byteCount": altered.count, "width": entry.manifest.width,
        "height": entry.manifest.height,
        "sha256": SHA256.hash(data: altered).map { String(format: "%02x", $0) }.joined(),
    ]
    let manifest = try AvatarManifest(
        data: JSONSerialization.data(withJSONObject: raw), expected: entry.manifest.reference,
        variant: .thumbnail)
    _ = try AvatarPayloadValidator.decode(altered, manifest: manifest)
    await #expect(throws: GatewayAvatarCacheFailure.invalidData) {
        try await f.cache.store(altered, manifest: manifest, lease: lease)
    }
    #expect(try Data(contentsOf: file) == original)
}

@Test func avatarDiskCacheRejectsMalformedEnvelopeHeadersWithoutAcceptingTheirBytes() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    for change in 0...1 {
        try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
        let file = try f.filename(f.scope)
        var data = try Data(contentsOf: file)
        if change == 0 { data[0] ^= 1 } else { data[Data("ECHOESAVATAR1\n".utf8).count] = 255 }
        try data.write(to: file)
        #expect(
            try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: lease)
                == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Test func avatarDiskCacheRejectsFutureBooleanAndForeignVersionEnvelopeMetadata() async throws {
    let f = try AvatarCacheFixture()
    let entry = try f.entry()
    defer { f.cleanup() }
    let lease = await f.cache.activate(scope: f.scope)
    let prefix = Data("ECHOESAVATAR1\n".utf8)
    for mutation in 0...3 {
        try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
        let file = try f.filename(f.scope)
        let data = try Data(contentsOf: file)
        let count = data[prefix.count..<(prefix.count + 4)].reduce(0) { $0 * 256 + Int($1) }
        let end = prefix.count + 4 + count
        var object = try #require(
            JSONSerialization.jsonObject(with: data.subdata(in: (prefix.count + 4)..<end)) as? [String: Any])
        switch mutation {
        case 0: object["storedAt"] = true
        case 1: object["storedAt"] = f.clock.now().timeIntervalSince1970 + 1000
        case 2: object["unexpected"] = "not-a-cache-field"
        default:
            var manifest = try #require(object["manifest"] as? [String: Any])
            manifest["versionID"] = "66000000-0000-4000-8000-000000000099"
            object["manifest"] = manifest
        }
        let json = try JSONSerialization.data(withJSONObject: object)
        let size = UInt32(json.count)
        var changed = prefix
        changed.append(contentsOf: [
            UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255),
        ])
        changed.append(json)
        changed.append(data.suffix(from: end))
        try changed.write(to: file)
        #expect(
            try await f.cache.read(reference: entry.manifest.reference, variant: .thumbnail, lease: lease)
                == nil)
    }
}

#if os(iOS) && !targetEnvironment(simulator)
    private let avatarCachePhysicalDevice = true
#else
    private let avatarCachePhysicalDevice = false
#endif

@Test(
    .enabled(
        if: avatarCachePhysicalDevice,
        "Data Protection requires a physical iOS device; Simulator returned no attribute."))
func avatarDiskCachePhysicalFileProtectionIsComplete() async throws {
    #if os(iOS)
        let f = try AvatarCacheFixture()
        let entry = try f.entry()
        defer { f.cleanup() }
        let lease = await f.cache.activate(scope: f.scope)
        try await f.cache.store(entry.bytes, manifest: entry.manifest, lease: lease)
        let attributes = try FileManager.default.attributesOfItem(atPath: f.filename(f.scope).path)
        let protection =
            (attributes[.protectionKey] as? FileProtectionType)?.rawValue
            ?? (attributes[.protectionKey] as? String)
        #expect(protection == FileProtectionType.complete.rawValue)
    #endif
}
