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
    func pendingMessage() throws -> PendingCommunityMessage?
    func forgetPendingMessage(_ expected: PendingCommunityMessage) throws
}

extension CommunityClient {
    public var serverTimeOffset: TimeInterval { 0 }
    public func pendingMessage() throws -> PendingCommunityMessage? { nil }
    public func forgetPendingMessage(_ expected: PendingCommunityMessage) throws {
        throw PendingMessageFailure.changed
    }
}

public struct PendingCommunityMessage: Equatable, Sendable {
    public let requestID: String
    public let name: String
    public let text: String
    public let coordinate: Coordinate
    public let recoveryID: String
    public init(requestID: String, name: String, text: String, coordinate: Coordinate, recoveryID: String) {
        self.requestID = requestID
        self.name = name
        self.text = text
        self.coordinate = coordinate
        self.recoveryID = recoveryID
    }
}
public enum PendingMessageFailure: Error, LocalizedError, Equatable, Sendable {
    case unresolved, changed
    public var errorDescription: String? {
        switch self {
        case .unresolved:
            "Najpierw ponów poprzednią wiadomość lub usuń jej lokalną próbę. Mogła już zostać wysłana."
        case .changed: "Próba wiadomości zmieniła się. Sprawdź jej aktualny stan."
        }
    }
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
    public private(set) var pendingMessage: PendingCommunityMessage?
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
    @ObservationIgnored private var sessionEpoch = UUID()

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

    /// Synchronous boundary used before changing native accounts or closing their foreground UI.
    public func invalidateForAccountChange() {
        sessionEpoch = UUID()
        visibilityEpoch += 1
        locationEpoch += 1
        phase = .idle
        userID = nil
        name = ""
        users = []
        messages = []
        blockedIDs = []
        isSharing = false
        isChangingVisibility = false
        isSending = false
        isLoadingMessages = false
        isLoadingUsers = false
        isLoadingOlder = false
        didLoadUsers = false
        didLoadMessages = false
        nextCursor = nil
        supportURL = nil
        draft = ""
        pendingMessage = nil
        errorMessage = nil
        statusMessage = nil
        isChatOpen = false
        isForeground = false
        location = nil
        hasUsableLocation = false
        previousArea = nil
        pendingStop = false
        track = ("", "")
        trackDirty = false
        generation = 0
        lastPublish = .distantPast
        lastRefresh = .distantPast
        attempt = nil
    }
    private func isCurrent(_ epoch: UUID) -> Bool { epoch == sessionEpoch && !Task.isCancelled }

    public func connect(name value: String) async {
        guard phase != .connecting else { return }
        let validated: String
        do { validated = try InputValidation.name(value) } catch {
            errorMessage = error.localizedDescription
            return
        }
        let foreground = isForeground
        invalidateForAccountChange()
        isForeground = foreground
        let epoch = sessionEpoch
        phase = .connecting
        defer { if epoch == sessionEpoch, phase == .connecting { phase = .idle } }
        do {
            let uid = try await client.connect()
            guard isCurrent(epoch) else { return }
            // Privacy cleanup precedes auxiliary reads and uses the adapter's persisted stop ID.
            let currentGeneration = try await client.stopSharing()
            guard isCurrent(epoch) else { return }
            let support = try await client.configuration()
            guard isCurrent(epoch) else { return }
            let blocked = try await client.blockedUsers()
            guard isCurrent(epoch) else { return }
            let pending = try client.pendingMessage()
            guard isCurrent(epoch) else { return }
            userID = uid
            name = validated
            supportURL = support
            blockedIDs = Set(blocked)
            generation = currentGeneration
            pendingMessage = pending
            if let pending {
                draft = pending.text
                attempt = (pending.requestID, pending.text, pending.name, pending.coordinate)
            }
            phase = .ready
            lastRefresh = .distantPast
        } catch {
            guard isCurrent(epoch) else { return }
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    public func setForeground(_ active: Bool) async {
        isForeground = active
        if !active {
            locationEpoch += 1
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
        if previousArea == nil
            || previousArea!.distance(to: coordinate) >= CommunityPolicy.areaRefreshDistanceMeters
        {
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
        let session = sessionEpoch
        if !enabled {
            let needsStop = isSharing || isChangingVisibility || pendingStop
            isSharing = false
            visibilityEpoch += 1
            let epoch = visibilityEpoch
            guard userID != nil, needsStop else { return }
            pendingStop = true
            do {
                let value = try await client.stopSharing()
                guard isCurrent(session), epoch == visibilityEpoch else { return }
                generation = value
                pendingStop = false
            } catch {
                guard isCurrent(session), epoch == visibilityEpoch else { return }
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
        defer { if session == sessionEpoch { isChangingVisibility = false } }
        do {
            let newGeneration = try await client.visibilityGeneration()
            guard isCurrent(session), epoch == visibilityEpoch, isForeground else { return }
            try await client.publish(
                name: name, coordinate: fix.coordinate, measuredAt: fix.measuredAt,
                song: track.title, songID: track.id, generation: newGeneration)
            guard isCurrent(session) else { return }
            guard epoch == visibilityEpoch, isForeground else {
                pendingStop = true
                let value = try await client.stopSharing()
                guard isCurrent(session) else { return }
                generation = value
                pendingStop = false
                return
            }
            generation = newGeneration
            isSharing = true
            pendingStop = false
            lastPublish = now()
            trackDirty = false
            statusMessage = nil
        } catch {
            if isCurrent(session), epoch == visibilityEpoch { errorMessage = error.localizedDescription }
        }
    }

    public func tick() async {
        expireCached()
        guard phase == .ready, isForeground else { return }
        let session = sessionEpoch
        if pendingStop {
            do {
                let value = try await client.stopSharing()
                guard isCurrent(session) else { return }
                generation = value
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
            guard isCurrent(session) else { return }
            if isChatOpen { await refreshMessages() }
        }
        guard isCurrent(session) else { return }
        if isSharing
            && (elapsed(since: lastPublish) >= 30 || (trackDirty && elapsed(since: lastPublish) >= 5))
        {
            await refreshPresence()
        }
    }

    private func refreshPresence() async {
        guard isSharing, isForeground, let fix = location, fix.isUsable(at: now()) else { return }
        let epoch = visibilityEpoch
        let session = sessionEpoch
        let sentTrack = track
        do {
            try await client.publish(
                name: name, coordinate: fix.coordinate, measuredAt: fix.measuredAt,
                song: sentTrack.title, songID: sentTrack.id, generation: generation)
            guard isCurrent(session), epoch == visibilityEpoch, isSharing else { return }
            lastPublish = now()
            trackDirty = track != sentTrack
        } catch {
            if isCurrent(session), epoch == visibilityEpoch {
                statusMessage = "Nie udało się odnowić obecności. Spróbujemy ponownie."
            }
        }
    }

    public func refreshUsers() async {
        guard !isLoadingUsers, phase == .ready, isForeground, let coordinate = usableCoordinate else {
            return
        }
        let epoch = locationEpoch
        let session = sessionEpoch
        isLoadingUsers = true
        defer { if session == sessionEpoch { isLoadingUsers = false } }
        do {
            let result = try await client.nearby(coordinate: coordinate)
            guard isCurrent(session), epoch == locationEpoch, isForeground else { return }
            let valid = result.filter {
                $0.id != userID && !blockedIDs.contains($0.id) && $0.isValid(at: serverNow)
            }
            if users != valid { users = valid }
            didLoadUsers = true
        } catch {
            if isCurrent(session), epoch == locationEpoch, isForeground {
                errorMessage = error.localizedDescription
            }
        }
    }

    public func refreshMessages(older: Bool = false) async {
        guard !isLoadingMessages, phase == .ready, isForeground, isChatOpen,
            let coordinate = usableCoordinate
        else { return }
        if older && (nextCursor == nil || messages.count >= 200) { return }
        isLoadingMessages = true
        isLoadingOlder = older
        let epoch = locationEpoch
        let session = sessionEpoch
        let pageCursor = older ? nextCursor : nil
        defer {
            if session == sessionEpoch {
                isLoadingMessages = false
                isLoadingOlder = false
            }
        }
        do {
            let page = try await client.messages(
                coordinate: coordinate, cursor: pageCursor, knownIDs: messages.map(\.id))
            guard isCurrent(session), epoch == locationEpoch, isForeground, isChatOpen else { return }
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
        } catch {
            if isCurrent(session), epoch == locationEpoch, isForeground, isChatOpen {
                if error as? CommunityPageFailure == .cursorExpired {
                    nextCursor = nil
                    didLoadMessages = false
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    public func sendDraft() async -> Bool {
        guard !isSending, phase == .ready, isForeground else { return false }
        guard let coordinate = usableCoordinate else {
            errorMessage = ValidationError.location.localizedDescription
            return false
        }
        let epoch = sessionEpoch
        let area = locationEpoch
        do {
            let text = try InputValidation.message(draft)
            let pending = try client.pendingMessage()
            pendingMessage = pending
            if let pending {
                guard pending.text == text else { throw PendingMessageFailure.unresolved }
                attempt = (pending.requestID, pending.text, pending.name, pending.coordinate)
            } else if attempt?.text != text || attempt?.name != name {
                attempt = (UUID().uuidString, text, name, coordinate)
            }
            guard let attempt else { return false }
            isSending = true
            defer { if epoch == sessionEpoch { isSending = false } }
            let sent = try await client.send(
                text: attempt.text, name: attempt.name, coordinate: attempt.coordinate, requestID: attempt.id)
            guard isCurrent(epoch) else { return false }
            if (try? InputValidation.message(draft)) == text { draft = "" }
            self.attempt = nil
            pendingMessage = nil
            if area == locationEpoch, isForeground,
                attempt.coordinate.distance(to: coordinate) < CommunityPolicy.areaRefreshDistanceMeters
            {
                messages = Array(
                    MessageTimeline.merge(messages, with: [sent], now: serverNow, blocked: blockedIDs).suffix(
                        200))
            }
            return true
        } catch {
            guard isCurrent(epoch) else { return false }
            do { pendingMessage = try client.pendingMessage() } catch {
                // Preserve the last verified snapshot on protected-storage failure.
            }
            errorMessage = error.localizedDescription
            return false
        }
    }
    @discardableResult
    public func retryPendingMessage() async -> Bool {
        guard !isSending, let pending = pendingMessage else { return false }
        let epoch = sessionEpoch
        let edited = draft
        draft = pending.text
        attempt = (pending.requestID, pending.text, pending.name, pending.coordinate)
        let sent = await sendDraft()
        if isCurrent(epoch), edited != pending.text, draft.isEmpty || draft == pending.text { draft = edited }
        return sent
    }
    /// Explicit LOCAL removal only. It does not claim that an unknown send was never delivered.
    public func forgetPendingMessage(_ expected: PendingCommunityMessage) throws {
        guard !isSending, pendingMessage == expected else { throw PendingMessageFailure.changed }
        try client.forgetPendingMessage(expected)
        pendingMessage = nil
        attempt = nil
    }

    public func block(userID: String, blocked: Bool = true) async {
        guard phase == .ready, isForeground else { return }
        let epoch = sessionEpoch
        do {
            try await client.block(userID: userID, blocked: blocked)
            guard isCurrent(epoch) else { return }
            if blocked { blockedIDs.insert(userID) } else { blockedIDs.remove(userID) }
            expireCached()
            users.removeAll { blockedIDs.contains($0.id) }
            statusMessage = blocked ? "Użytkownik został zablokowany." : "Blokada została usunięta."
        } catch { if isCurrent(epoch) { errorMessage = error.localizedDescription } }
    }

    public func report(messageID: String, reason: String) async {
        guard phase == .ready, isForeground else { return }
        let epoch = sessionEpoch
        do {
            try await client.report(messageID: messageID, reason: reason)
            guard isCurrent(epoch) else { return }
            statusMessage = "Zgłoszenie zostało zapisane do sprawdzenia."
        } catch { if isCurrent(epoch) { errorMessage = error.localizedDescription } }
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
        let epoch = sessionEpoch
        await setSharing(false)
        guard isCurrent(epoch) else { return false }
        do {
            try await client.deleteOwnData()
            guard isCurrent(epoch) else { return false }
            invalidateForAccountChange()
            return true
        } catch {
            guard isCurrent(epoch) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }
}
