import Foundation
import Testing

@testable import EchoesCloudKit

@Test @MainActor func avatarReportRefreshMakesNewProtectedHandleAndRequiresDisplayAgainWithoutSubmitting()
    async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, photo, original) = try await f.show()
    let before = await f.avatar.photo.api.captured().count
    try await f.host.refreshPhoto(photo)
    let next = try #require(f.host.presentation)
    #expect(next != original && f.host.image(for: original) == nil && !f.host.canSubmit)
    #expect(await f.avatar.photo.api.captured().count == before + 1)
    #expect(await f.api.calls.isEmpty)
    #expect(throws: GatewayAvatarReportHostFailure.displayRequired) { try f.host.acknowledgeDisplay(next) }
    _ = try #require(f.host.image(for: next))
    try f.host.acknowledgeDisplay(next)
    #expect(f.host.canSubmit && f.host.pendingOperation == nil)
}
@Test @MainActor func avatarReportExpiredClaimCanRequestFreshReadButNeverRevivesOriginalConsent() async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, photo, old) = try await f.show()
    f.avatar.photo.state.time += 31
    #expect(f.host.image(for: old) == nil)
    #expect(throws: GatewayAvatarReportHostFailure.displayRequired) { try photo.snapshot() }
    try await f.host.refreshPhoto(photo)
    let fresh = try #require(f.host.presentation)
    #expect(fresh != old && !f.host.canSubmit)
    #expect(throws: GatewayAvatarReportHostFailure.displayRequired) { try photo.snapshot() }
    _ = try #require(f.host.image(for: fresh))
    try f.host.acknowledgeDisplay(fresh)
    #expect(f.host.canSubmit)
}
@Test @MainActor func avatarReportRefreshRetainsBusyUntilSharedReadDrainsAndCannotBorrowReleasedConsumer()
    async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (lease, photo, _) = try await f.show()
    await f.avatar.photo.api.gate.arm()
    let work = Task { try await f.host.refreshPhoto(photo) }
    try await f.avatar.photo.api.gate.wait()
    f.avatar.binding.release(lease)
    #expect(f.host.isBusy)
    await #expect(throws: GatewayAvatarReportFailure.busy) { try await f.connect() }
    await f.avatar.photo.api.gate.release()
    _ = await work.result
    #expect(!f.host.isBusy && !f.host.isConnected && f.host.presentation == nil)
    #expect(await f.api.calls.isEmpty)
}
@Test @MainActor func avatarReportRefreshRejectsNativeAndParentChangeAcrossProtectedRead() async throws {
    for native in [true, false] {
        let f = try await PhotoReportHostFixture()
        defer { f.close() }
        let (_, photo, _) = try await f.show()
        await f.avatar.photo.api.gate.arm()
        let work = Task { try await f.host.refreshPhoto(photo) }
        try await f.avatar.photo.api.gate.wait()
        if native {
            try f.avatar.photo.source.select("67000000-0000-4000-8000-000000000002")
        } else {
            f.state.parent = false
        }
        await f.avatar.photo.api.gate.release()
        let result = await work.result
        #expect(throws: (any Error).self) { try result.get() }
        #expect(f.host.presentation == nil && !f.host.canSubmit)
        #expect(await f.api.calls.isEmpty)
    }
}
@Test @MainActor func avatarReportRefreshUsesExistingFullPhotoQuotaAndNeverFallsBackAfterRefusal()
    async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, photo, _) = try await f.show()
    for _ in 0..<3 { try await f.host.refreshPhoto(photo) }
    await #expect(throws: GatewayAvatarReportFailure.unavailable) { try await f.host.refreshPhoto(photo) }
    #expect(await f.avatar.photo.api.captured().count == 4)
    #expect(f.host.presentation == nil && !f.host.isConnected)
}
@Test @MainActor func avatarReportPresenterOldSheetAndOwnerCannotCloseOrOperateNewSession() async throws {
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let presenter = GatewayAvatarReportPresenter(host: f.host)
    let ownerA = UUID()
    let ownerB = UUID()
    let first = try presenter.open(ownerID: ownerA, isCurrent: { true })
    try await first.open()
    let second = try presenter.open(ownerID: ownerB, isCurrent: { true })
    try await second.open()
    first.close()
    presenter.invalidate(ownerID: ownerA)
    #expect(!first.isCurrent && second.isCurrent && f.host.isConnected)
    await #expect(throws: GatewayAvatarReportHostFailure.superseded) { try await first.cancelPending() }
    await #expect(throws: GatewayAvatarReportHostFailure.superseded) { try await first.recover() }
    #expect(second.isCurrent && f.host.isConnected)
    presenter.invalidate(ownerID: ownerB)
    #expect(!second.isCurrent && !f.host.isConnected)
    #expect(await f.api.calls.isEmpty)
}
@Test @MainActor func avatarReportRecoverySessionWithoutPhotoKeepsOriginalIdentityAndDoesNotRestoreConsent()
    async throws
{
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let (_, _, shown) = try await f.show()
    await f.api.set(.accepted, loseACK: true)
    await #expect(throws: GatewayAvatarReportFailure.unavailable) {
        try await f.host.submit(reason: "PRIVATE", presentation: shown)
    }
    let presenter = GatewayAvatarReportPresenter(host: f.host)
    let recovery = try presenter.open(isCurrent: { true })
    try await recovery.open()
    let intent = try #require(f.host.pendingOperation?.intent)
    #expect(!recovery.hasPhoto && f.host.presentation == nil && !f.host.canSubmit)
    await #expect(throws: GatewayAvatarReportHostFailure.displayRequired) {
        try await recovery.refreshPhoto()
    }
    await f.api.set(.accepted)
    try await recovery.recover()
    try await recovery.acknowledgeResult(#require(f.host.resolution))
    #expect(f.host.pendingOperation == nil)
    #expect(await f.api.identities == [intent, intent])
}
@Test @MainActor
func avatarReportDeletionFenceInvalidatesPresenterAndWithholdsLateACKWithoutErasingOtherOwner() async throws {
    let f = try await PhotoReportHostFixture()
    defer { f.close() }
    let other = try photoStoreScope(account: "67000000-0000-4000-8000-000000000002")
    let otherJournal = GatewayAvatarReportJournal(storage: f.storage)
    let otherLease = try await otherJournal.open(scope: other)
    let otherEntry = try await otherJournal.prepare(photoStoreIntent(other), lease: otherLease)
    let (_, photo, _) = try await f.show()
    let presenter = GatewayAvatarReportPresenter(host: f.host)
    let session = try presenter.open(photo: photo, isCurrent: { true })
    try await session.open()
    let shown = try #require(f.host.presentation)
    _ = try #require(f.host.image(for: shown))
    try f.host.acknowledgeDisplay(shown)
    await f.api.gate.arm()
    let work = Task { try await session.submit(reason: "PRIVATE", presentation: shown) }
    try await f.api.gate.wait()
    let native = try #require(f.avatar.photo.source.communityAuthorization)
    presenter.invalidate()
    try f.journal.fenceForAccountDeletion(
        binding: native.identity.binding, accountID: native.identity.accountID)
    await f.api.gate.release()
    _ = await work.result
    #expect(!session.isCurrent && f.host.outcome == nil && !f.host.isConnected)
    let owner = try #require(f.avatar.photo.source.privateDataScope(configuration: f.avatar.photo.cloudKit))
    try await f.journal.erase(owner: owner)
    #expect(f.storage.records.count == 1 && f.storage.records[other.storageIdentifier] != nil)
    #expect(try await otherJournal.pending(lease: otherLease) == otherEntry)
}
