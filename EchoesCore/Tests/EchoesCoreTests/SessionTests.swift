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
    var profiles: [NearbyProfile] = []
    func connect() async throws -> String { "viewer" }
    func configuration() async throws -> URL? { nil }
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
        return stopCount
    }
    func nearby(coordinate: Coordinate) async throws -> [NearbyProfile] {
        await onNearby?()
        return profiles
    }
    func messages(coordinate: Coordinate, cursor: String?, knownIDs: [String]) async throws
        -> MessagePage
    {
        messageReads += 1
        return .init(messages: [], nextCursor: nil)
    }
    func send(text: String, name: String, coordinate: Coordinate, requestID: String) async throws
        -> ChatMessage
    {
        sendIDs.append(requestID)
        if sendFails { throw ValidationError.message }
        return .init(
            id: requestID, text: text, senderName: name, senderID: "viewer",
            timestamp: Date().timeIntervalSince1970 * 1000,
            expiresAt: Date().addingTimeInterval(7200).timeIntervalSince1970 * 1000)
    }
    func block(userID: String, blocked: Bool) async throws {}
    func blockedUsers() async throws -> [String] { [] }
    func report(messageID: String, reason: String) async throws {}
    func deleteOwnData() async throws {}
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
    #expect(session.users.isEmpty)
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
    #expect(session.users.isEmpty)
}
