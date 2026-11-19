import Foundation
import Testing

@testable import EchoesCloudKit

private final class AvatarReviewReadStorage: GatewayAvatarReviewJournalStorage, @unchecked Sendable {
    let base = ReviewMemoryStorage(), readGate = ReviewStorageGate()
    func read(scope: GatewayAvatarReviewScope) throws -> Data? {
        readGate.blockIfArmed()
        return try base.read(scope: scope)
    }
    func write(_ data: Data, scope: GatewayAvatarReviewScope) throws { try base.write(data, scope: scope) }
    func erase(owner: PrivateAccountScope) throws { try base.erase(owner: owner) }
}
@MainActor private final class AvatarReviewTokenHook: GatewayAvatarAuthorizationSource {
    let base: PhotoAuthorization
    var afterToken: (() -> Void)?
    init(_ base: PhotoAuthorization) { self.base = base }
    var communityAuthorization: GatewayCommunityAuthorization? { base.communityAuthorization }
    func privateDataScope(configuration: CloudKitConfiguration) -> PrivateAccountScope? {
        base.privateDataScope(configuration: configuration)
    }
    func communityAccessToken(for value: GatewayCommunityAuthorization) async throws -> GatewaySecret {
        let result = try await base.communityAccessToken(for: value)
        let action = afterToken
        afterToken = nil
        action?()
        return result
    }
    func rejectCommunityAccess(for value: GatewayCommunityAuthorization) async {
        await base.rejectCommunityAccess(for: value)
    }
}

@Test @MainActor func avatarReviewHostLastJournalReadRechecksNativeScopeBeforeAnyInspectDispatch()
    async throws
{
    let f = try ReviewHostFixture()
    let storage = AvatarReviewReadStorage()
    let source = AvatarReviewTokenHook(f.authorization)
    let journal = GatewayAvatarReviewJournal(storage: storage)
    let host = try GatewayAvatarReviewHost(
        api: f.api, configuration: .init(origin: URL(string: f.api.origin)!),
        cloudKit: f.scope.owner.configuration,
        authorization: source, journal: journal, isEnabled: { true }, date: { f.clock.date() },
        uptime: { f.clock.up() })
    host.setForeground(true)
    try await host.connect()
    try await host.refreshQueue()
    source.afterToken = { storage.readGate.arm() }
    let running = Task { try await host.inspect(f.wire.item) }
    defer {
        storage.readGate.release()
        running.cancel()
    }
    for _ in 0..<5000 {
        if storage.readGate.hasEntered() { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(storage.readGate.hasEntered())
    f.authorization.cloudName = "other-cloud-account"
    storage.readGate.release()
    await #expect(throws: GatewayAvatarReviewHostFailure.superseded) { try await running.value }
    #expect(await f.api.calls == ["queue"])
    #expect(host.presentation == nil && !host.isConnected)
}

@Test @MainActor func avatarReviewJournalFullErasedOwnerMemoryClosesAdmissionButStillRetriesExactCleanup()
    async throws
{
    let storage = ReviewMemoryStorage()
    let journal = GatewayAvatarReviewJournal(storage: storage)
    let scope = try reviewStoreScope()
    let lease = try await journal.open(scope: scope)
    _ = try await journal.prepare(reviewStoreIntent(), lease: lease)
    for index in 0..<32 {
        let other = try reviewStoreScope(
            account: UUID().uuidString.lowercased(), cloud: "synthetic-erase-" + String(index))
        try await journal.erase(owner: other.owner)
    }
    storage.failErase = true
    await #expect(throws: GatewayAvatarReviewJournalFailure.unavailable) {
        try await journal.erase(owner: scope.owner)
    }
    #expect(!journal.isActive(lease) && storage.records[scope.digest] != nil)
    await #expect(throws: GatewayAvatarReviewJournalFailure.inactive) { try await journal.open(scope: scope) }
    storage.failErase = false
    try await journal.erase(owner: scope.owner)
    #expect(storage.records[scope.digest] == nil)
    await #expect(throws: GatewayAvatarReviewJournalFailure.inactive) { try await journal.open(scope: scope) }
}
