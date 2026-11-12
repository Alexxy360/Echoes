import Foundation
import Observation

@MainActor
public protocol CommunityClient {
    var serverTimeOffset: TimeInterval { get }
    func connect() async throws -> String
    func configuration() async throws -> URL?
    func visibilityGeneration() async throws -> Int
    func publish(
        name: String, coordinate: Coordinate, measuredAt: Date,
        song: String, songID: String, generation: Int) async throws
    func stopSharing() async throws -> Int
    func nearby(coordinate: Coordinate) async throws -> [NearbyProfile]
    func messages(coordinate: Coordinate, cursor: String?, knownIDs: [String]) async throws
        -> MessagePage
    func send(text: String, name: String, coordinate: Coordinate, requestID: String) async throws
        -> ChatMessage
    func block(userID: String, blocked: Bool) async throws
    func blockedUsers() async throws -> [String]
    func report(messageID: String, reason: String) async throws
    func deleteOwnData() async throws
}

extension CommunityClient {
    public var serverTimeOffset: TimeInterval { 0 }
}

public struct LocationFix: Equatable, Sendable {
    public let coordinate: Coordinate
    public let accuracy: Double
    public let measuredAt: Date
    public init(coordinate: Coordinate, accuracy: Double, measuredAt: Date) {
        self.coordinate = coordinate
        self.accuracy = accuracy
        self.measuredAt = measuredAt
    }
    public func isUsable(at now: Date) -> Bool {
        InputValidation.usableLocation(
            coordinate: coordinate, accuracy: accuracy, measuredAt: measuredAt, now: now)
    }
}

@MainActor
@Observable
public final class CommunitySession {
    public enum Phase: Equatable { case idle, connecting, ready, failed }
    public private(set) var phase: Phase = .idle
    public private(set) var userID: String?
    public private(set) var name = ""
    public private(set) var users: [NearbyProfile] = []
    public private(set) var messages: [ChatMessage] = []
    public private(set) var blockedIDs: Set<String> = []
    public private(set) var isSharing = false
    public private(set) var isChangingVisibility = false
    public private(set) var isSending = false
    public private(set) var isLoadingMessages = false
    public private(set) var isLoadingUsers = false
    public private(set) var isLoadingOlder = false
    public private(set) var didLoadUsers = false
    public private(set) var didLoadMessages = false
    public private(set) var nextCursor: String?
    public private(set) var supportURL: URL?
    public var draft = ""
    public var errorMessage: String?
    public var statusMessage: String?
    public var isChatOpen = false
    public private(set) var isForeground = false
    public private(set) var location: LocationFix?
    public private(set) var hasUsableLocation = false
    @ObservationIgnored private let client: any CommunityClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var visibilityEpoch = 0
    @ObservationIgnored private var locationEpoch = 0
    @ObservationIgnored private var previousArea: Coordinate?
    @ObservationIgnored private var pendingStop = false
    @ObservationIgnored private var track = (title: "", id: "")
    @ObservationIgnored private var trackDirty = false
    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var attempt: (id: String, text: String, name: String, coordinate: Coordinate)?

    public init(client: any CommunityClient, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    public var usableCoordinate: Coordinate? {
        guard hasUsableLocation, let location, location.isUsable(at: now()) else { return nil }
        return location.coordinate
    }

    private var serverNow: Date { now().addingTimeInterval(client.serverTimeOffset) }

    private func elapsed(since date: Date) -> TimeInterval {
        let interval = now().timeIntervalSince(date)
        return interval < 0 ? .infinity : interval
    }

    public var canSend: Bool {
        phase == .ready && isForeground && usableCoordinate != nil && !isSending
            && (try? InputValidation.message(draft)) != nil
    }

    public func connect(name value: String) async {
        guard phase != .connecting else { return }
        do {
            let name = try InputValidation.name(value)
            phase = .connecting
            errorMessage = nil
            let uid = try await client.connect()
            let support = try await client.configuration()
            let blocked = try await client.blockedUsers()
            // Start each process privately, including cleanup of a previous unclean exit.
            let currentGeneration = try await client.stopSharing()
            guard !Task.isCancelled else {
                phase = .idle
                return
            }
            userID = uid
            self.name = name
            supportURL = support
            blockedIDs = Set(blocked)
            generation = currentGeneration
            phase = .ready
            lastRefresh = .distantPast
        } catch {
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    public func setForeground(_ active: Bool) async {
        isForeground = active
        if !active {
            lastRefresh = .distantPast
            await setSharing(false)
        }
    }

    public func updateLocation(_ fix: LocationFix?) {
        if location != fix { location = fix }
        let usable = fix?.isUsable(at: now()) == true
        if hasUsableLocation != usable { hasUsableLocation = usable }
        guard let coordinate = usableCoordinate else {
            if previousArea != nil {
                previousArea = nil
                locationEpoch += 1
                users = []
                messages = []
                nextCursor = nil
            }
            return
        }
        if previousArea == nil || previousArea!.distance(to: coordinate) >= 250 {
            previousArea = coordinate
            locationEpoch += 1
            users = []
            messages = []
            nextCursor = nil
            didLoadUsers = false
            didLoadMessages = false
            lastRefresh = .distantPast
        }
    }

    public func updateTrack(title: String, id: String) {
        guard track.title != title || track.id != id else { return }
        track = (title, id)
        trackDirty = true
    }

    public func setSharing(_ enabled: Bool) async {
        if !enabled {
            let needsStop = isSharing || isChangingVisibility || pendingStop
            isSharing = false
            visibilityEpoch += 1
            guard userID != nil, needsStop else { return }
            pendingStop = true
            do {
                generation = try await client.stopSharing()
                pendingStop = false
            } catch {
                statusMessage =
                    "Zatrzymano publikowanie na tym urządzeniu. Ostatni profil może być widoczny do 10 minut; ponowimy jego ukrycie po odzyskaniu połączenia."
            }
            return
        }
        guard !isChangingVisibility, phase == .ready, isForeground else { return }
        guard let fix = location, fix.isUsable(at: now()) else {
            errorMessage = ValidationError.location.localizedDescription
            return
        }
        isChangingVisibility = true
        let epoch = visibilityEpoch
        defer { isChangingVisibility = false }
        do {
            let newGeneration = try await client.visibilityGeneration()
            guard epoch == visibilityEpoch, isForeground, !Task.isCancelled else { return }
            try await client.publish(
                name: name, coordinate: fix.coordinate, measuredAt: fix.measuredAt,
                song: track.title, songID: track.id, generation: newGeneration)
            guard epoch == visibilityEpoch, isForeground, !Task.isCancelled else {
                pendingStop = true
                generation = try await client.stopSharing()
                pendingStop = false
                return
            }
            generation = newGeneration
            isSharing = true
            pendingStop = false
            lastPublish = now()
            trackDirty = false
            statusMessage = nil
        } catch { if epoch == visibilityEpoch { errorMessage = error.localizedDescription } }
    }

    public func tick() async {
        expireCached()
        guard phase == .ready, isForeground else { return }
        if pendingStop {
            do {
                generation = try await client.stopSharing()
                pendingStop = false
                statusMessage = nil
            } catch { return }
        }
        guard usableCoordinate != nil else {
            if isSharing { await setSharing(false) }
            return
        }
        if elapsed(since: lastRefresh) >= 15 {
            lastRefresh = now()
            await refreshUsers()
            if isChatOpen { await refreshMessages() }
        }
        if isSharing
            && (elapsed(since: lastPublish) >= 30 || (trackDirty && elapsed(since: lastPublish) >= 5))
        {
            await refreshPresence()
        }
    }

    private func refreshPresence() async {
        guard isSharing, isForeground, let fix = location, fix.isUsable(at: now()) else { return }
        let epoch = visibilityEpoch
        let sentTrack = track
        do {
            try await client.publish(
                name: name, coordinate: fix.coordinate, measuredAt: fix.measuredAt,
                song: sentTrack.title, songID: sentTrack.id, generation: generation)
            guard epoch == visibilityEpoch, isSharing else { return }
            lastPublish = now()
            trackDirty = track != sentTrack
        } catch { statusMessage = "Nie udało się odnowić obecności. Spróbujemy ponownie." }
    }

    public func refreshUsers() async {
        guard !isLoadingUsers, phase == .ready, isForeground, let coordinate = usableCoordinate else {
            return
        }
        let epoch = locationEpoch
        isLoadingUsers = true
        defer { isLoadingUsers = false }
        do {
            let result = try await client.nearby(coordinate: coordinate)
            guard epoch == locationEpoch, isForeground, !Task.isCancelled else { return }
            let valid = result.filter {
                $0.id != userID && !blockedIDs.contains($0.id) && $0.isValid(at: serverNow)
            }
            if users != valid { users = valid }
            didLoadUsers = true
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    public func refreshMessages(older: Bool = false) async {
        guard !isLoadingMessages, phase == .ready, isForeground, isChatOpen,
            let coordinate = usableCoordinate
        else { return }
        if older && (nextCursor == nil || messages.count >= 200) { return }
        isLoadingMessages = true
        isLoadingOlder = older
        let epoch = locationEpoch
        let pageCursor = older ? nextCursor : nil
        defer {
            isLoadingMessages = false
            isLoadingOlder = false
        }
        do {
            let page = try await client.messages(
                coordinate: coordinate, cursor: pageCursor, knownIDs: messages.map(\.id))
            guard epoch == locationEpoch, isForeground, isChatOpen, !Task.isCancelled else { return }
            let removed = Set(page.removedIDs)
            let updated = Array(
                MessageTimeline.merge(
                    messages.filter { !removed.contains($0.id) },
                    with: page.messages, now: serverNow, blocked: blockedIDs
                ).suffix(200))
            if messages != updated { messages = updated }
            if older || !didLoadMessages { nextCursor = page.nextCursor }
            if messages.count >= 200 { nextCursor = nil }
            didLoadMessages = true
        } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    @discardableResult
    public func sendDraft() async -> Bool {
        guard !isSending, phase == .ready, isForeground else { return false }
        guard let coordinate = usableCoordinate else {
            errorMessage = ValidationError.location.localizedDescription
            return false
        }
        let sendingUserID = userID
        do {
            let text = try InputValidation.message(draft)
            if attempt?.text != text || attempt?.name != name {
                attempt = (UUID().uuidString, text, name, coordinate)
            }
            guard let attempt else { return false }
            isSending = true
            defer { isSending = false }
            let sent = try await client.send(
                text: attempt.text, name: attempt.name,
                coordinate: attempt.coordinate, requestID: attempt.id)
            guard !Task.isCancelled, userID == sendingUserID else { return false }
            if (try? InputValidation.message(draft)) == text { draft = "" }
            self.attempt = nil
            messages = Array(
                MessageTimeline.merge(messages, with: [sent], now: serverNow, blocked: blockedIDs).suffix(
                    200))
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func block(userID: String, blocked: Bool = true) async {
        do {
            try await client.block(userID: userID, blocked: blocked)
            if blocked { blockedIDs.insert(userID) } else { blockedIDs.remove(userID) }
            expireCached()
            users.removeAll { blockedIDs.contains($0.id) }
            statusMessage = blocked ? "Użytkownik został zablokowany." : "Blokada została usunięta."
        } catch { errorMessage = error.localizedDescription }
    }

    public func report(messageID: String, reason: String) async {
        do {
            try await client.report(messageID: messageID, reason: reason)
            statusMessage = "Zgłoszenie zostało zapisane do sprawdzenia."
        } catch { errorMessage = error.localizedDescription }
    }

    public func changeName(_ value: String) throws {
        name = try InputValidation.name(value)
        trackDirty = true
    }

    public func expireCached() {
        let date = serverNow
        if users.contains(where: { !$0.isValid(at: date) || blockedIDs.contains($0.id) }) {
            users.removeAll { !$0.isValid(at: date) || blockedIDs.contains($0.id) }
        }
        if messages.contains(where: { !$0.isValid(at: date) || blockedIDs.contains($0.senderID) }) {
            messages.removeAll { !$0.isValid(at: date) || blockedIDs.contains($0.senderID) }
        }
    }

    public func deleteOwnData() async -> Bool {
        await setSharing(false)
        do {
            try await client.deleteOwnData()
            users = []
            messages = []
            blockedIDs = []
            userID = nil
            name = ""
            draft = ""
            attempt = nil
            nextCursor = nil
            isChatOpen = false
            phase = .idle
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
