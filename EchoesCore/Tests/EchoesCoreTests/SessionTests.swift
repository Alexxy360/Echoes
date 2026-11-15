import Foundation
import Testing

@testable import EchoesCore

@MainActor
private final class MockClient: CommunityClient {
    var serverTimeOffset: TimeInterval = 0
    var sendFails = false
    var sendIDs: [String] = []
    var publishCount = 0
    var stopCount = 0
    var messageReads = 0
    var onPublish: (() async -> Void)?
    var onNearby: (() async -> Void)?
    var onConfiguration: (() async -> Void)?
    var onSend: (() async -> Void)?
    var onStop: (() async -> Void)?
    var uid = "viewer"
    var blockReads = 0
    var deleteCalls = 0
    var pending: PendingCommunityMessage?
    var page = MessagePage(messages: [], nextCursor: nil)
    var pageExpired = false
    var profiles: [NearbyProfile] = []
    func connect() async throws -> String { uid }
    func configuration() async throws -> URL? {
        await onConfiguration?()
        return nil
    }
    func visibilityGeneration() async throws -> Int { stopCount }
    func publish(
        name: String, coordinate: Coordinate, measuredAt: Date, song: String, songID: String,
        generation: Int
    ) async throws {
        publishCount += 1
        await onPublish?()
    }
    func stopSharing() async throws -> Int {
        stopCount += 1
        let result = stopCount
        await onStop?()
        return result
    }
    func nearby(coordinate: Coordinate) async throws -> [NearbyProfile] {
        await onNearby?()
        return profiles
    }
    func messages(coordinate: Coordinate, cursor: String?, knownIDs: [String]) async throws
        -> MessagePage
    {
        messageReads += 1
        if pageExpired { throw CommunityPageFailure.cursorExpired }
        return page
    }
    func send(text: String, name: String, coordinate: Coordinate, requestID: String) async throws
        -> ChatMessage
    {
        sendIDs.append(requestID)
        await onSend?()
        if sendFails { throw ValidationError.message }
        return .init(
            id: requestID, text: text, senderName: name, senderID: "viewer",
            timestamp: Date().timeIntervalSince1970 * 1000,
            expiresAt: Date().addingTimeInterval(7200).timeIntervalSince1970 * 1000)
    }
    func block(userID: String, blocked: Bool) async throws {}
    func blockedUsers() async throws -> [String] {
        blockReads += 1
        return []
    }
    func report(messageID: String, reason: String) async throws {}
    func deleteOwnData() async throws { deleteCalls += 1 }
    func pendingMessage() throws -> PendingCommunityMessage? { pending }
    func forgetPendingMessage(_ expected: PendingCommunityMessage) throws {
        guard pending == expected else { throw PendingMessageFailure.changed }
        pending = nil
    }
}

@MainActor
private final class Clock {
    var date = Date()
    var fix: LocationFix {
        .init(coordinate: .init(latitude: 51.11, longitude: 17.03), accuracy: 10, measuredAt: date)
    }
}

@MainActor @Test func failedSendPreservesDraftAndRetryReusesIdempotencyKey() async {
    let client = MockClient()
    let tested = CommunitySession(client: client)
    await tested.connect(name: "Gość")
    await tested.setForeground(true)
    tested.updateLocation(Clock().fix)
    tested.draft = "Ważna wiadomość"
    client.sendFails = true
    #expect(await tested.sendDraft() == false)
    #expect(tested.draft == "Ważna wiadomość")
    client.sendFails = false
    #expect(await tested.sendDraft())
    #expect(tested.draft.isEmpty)
    #expect(client.sendIDs.count == 2 && client.sendIDs[0] == client.sendIDs[1])
}

@MainActor @Test func noLocationDoesNotDropTextOrInvokeSend() async {
    let client = MockClient()
    let tested = CommunitySession(client: client)
    await tested.connect(name: "Gość")
    await tested.setForeground(true)
    tested.draft = "Zachowaj mnie"
    #expect(await tested.sendDraft() == false)
    #expect(tested.draft == "Zachowaj mnie")
    #expect(client.sendIDs.isEmpty)
}

@MainActor @Test func enteringAndReadingNeverPublishesWithoutOptIn() async {
    let client = MockClient()
    let clock = Clock()
    let session = CommunitySession(client: client, now: { clock.date })
    await session.connect(name: "Gość")
    await session.setForeground(true)
    session.updateLocation(clock.fix)
    await session.tick()
    #expect(!session.isSharing)
    #expect(client.publishCount == 0)
    await session.setSharing(true)
    #expect(session.isSharing && client.publishCount == 1)
    await session.setForeground(false)
    #expect(!session.isSharing)
    await session.setForeground(true)
    await session.tick()
    #expect(client.publishCount == 1)
}

@MainActor @Test func musicUpdatesWithoutChangingLocation() async {
    let client = MockClient()
    let clock = Clock()
    let session = CommunitySession(client: client, now: { clock.date })
    await session.connect(name: "Gość")
    await session.setForeground(true)
    session.updateLocation(clock.fix)
    await session.setSharing(true)
    clock.date.addTimeInterval(6)
    session.updateTrack(title: "Inny utwór", id: "123")
    await session.tick()
    #expect(client.publishCount == 2)
}

@MainActor @Test func lateLocationStartsChatAndOldAreaResponsesAreDiscarded() async {
    let client = MockClient()
    let clock = Clock()
    let session = CommunitySession(client: client, now: { clock.date })
    await session.connect(name: "Gość")
    await session.setForeground(true)
    session.isChatOpen = true
    await session.refreshMessages()
    #expect(client.messageReads == 0)
    session.updateLocation(clock.fix)
    await session.tick()
    #expect(client.messageReads == 1)
    client.profiles = [
        .init(
            id: "other", name: "Maja", coordinate: clock.fix.coordinate,
            lastSong: "", appleMusicID: "",
            expiresAt: clock.date.addingTimeInterval(600).timeIntervalSince1970 * 1000)
    ]
    client.onNearby = {
        session.updateLocation(
            .init(
                coordinate: .init(latitude: 52.23, longitude: 21.01), accuracy: 10, measuredAt: clock.date))
    }
    await session.refreshUsers()
    #expect(session.users.isEmpty)
}

@MainActor @Test func expiredProfilesDisappearWithoutSnapshotOrNetwork() async {
    let client = MockClient()
    let clock = Clock()
    let session = CommunitySession(client: client, now: { clock.date })
    await session.connect(name: "Gość")
    await session.setForeground(true)
    session.updateLocation(clock.fix)
    client.profiles = [
        .init(
            id: "other", name: "Maja", coordinate: clock.fix.coordinate,
            lastSong: "", appleMusicID: "",
            expiresAt: clock.date.addingTimeInterval(1).timeIntervalSince1970 * 1000)
    ]
    await session.refreshUsers()
    #expect(session.users.count == 1)
    clock.date.addTimeInterval(2)
    session.expireCached()
}

@MainActor @Test func backgroundDuringVisibilityRequestCannotTurnSharingBackOn() async {
    let client = MockClient()
    let clock = Clock()
    let session = CommunitySession(client: client, now: { clock.date })
    await session.connect(name: "Gość")
    await session.setForeground(true)
    session.updateLocation(clock.fix)
    client.onPublish = { await session.setForeground(false) }
    await session.setSharing(true)
    #expect(!session.isSharing && !session.isForeground)
    #expect(client.stopCount >= 2)
}

@MainActor @Test func serverClockOffsetKeepsExpiryCorrectWhenDeviceClockIsWrong() async {
    let client = MockClient()
    let clock = Clock()
    let actualNow = clock.date
    clock.date.addTimeInterval(3600)
    client.serverTimeOffset = -3600
    let session = CommunitySession(client: client, now: { clock.date })
    await session.connect(name: "Gość")
    await session.setForeground(true)
    session.updateLocation(clock.fix)
    client.profiles = [
        .init(
            id: "other", name: "Maja", coordinate: clock.fix.coordinate,
            lastSong: "", appleMusicID: "",
            expiresAt: actualNow.addingTimeInterval(10).timeIntervalSince1970 * 1000)
    ]
    await session.refreshUsers()
    #expect(session.users.count == 1)
    clock.date.addTimeInterval(11)
    session.expireCached()
}

@MainActor @Test func oldConnectCannotRunMoreRequestsOrReplaceANewlyConnectedAccount() async {
    let client = MockClient()
    let tested = CommunitySession(client: client)
    client.onConfiguration = {
        client.onConfiguration = nil
        tested.invalidateForAccountChange()
        client.uid = "new-viewer"
        await tested.connect(name: "Nowy")
    }
    await tested.connect(name: "Poprzedni")
    #expect(tested.userID == "new-viewer" && tested.name == "Nowy" && tested.phase == .ready)
    #expect(client.blockReads == 1 && client.stopCount == 2)
}

@MainActor @Test func oldSendCannotClearTheDraftOrPopulateTheTimelineAfterSameAccountReconnection() async {
    let client = MockClient()
    let clock = Clock()
    let session = CommunitySession(client: client)
    await session.connect(name: "Gość")
    await session.setForeground(true)
    session.updateLocation(clock.fix)
    session.draft = "Stara treść"
    client.onSend = {
        client.onSend = nil
        session.invalidateForAccountChange()
        await session.connect(name: "Gość")
        await session.setForeground(true)
        session.updateLocation(clock.fix)
        session.draft = "Nowy szkic"
    }
    #expect(await session.sendDraft() == false)
    #expect(session.draft == "Nowy szkic" && session.messages.isEmpty && !session.isSending)
}

@MainActor @Test func oldNearbyResponseCannotSurviveBackgroundForegroundABA() async {
    let client = MockClient()
    let clock = Clock()
    let tested = CommunitySession(client: client)
    await tested.connect(name: "Gość")
    await tested.setForeground(true)
    tested.updateLocation(clock.fix)
    client.profiles = [
        .init(
            id: "near", name: "Maja", coordinate: clock.fix.coordinate, lastSong: "", appleMusicID: "",
            expiresAt: clock.date.addingTimeInterval(600).timeIntervalSince1970 * 1000)
    ]
    client.onNearby = {
        await tested.setForeground(false)
        await tested.setForeground(true)
    }
    await tested.refreshUsers()
    #expect(tested.users.isEmpty && !tested.didLoadUsers)
}

@MainActor @Test func movementWhileSendingDoesNotInsertTheOldAreasAcknowledgementInTheNewTimeline() async {
    let client = MockClient()
    let clock = Clock()
    let tested = CommunitySession(client: client)
    await tested.connect(name: "Gość")
    await tested.setForeground(true)
    tested.updateLocation(clock.fix)
    tested.draft = "Treść"
    client.onSend = {
        tested.updateLocation(
            .init(coordinate: .init(latitude: 52, longitude: 21), accuracy: 10, measuredAt: clock.date))
    }
    #expect(await tested.sendDraft())
    #expect(tested.draft.isEmpty && tested.messages.isEmpty)
}

@MainActor @Test func deletionDoesNotDispatchAgainstAnAccountConnectedWhilePrivacyCleanupWasAwaited() async {
    let client = MockClient()
    let clock = Clock()
    let session = CommunitySession(client: client)
    await session.connect(name: "Gość")
    await session.setForeground(true)
    session.updateLocation(clock.fix)
    await session.setSharing(true)
    client.onStop = {
        client.onStop = nil
        session.invalidateForAccountChange()
        client.uid = "new-viewer"
        await session.connect(name: "Nowy")
    }
    #expect(await session.deleteOwnData() == false)
    #expect(client.deleteCalls == 0 && session.userID == "new-viewer" && session.name == "Nowy")
}

@MainActor @Test func pendingMessageRecoveryUsesItsOriginalFieldsAndPreservesAnEditedNewDraft() async {
    let client = MockClient()
    let clock = Clock()
    client.pending = .init(
        requestID: "old-request", name: "Poprzednia nazwa", text: "Poprzednia treść",
        coordinate: clock.fix.coordinate, recoveryID: "snapshot")
    let session = CommunitySession(client: client)
    await session.connect(name: "Nowa nazwa")
    await session.setForeground(true)
    session.updateLocation(clock.fix)
    #expect(session.draft == "Poprzednia treść" && session.pendingMessage == client.pending)
    session.draft = "Nowy szkic"
    #expect(await session.sendDraft() == false)
    #expect(client.sendIDs.isEmpty)
    client.onSend = { client.pending = nil }
    #expect(await session.retryPendingMessage())
    #expect(client.sendIDs == ["old-request"])
    #expect(session.draft == "Nowy szkic" && session.pendingMessage == nil)
}

@MainActor @Test func forgettingAPendingMessageRequiresTheDisplayedSnapshotAndPreservesDraftAndServer()
    async throws
{
    let client = MockClient()
    let clock = Clock()
    let pending = PendingCommunityMessage(
        requestID: "id", name: "Maja", text: "Treść", coordinate: clock.fix.coordinate, recoveryID: "snapshot"
    )
    client.pending = pending
    let session = CommunitySession(client: client)
    await session.connect(name: "Maja")
    session.draft = "Nowy szkic"
    let old = PendingCommunityMessage(
        requestID: "id", name: "Maja", text: "Treść", coordinate: clock.fix.coordinate, recoveryID: "old")
    #expect(throws: PendingMessageFailure.changed) { try session.forgetPendingMessage(old) }
    try session.forgetPendingMessage(pending)
    #expect(
        session.draft == "Nowy szkic" && session.pendingMessage == nil && client.pending == nil
            && client.sendIDs.isEmpty && client.deleteCalls == 0)
}

@MainActor @Test func anExpiredPageCursorCanBeReplacedByTheNextFreshRead() async {
    let client = MockClient()
    let clock = Clock()
    let tested = CommunitySession(client: client)
    await tested.connect(name: "Maja")
    await tested.setForeground(true)
    tested.updateLocation(clock.fix)
    tested.isChatOpen = true
    client.page = .init(messages: [], nextCursor: "old")
    await tested.refreshMessages()
    #expect(tested.nextCursor == "old")
    client.pageExpired = true
    await tested.refreshMessages(older: true)
    #expect(tested.nextCursor == nil && !tested.didLoadMessages)
    client.pageExpired = false
    client.page = .init(messages: [], nextCursor: "fresh")
    await tested.refreshMessages()
    #expect(tested.nextCursor == "fresh" && tested.didLoadMessages)
}

@MainActor @Test func retryingAnOlderAreasPendingMessageDoesNotEchoItInTheCurrentArea() async {
    let client = MockClient()
    let clock = Clock()
    client.pending = .init(
        requestID: "old-area", name: "Maja", text: "Treść", coordinate: .init(latitude: 52, longitude: 21),
        recoveryID: "snapshot")
    let tested = CommunitySession(client: client)
    await tested.connect(name: "Maja")
    await tested.setForeground(true)
    tested.updateLocation(clock.fix)
    client.onSend = { client.pending = nil }
    #expect(await tested.sendDraft())
    #expect(tested.draft.isEmpty && tested.messages.isEmpty)
}
