import Foundation
import Testing

@testable import EchoesCloudKit

@MainActor private struct PublicationEditorFixture {
    let owner: OwnerFlowFixture
    let clock: OwnerPreviewClock
    let api: OwnerPreviewHostAPI
    let preview: GatewayAvatarOwnerPreviewHost
    let editor: GatewayAvatarEditorHost
    init() throws {
        owner = try .init()
        let wire = try OwnerPreviewWireFixture()
        clock = .init(wire.now)
        api = .init(fixture: wire, clock: clock, origin: owner.configuration.origin.absoluteString)
        preview = try .init(
            api: api, configuration: owner.configuration, cloudKit: owner.cloudKit,
            authorization: owner.authorization, isEnabled: { [owner] in owner.flags.enabled },
            date: { [clock] in clock.date() }, uptime: { [clock] in clock.up() })
        editor = try .init(
            controller: owner.controller, cloudKit: owner.cloudKit, authorization: owner.authorization,
            ownerPreview: preview, isEnabled: { [owner] in owner.flags.enabled })
    }
    func open() throws -> GatewayAvatarEditorSession {
        let session = try editor.open(isCurrent: { true })
        session.setForeground(true)
        return session
    }
    func approved() async throws -> GatewayAvatarEditorSession {
        await owner.api.set(try .init(data: JSONSerialization.data(withJSONObject: mutationBody(.approved))))
        let session = try open()
        await session.perform(.refresh)
        #expect(session.pendingOperation == nil && session.snapshot?.status == .approved)
        return session
    }
    func show(_ session: GatewayAvatarEditorSession, acknowledge: Bool = true) async throws
        -> GatewayAvatarOwnerPreviewPresentation
    {
        await session.loadPublicationPreview()
        let handle = try #require(session.publicationPresentation)
        #expect(session.publicationImage(for: handle) != nil)
        if acknowledge { try session.acknowledgePublicationDisplay(handle) }
        return handle
    }
    func cleanup() {
        editor.invalidate()
        owner.cleanup()
    }
}

@Test @MainActor func publicationEditorWithoutJournalNeedsImageDisplayAndSeparateExactConfirmation()
    async throws
{
    let f = try PublicationEditorFixture()
    defer { f.cleanup() }
    let session = try await f.approved()
    #expect(session.canLoadPublicationPreview && !session.canPublish)
    let handle = try await f.show(session, acknowledge: false)
    await session.confirmPublication(handle)
    #expect(await f.owner.actions() == ["status"] && session.pendingOperation == nil)
    try session.acknowledgePublicationDisplay(handle)
    #expect(session.canPublish)
    await session.perform(.publish)  // The old generic entry point cannot bypass the dedicated confirmation.
    #expect(await f.owner.actions() == ["status"])
    let selected = try GatewayAvatarPublishIntent(snapshot: #require(session.snapshot))
    await session.confirmPublication(handle)
    #expect(session.snapshot?.status == .published && session.pendingOperation == nil)
    #expect(session.publicationImage(for: handle) == nil && !session.canPublish)
    let published = await f.owner.api.captured().compactMap { call -> GatewayAvatarPublishIntent? in
        if case .publish(let intent) = call.action { return intent }
        return nil
    }
    #expect(published == [selected])
    await session.confirmPublication(handle)
    #expect(await f.owner.actions() == ["status", "status", "publish"])
}

@Test @MainActor func publicationEditorRefreshRequiresNewImageAndAckEvenWhenSelectionIsUnchanged()
    async throws
{
    let f = try PublicationEditorFixture()
    defer { f.cleanup() }
    let session = try await f.approved()
    let old = try await f.show(session)
    await session.perform(.refresh)
    #expect(
        session.publicationPresentation == nil && session.publicationImage(for: old) == nil
            && !session.canPublish)
    await session.confirmPublication(old)
    #expect(await f.owner.actions() == ["status", "status"])
    let fresh = try await f.show(session, acknowledge: false)
    #expect(fresh != old && !session.canPublish)
    try session.acknowledgePublicationDisplay(fresh)
    #expect(session.canPublish)
}

@Test @MainActor func publicationEditorNewServerReviewCannotReplacePreviouslyConfirmedSelection() async throws
{
    let f = try PublicationEditorFixture()
    defer { f.cleanup() }
    let session = try await f.approved()
    let handle = try await f.show(session)
    try await f.owner.api.review(.approved)
    await session.confirmPublication(handle)
    #expect(await f.owner.actions() == ["status", "status"])
    #expect(session.pendingOperation == nil && session.publicationPresentation == nil && !session.canPublish)
    #expect(session.errorMessage != nil)
}

@Test @MainActor func publicationEditorUnknownResultRecoversReadOnlyAndRetryNeedsNewDisplayAndConfirmation()
    async throws
{
    let f = try PublicationEditorFixture()
    defer { f.cleanup() }
    let session = try await f.approved()
    let first = try await f.show(session)
    let selected = try GatewayAvatarPublishIntent(snapshot: #require(session.snapshot))
    await f.owner.api.fail("publish", .beforeAccept)
    await session.confirmPublication(first)
    let pending = try #require(session.pendingOperation)
    #expect(pending.intent == .publish(selected) && pending.phase == .publishing && !pending.hasSource)
    #expect(session.publicationImage(for: first) == nil && !session.canPublish)
    await session.perform(.recover)
    #expect(
        session.pendingOperation == pending && !session.canDiscardPending && session.canLoadPublicationPreview
    )
    await session.perform(.publish)
    #expect(await f.owner.actions() == ["status", "status", "publish", "status"])
    let retry = try await f.show(session)
    await session.confirmPublication(retry)
    #expect(session.snapshot?.status == .published && session.pendingOperation == nil)
    let publications = await f.owner.api.captured().compactMap { call -> GatewayAvatarPublishIntent? in
        if case .publish(let intent) = call.action { return intent }
        return nil
    }
    #expect(publications == [selected, selected])
}

@Test @MainActor func publicationEditorExpiryDoesNotPollAndOldConfirmationCannotPublish() async throws {
    let f = try PublicationEditorFixture()
    defer { f.cleanup() }
    let session = try await f.approved()
    let handle = try await f.show(session)
    f.clock.move(wall: 30_000, monotonic: 30)
    #expect(session.publicationPresentation == nil && !session.canPublish)
    await session.confirmPublication(handle)
    #expect(await f.owner.actions() == ["status"])
    #expect(await f.api.count() == 1)
    #expect(session.canLoadPublicationPreview && session.pendingOperation == nil)
}

@Test @MainActor func publicationEditorClosedConfirmationKeepsBusyUntilTokenIOActuallyReturns() async throws {
    let f = try PublicationEditorFixture()
    defer { f.cleanup() }
    let session = try await f.approved()
    let handle = try await f.show(session)
    await f.owner.authorization.gate.arm()
    let confirmation = Task { await session.confirmPublication(handle) }
    try await f.owner.authorization.gate.wait()
    session.setForeground(false)
    let fresh = try f.open()
    #expect(fresh.isBusy && !session.isCurrent && session.publicationImage(for: handle) == nil)
    await f.owner.authorization.gate.release()
    await confirmation.value
    #expect(!fresh.isBusy && fresh.publicationPresentation == nil && !fresh.canPublish)
    #expect(await f.owner.actions() == ["status"])
}

@Test @MainActor func publicationEditorDelayedPreviewCannotPopulateNewSessionAfterClose() async throws {
    let f = try PublicationEditorFixture()
    defer { f.cleanup() }
    let old = try await f.approved()
    await f.api.gate.arm()
    let reading = Task { await old.loadPublicationPreview() }
    try await f.api.gate.wait()
    old.close()
    let fresh = try f.open()
    #expect(fresh.isBusy && !old.isCurrent)
    await f.api.gate.release()
    await reading.value
    await fresh.perform(.refresh)
    #expect(fresh.isCurrent && fresh.publicationPresentation == nil && !fresh.canPublish)
    _ = try await f.show(fresh)
    #expect(fresh.canPublish)
}

@Test @MainActor func publicationEditorCurrentPrivateScopeIsCheckedBeforeEveryImageAndConfirmation()
    async throws
{
    let f = try PublicationEditorFixture()
    defer { f.cleanup() }
    let session = try await f.approved()
    let handle = try await f.show(session)
    f.owner.authorization.cloudName = "different-private-icloud"
    #expect(!session.isCurrent && session.publicationImage(for: handle) == nil && !session.canPublish)
    await session.confirmPublication(handle)
    #expect(await f.owner.actions() == ["status"])
}

@Test @MainActor func publicationEditorPreviewContextDoesNotRetainClosedViewOrEditorHost() async throws {
    let f = try PublicationEditorFixture()
    defer { f.cleanup() }
    await f.owner.api.set(try .init(data: JSONSerialization.data(withJSONObject: mutationBody(.approved))))
    var host: GatewayAvatarEditorHost? = try .init(
        controller: f.owner.controller, cloudKit: f.owner.cloudKit,
        authorization: f.owner.authorization, ownerPreview: f.preview, isEnabled: { true })
    var session = try host?.open(isCurrent: { true })
    session?.setForeground(true)
    await session?.perform(.refresh)
    await session?.loadPublicationPreview()
    #expect(session?.publicationPresentation != nil)
    weak var weakHost = host
    weak var weakSession = session
    session = nil
    host = nil
    #expect(weakSession == nil && weakHost == nil)
    #expect(f.preview.presentation == nil)
}

@Test @MainActor func publicationEditorUnsentLocalDraftDoesNotAuthorizeOlderServerPhoto() async throws {
    let f = try PublicationEditorFixture()
    defer { f.cleanup() }
    let session = try await f.approved()
    await session.prepare { f.owner.avatar }
    #expect(session.preview != nil && !session.canLoadPublicationPreview && !session.canPublish)
    await session.loadPublicationPreview()
    #expect(session.publicationPresentation == nil)
    #expect(await f.api.count() == 0)
    session.discardSelection()
    #expect(session.canLoadPublicationPreview)
    _ = try await f.show(session)
    #expect(session.canPublish)
}
