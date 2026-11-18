import Foundation
import Observation
import Testing

@testable import EchoesCloudKit

@MainActor private func editorHost(_ f: OwnerFlowFixture) throws -> GatewayAvatarEditorHost {
    let wire = try OwnerPreviewWireFixture()
    let clock = OwnerPreviewClock(wire.now)
    let api = OwnerPreviewHostAPI(fixture: wire, clock: clock, origin: f.configuration.origin.absoluteString)
    return try .init(
        controller: f.controller, cloudKit: f.cloudKit, authorization: f.authorization,
        ownerPreview: GatewayAvatarOwnerPreviewHost(
            api: api, configuration: f.configuration, cloudKit: f.cloudKit, authorization: f.authorization,
            isEnabled: { f.flags.enabled }, date: { clock.date() }, uptime: { clock.up() }),
        isEnabled: { f.flags.enabled })
}

@Test @MainActor func avatarEditorMetadataPublicationStaysClosedUntilAuthorPreviewButAllowsRecoveryAndClear()
    async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    await f.api.set(
        try GatewayAvatarOwnerSnapshot(data: JSONSerialization.data(withJSONObject: mutationBody(.approved))))
    let host = try editorHost(f)
    let session = try host.open(isCurrent: { true })
    await session.perform(.refresh)
    #expect(session.snapshot?.status == .approved && session.pendingOperation == nil)
    #expect(!session.canPublish)
    await session.perform(.publish)
    #expect(await f.actions() == ["status"])
    // Trusted controller caller models the future preview, without claiming UI acceptance here.
    await f.api.fail("publish", .beforeAccept)
    await #expect(throws: GatewayAvatarMutationFailure.unavailable) { try await f.controller.publish() }
    let pending = try #require(session.pendingOperation)
    guard case .publish = pending.intent else {
        Issue.record("Expected saved publication")
        return
    }
    #expect(session.canRecover && !session.canRetryUpload && !session.canPublish && !session.canChoosePhoto)
    await session.perform(.recover)
    #expect(session.pendingOperation == pending && !session.canDiscardPending)
    await session.perform(.clear)
    #expect(session.pendingOperation == nil && session.snapshot?.status == GatewayAvatarOwnerStatus.none)
}
@Test @MainActor func avatarEditorSelectionDoesNotUploadAndConsentIsBoundToTheExactDraft() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let host = try editorHost(f)
    let session = try host.open(isCurrent: { true })
    await session.perform(.refresh)
    await session.prepare { f.avatar }
    let first = try #require(session.selectionID)
    #expect(session.preview != nil && !session.consentAccepted && !session.canSubmit)
    #expect(await f.actions() == ["status"])
    await session.perform(.submit)
    #expect(await f.actions() == ["status"])
    session.consent(true, for: first)
    #expect(session.canSubmit)
    await session.prepare { f.avatar }
    let second = try #require(session.selectionID)
    session.consent(true, for: first)
    #expect(second != first && !session.consentAccepted && !session.canSubmit)
    session.consent(true, for: second)
    await session.perform(.submit)
    #expect(session.preview == nil && !session.consentAccepted && session.pendingOperation?.phase == .staged)
    #expect(!session.canPublish && !session.canChoosePhoto)
    try await f.api.review(.approved)
    await session.perform(.refresh)
    session.setForeground(true)
    #expect(!session.canPublish)
    await session.loadPublicationPreview()
    let approved = try #require(session.publicationPresentation)
    try session.acknowledgePublicationDisplay(approved)
    #expect(session.canPublish)
    await session.perform(.publish)
    #expect(session.snapshot?.status == .approved)
    await session.confirmPublication(approved)
    #expect(session.snapshot?.status == .published && session.pendingOperation == nil)
}
@Test @MainActor func avatarEditorOldSheetCannotReadOrCloseANewerSheet() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let host = try editorHost(f)
    let old = try host.open(isCurrent: { true })
    await old.perform(.refresh)
    await old.prepare { f.avatar }
    old.consent(true, for: try #require(old.selectionID))
    let fresh = try host.open(isCurrent: { true })
    await fresh.perform(.refresh)
    await fresh.prepare { f.avatar }
    old.close()
    await old.perform(.clear)
    #expect(!old.isCurrent && old.preview == nil && !old.consentAccepted && old.snapshot == nil)
    #expect(fresh.isCurrent && fresh.preview != nil && fresh.canChoosePhoto)
    #expect(await f.actions() == ["status", "status"])
}
@Test @MainActor func avatarEditorDomainAndICloudChangeHideDraftImmediatelyBeforeExplicitClose() async throws
{
    for change in 0..<2 {
        let f = try OwnerFlowFixture()
        defer { f.cleanup() }
        let domain = OwnerFlowFlags()
        let host = try editorHost(f)
        let session = try host.open(isCurrent: { domain.enabled })
        await session.perform(.refresh)
        await session.prepare { f.avatar }
        if change == 0 { domain.enabled = false } else { f.authorization.cloudName = "other-icloud" }
        #expect(
            !session.isCurrent && session.preview == nil && session.selectionID == nil
                && session.snapshot == nil)
        await session.perform(.submit)
        #expect(await f.actions() == ["status"])
        host.invalidate()
    }
}
@Test @MainActor func avatarEditorUnsettledPreparationKeepsGlobalSlotAndCannotPopulateANewAccount()
    async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let host = try editorHost(f)
    let old = try host.open(isCurrent: { true })
    await old.perform(.refresh)
    let gate = PhotoGate()
    await gate.arm()
    let operation = Task {
        await old.prepare {
            await gate.enter()
            return f.avatar
        }
    }
    try await gate.wait()
    old.close()
    try f.authorization.select("6b000000-0000-4000-8000-000000000002")
    let fresh = try host.open(isCurrent: { true })
    #expect(fresh.isBusy)
    await fresh.perform(.refresh)
    #expect(await f.actions() == ["status"])
    await gate.release()
    await operation.value
    #expect(!fresh.isBusy && fresh.preview == nil && old.preview == nil)
    await fresh.perform(.refresh)
    await fresh.prepare { f.avatar }
    #expect(fresh.preview != nil && !fresh.consentAccepted)
    #expect((await f.api.captured()).last?.account == "6b000000-0000-4000-8000-000000000002")
}
@Test @MainActor func avatarEditorCancellationAndUnknownProviderFailureNeverExposePrivateDetails()
    async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let host = try editorHost(f)
    let session = try host.open(isCurrent: { true })
    await session.perform(.refresh)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await session.prepare { f.avatar }
    }
    await cancelled.value
    #expect(session.preview == nil && session.errorMessage == nil)
    await session.prepare { throw NSError(domain: "PRIVATE-PROVIDER-FILE-URL", code: 1) }
    #expect(session.preview == nil && session.errorMessage != nil)
    #expect(session.errorMessage?.contains("PRIVATE-PROVIDER") == false)
    #expect(await f.actions() == ["status"])
}
@Test @MainActor func avatarEditorCurrentAndConsentAreRecheckedWhenUploadIsRequestedDirectly() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let host = try editorHost(f)
    let session = try host.open(isCurrent: { true })
    await session.perform(.refresh)
    await session.prepare { f.avatar }
    await session.perform(.submit)
    #expect(session.errorMessage != nil && session.preview != nil)
    #expect(await f.actions() == ["status"])
    session.discardSelection()
    #expect(session.preview == nil && session.selectionID == nil && !session.consentAccepted)
    await session.perform(.submit)
    #expect(await f.actions() == ["status"])
}
@Test @MainActor func avatarEditorLateNetworkReplyCannotRestoreAnotherEditorsDraftOrSnapshot() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let host = try editorHost(f)
    let old = try host.open(isCurrent: { true })
    await old.perform(.refresh)
    await old.prepare { f.avatar }
    old.consent(true, for: try #require(old.selectionID))
    await f.api.pause("upload")
    let upload = Task { await old.perform(.submit) }
    try await f.api.gate.wait()
    old.close()
    try f.authorization.select("6b000000-0000-4000-8000-000000000002")
    let fresh = try host.open(isCurrent: { true })
    #expect(fresh.isBusy && old.preview == nil)
    await f.api.gate.release()
    await upload.value
    await fresh.perform(.refresh)
    #expect(fresh.snapshot?.generation == 0 && fresh.pendingOperation == nil && fresh.preview == nil)
    #expect(old.snapshot == nil && old.pendingOperation == nil)
}
@Test @MainActor func avatarEditorUnknownWriteConsumesDraftButPreservesRecoverableJournal() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let host = try editorHost(f)
    let session = try host.open(isCurrent: { true })
    await session.perform(.refresh)
    await session.prepare { f.avatar }
    session.consent(true, for: try #require(session.selectionID))
    await f.journal.fail(prepare: true)
    await session.perform(.submit)
    #expect(
        session.preview == nil && !session.consentAccepted && session.needsRefresh && !session.canChoosePhoto)
    let saved = try #require(await f.journal.read())
    await f.journal.fail()
    await session.perform(.refresh)
    #expect(session.pendingOperation == saved && session.canRetryUpload && session.canDiscardPending)
    await session.perform(.discardUnsentOrSuperseded)
    #expect(session.pendingOperation == nil && session.canChoosePhoto)
}
@Test @MainActor func avatarEditorInvalidThumbnailCannotBecomeAPreviewOrConsentTarget() async throws {
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let host = try editorHost(f)
    let session = try host.open(isCurrent: { true })
    await session.perform(.refresh)
    await session.prepare { PreparedAvatar(image: f.avatar.image, thumbnail: Data([1, 2])) }
    #expect(
        session.preview == nil && session.selectionID == nil && session.errorMessage != nil
            && !session.canSubmit)
}
@Test @MainActor func avatarEditorDefaultInactiveHostDoesNotInvalidateAnAlreadyConnectedController()
    async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    try await f.controller.connect()
    let host = try GatewayAvatarEditorHost(
        controller: f.controller, cloudKit: f.cloudKit, authorization: f.authorization)
    #expect(throws: GatewayFailure.signInRequired) { try host.open(isCurrent: { true }) }
    #expect(f.controller.isConnected)
}
@Test @MainActor func avatarEditorClosingAndReopeningDropsConsentButRestoresThePendingOperation() async throws
{
    let f = try OwnerFlowFixture()
    defer { f.cleanup() }
    let host = try editorHost(f)
    let old = try host.open(isCurrent: { true })
    await old.perform(.refresh)
    await old.prepare { f.avatar }
    old.consent(true, for: try #require(old.selectionID))
    await f.api.fail("upload", .lostReply)
    await old.perform(.submit)
    let saved = try #require(await f.journal.read())
    old.close()
    let fresh = try host.open(isCurrent: { true })
    await fresh.perform(.refresh)
    #expect(fresh.pendingOperation?.intent == saved.intent && fresh.pendingOperation?.phase == .staged)
    #expect(fresh.preview == nil && !fresh.consentAccepted && !fresh.canPublish)
    await fresh.perform(.clear)
    #expect(fresh.pendingOperation == nil && fresh.canChoosePhoto)
}
