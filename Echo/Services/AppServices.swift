import CoreLocation
import EchoesCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AppServices {
    let session: CommunitySession
    let location = LocationService()
    let music = MusicService()
    private let preferences: UserDefaults?
    private let demo: Bool
    let isGatewayDevelopment: Bool
    private let isCurrent: @MainActor () -> Bool
    private let simulatedCoordinate: Coordinate?
    private(set) var hasAcceptedPrivacy: Bool
    private(set) var savedName: String

    init(
        client: (any CommunityClient)? = nil, preferences: UserDefaults = .standard, demo: Bool = false
    ) {
        self.preferences = preferences
        self.demo = demo
        isGatewayDevelopment = false
        isCurrent = { true }
        simulatedCoordinate = demo ? PreviewCommunityClient.center : nil
        session = CommunitySession(client: client ?? FirebaseCommunityAPI())
        savedName = preferences.string(forKey: "userName") ?? ""
        hasAcceptedPrivacy = preferences.bool(forKey: "privacyAcceptedV2")
    }

    /// Controlled native presentation: no Firebase fallback or shared legacy preferences.
    init(
        nativeSession: CommunitySession, simulatedCoordinate: Coordinate? = nil,
        isCurrent: @escaping @MainActor () -> Bool
    ) {
        session = nativeSession
        preferences = nil
        demo = simulatedCoordinate != nil
        self.simulatedCoordinate = simulatedCoordinate
        self.isCurrent = isCurrent
        isGatewayDevelopment = true
        savedName = ""
        hasAcceptedPrivacy = false
    }

    func invalidateNativePresentation() {
        guard isGatewayDevelopment else { return }
        location.reset()
        music.disable()
        savedName = ""
        hasAcceptedPrivacy = false
    }

    var canUseNativeSensors: Bool { isCurrent() && !demo }
    func requestLocationPermission() {
        guard canUseNativeSensors else { return }
        location.requestPermission()
    }

    func enter(name: String) async {
        guard isCurrent(), !Task.isCancelled else { return }
        do {
            let validated = try InputValidation.name(name)
            preferences?.set(validated, forKey: "userName")
            preferences?.set(true, forKey: "privacyAcceptedV2")
            savedName = validated
            hasAcceptedPrivacy = true
            await session.connect(name: validated)
        } catch { session.errorMessage = error.localizedDescription }
    }

    func activate() async {
        guard isCurrent(), !Task.isCancelled else { return }
        music.refresh()
        await session.setForeground(true)
        guard isCurrent(), !Task.isCancelled else { return }
        if hasAcceptedPrivacy {
            if session.phase == .idle { await session.connect(name: savedName) }
            if isCurrent(), !demo { location.resume() }
        }
    }

    func deactivate() async {
        location.pause()
        guard isCurrent() else { return }
        await session.setForeground(false)
    }

    func run() async {
        guard hasAcceptedPrivacy, isCurrent() else { return }
        while !Task.isCancelled, isCurrent() {
            if let simulatedCoordinate {
                session.updateLocation(
                    .init(coordinate: simulatedCoordinate, accuracy: 10, measuredAt: Date()))
            } else {
                location.refreshIfNeeded()
                session.updateLocation(
                    location.location.map {
                        .init(
                            coordinate: .init(
                                latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude),
                            accuracy: $0.horizontalAccuracy, measuredAt: $0.timestamp)
                    })
            }
            session.updateTrack(title: music.title, id: music.songID)
            await session.tick()
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
        }
    }

    func saveName(_ value: String) {
        guard isCurrent() else { return }
        do {
            try session.changeName(value)
            savedName = session.name
            preferences?.set(savedName, forKey: "userName")
        } catch { session.errorMessage = error.localizedDescription }
    }

    func deleteOwnData() async {
        guard isCurrent(), !isGatewayDevelopment else { return }
        if await session.deleteOwnData() {
            music.disable()
            location.pause()
            preferences?.removeObject(forKey: "userName")
            preferences?.removeObject(forKey: "privacyAcceptedV2")
            hasAcceptedPrivacy = false
            savedName = ""
        }
    }

    static func inactive() -> AppServices {
        AppServices(nativeSession: CommunitySession(client: PreviewCommunityClient()), isCurrent: { false })
    }

    static func preview() -> AppServices {
        let preferences = UserDefaults(suiteName: "EchoesPreview-" + UUID().uuidString) ?? .standard
        preferences.set("Gość", forKey: "userName")
        preferences.set(
            ProcessInfo.processInfo.environment["ECHOES_DEMO_ONBOARDING"] != "1",
            forKey: "privacyAcceptedV2")
        return AppServices(client: PreviewCommunityClient(), preferences: preferences, demo: true)
    }
}

@MainActor
final class PreviewCommunityClient: CommunityClient {
    static let center = Coordinate(latitude: 51.11, longitude: 17.03)
    private var entries: [ChatMessage] = []
    func connect() async throws -> String { "preview-viewer" }
    func configuration() async throws -> URL? { nil }
    func visibilityGeneration() async throws -> Int { 0 }
    func publish(
        name: String, coordinate: Coordinate, measuredAt: Date, song: String, songID: String,
        generation: Int
    ) async throws {}
    func stopSharing() async throws -> Int { 0 }
    func nearby(coordinate: Coordinate) async throws -> [NearbyProfile] {
        [
            .init(
                id: "preview-person", name: "Maja", coordinate: .init(latitude: 51.112, longitude: 17.034),
                lastSong: "Echoes — Pink Floyd", appleMusicID: "",
                expiresAt: Date().addingTimeInterval(600).timeIntervalSince1970 * 1000)
        ]
    }
    func messages(coordinate: Coordinate, cursor: String?, knownIDs: [String]) async throws
        -> MessagePage
    { .init(messages: entries, nextCursor: nil) }
    func send(text: String, name: String, coordinate: Coordinate, requestID: String) async throws
        -> ChatMessage
    {
        if ProcessInfo.processInfo.environment["ECHOES_DEMO_FAIL_SEND"] == "1" {
            throw CommunityFailure.unavailable
        }
        let message = ChatMessage(
            id: requestID, text: text, senderName: name, senderID: "preview-viewer",
            timestamp: Date().timeIntervalSince1970 * 1000,
            expiresAt: Date().addingTimeInterval(7200).timeIntervalSince1970 * 1000)
        entries.append(message)
        return message
    }
    func block(userID: String, blocked: Bool) async throws {}
    func blockedUsers() async throws -> [String] { [] }
    func report(messageID: String, reason: String) async throws {}
    func deleteOwnData() async throws { entries = [] }
}
