import EchoesCore
import Foundation

public enum GatewayCommunityFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidInput, invalidResponse, unavailable, stale, invalidCursor, textRejected
    case limited(retryAfterSeconds: Int?)
    case storage, superseded, busy, deletionRequiresReauthentication
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Sprawdź dane i spróbuj ponownie."
        case .invalidResponse, .unavailable: "Nie udało się potwierdzić wyniku. Spróbuj ponownie."
        case .stale: "Stan zmienił się. Odśwież dane przed ponowną próbą."
        case .invalidCursor: "Odśwież rozmowę, aby pobrać aktualne wiadomości."
        case .textRejected: "Zmień treść. Wiadomość nie spełnia zasad społeczności."
        case .limited: "Wykonano zbyt wiele prób. Odczekaj przed kolejną."
        case .storage: "Odblokuj urządzenie. Nie udało się zapisać operacji."
        case .superseded: "Konto lub stan aplikacji zmieniły się."
        case .busy: "Poczekaj na zakończenie bieżącej operacji."
        case .deletionRequiresReauthentication:
            "Usuń konto w ustawieniach konta, potwierdzając to przez Apple."
        }
    }
}

/// Closed operations, not a JSON/proxy escape hatch. Identifiers use lowercase UUIDs.
public enum GatewayCommunityOperation: Codable, Equatable, Sendable {
    case configuration, visibility, blocked, profile
    case publish(
        requestID: String, name: String, coordinate: Coordinate, measuredAt: Date,
        song: String, songID: String, generation: Int)
    case stop(requestID: String, generation: Int)
    case nearby(coordinate: Coordinate)
    case messages(coordinate: Coordinate, cursor: String?, knownIDs: [String])
    case send(requestID: String, name: String, text: String, coordinate: Coordinate)
    case block(requestID: String, accountID: String, blocked: Bool, generation: Int)
    case blockState(accountID: String)
    case report(requestID: String, messageID: String, reason: String, coordinate: Coordinate)
    case saveProfile(requestID: String, name: String, revision: String?)

    var path: String {
        let action: String
        switch self {
        case .configuration: action = "config"
        case .visibility: action = "visibility"
        case .blocked: action = "blocked"
        case .profile: action = "profile"
        case .publish: action = "publish"
        case .stop: action = "stop"
        case .nearby: action = "nearby"
        case .messages: action = "messages"
        case .send: action = "send"
        case .block: action = "block"
        case .blockState: action = "block/state"
        case .report: action = "report"
        case .saveProfile: action = "profile/save"
        }
        return "/v1/community/" + action
    }
    func encodedBody() throws -> Data {
        func identifier(_ value: String) throws -> String {
            guard gatewayUUID(value) else { throw GatewayCommunityFailure.invalidInput }
            return value
        }
        func coordinate(_ value: Coordinate) throws -> [String: Double] {
            guard value.isValid else { throw GatewayCommunityFailure.invalidInput }
            return ["latitude": value.latitude, "longitude": value.longitude]
        }
        func generation(_ value: Int) throws -> Int {
            guard value >= 0, value < 9_007_199_254_740_991 else {
                throw GatewayCommunityFailure.invalidInput
            }
            return value
        }
        func name(_ value: String) throws -> String {
            guard (try? InputValidation.name(value)) == value else {
                throw GatewayCommunityFailure.invalidInput
            }
            return value
        }
        func text(_ value: String) throws -> String {
            guard (try? InputValidation.message(value)) == value else {
                throw GatewayCommunityFailure.invalidInput
            }
            return value
        }
        let fields: [String: Any]
        switch self {
        case .configuration, .visibility, .blocked, .profile: fields = [:]
        case .publish(
            let id, let displayName, let position, let measuredAt, let song, let songID, let version):
            let milliseconds = measuredAt.timeIntervalSince1970 * 1000
            guard milliseconds.isFinite, milliseconds >= 0, milliseconds < 9_007_199_254_740_991,
                song.isEmpty || (try? InputValidation.message(song)) == song, song.utf16.count <= 300,
                communityMusicID(songID)
            else { throw GatewayCommunityFailure.invalidInput }
            fields = [
                "requestID": try identifier(id), "name": try name(displayName),
                "coordinate": try coordinate(position),
                "measuredAt": Int64(milliseconds), "song": song, "songID": songID,
                "generation": try generation(version),
            ]
        case .stop(let id, let version):
            fields = ["requestID": try identifier(id), "generation": try generation(version)]
        case .nearby(let position): fields = ["coordinate": try coordinate(position)]
        case .messages(let position, let cursor, let knownIDs):
            guard cursor == nil || communityCursor(cursor!), knownIDs.count <= 200,
                Set(knownIDs).count == knownIDs.count,
                knownIDs.allSatisfy({ communityRecordName($0, kind: "message") })
            else { throw GatewayCommunityFailure.invalidInput }
            fields = [
                "coordinate": try coordinate(position), "cursor": cursor as Any? ?? NSNull(),
                "knownIDs": knownIDs,
            ]
        case .send(let id, let displayName, let content, let position):
            fields = [
                "requestID": try identifier(id), "name": try name(displayName), "text": try text(content),
                "coordinate": try coordinate(position),
            ]
        case .block(let id, let target, let blocked, let version):
            fields = [
                "requestID": try identifier(id), "accountID": try identifier(target), "blocked": blocked,
                "generation": try generation(version),
            ]
        case .blockState(let target): fields = ["accountID": try identifier(target)]
        case .report(let id, let target, let reason, let position):
            guard communityRecordName(target, kind: "message") else {
                throw GatewayCommunityFailure.invalidInput
            }
            fields = [
                "requestID": try identifier(id), "messageID": target, "reason": try text(reason),
                "coordinate": try coordinate(position),
            ]
        case .saveProfile(let id, let displayName, let revision):
            guard revision == nil || communityRevision(revision!) else {
                throw GatewayCommunityFailure.invalidInput
            }
            fields = [
                "requestID": try identifier(id), "name": try name(displayName),
                "revision": revision as Any? ?? NSNull(),
            ]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            guard data.count <= 49_152 else { throw GatewayCommunityFailure.invalidInput }
            return data
        } catch { throw GatewayCommunityFailure.invalidInput }
    }
}

public struct GatewayPublicProfile: Equatable, Sendable {
    public let name: String
    public let revision: String
    public let avatarVersionID: String?
    public init(name: String, revision: String, avatarVersionID: String? = nil) {
        self.name = name
        self.revision = revision
        self.avatarVersionID = avatarVersionID
    }
}
public enum GatewayCommunityValue: Sendable {
    case configuration(supportURL: URL?)
    case generation(Int)
    case publication(id: String, generation: Int, visible: Bool)
    case nearby([NearbyProfile])
    case messages(MessagePage)
    case sent(ChatMessage)
    case blocked([String])
    case receipt(String)
    case blockState(generation: Int, blocked: Bool)
    case accepted
    case profile(GatewayPublicProfile?)
    case savedProfile(GatewayPublicProfile)
}
public struct GatewayCommunityReply: Sendable {
    public let serverTime: Date
    public let value: GatewayCommunityValue
    public init(serverTime: Date, value: GatewayCommunityValue) {
        self.serverTime = serverTime
        self.value = value
    }
}
public protocol GatewayCommunityAPI: Sendable {
    var origin: String { get }
    func perform(_ operation: GatewayCommunityOperation, token: GatewaySecret) async throws
        -> GatewayCommunityReply
}

func communityRecordName(_ value: String, kind: String) -> Bool {
    let prefix = "community-v1-" + kind + "-"
    return value.hasPrefix(prefix) && value.utf8.count == prefix.utf8.count + 64
        && value.dropFirst(prefix.count).utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
}
func communityMusicID(_ value: String) -> Bool {
    value.utf8.count <= 30 && value.utf8.allSatisfy { (48...57).contains($0) }
}
func communityRevision(_ value: String) -> Bool {
    (1...512).contains(value.utf8.count) && value.utf8.allSatisfy { (33...126).contains($0) }
}
func communityCursor(_ value: String) -> Bool {
    value.hasPrefix("v1.") && (4...20_000).contains(value.utf8.count)
        && value.dropFirst(3).utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                || $0 == 95
        }
}

/// Separate typed client and response cap; auth/deletion keep their existing 32 KiB boundary.
public struct GatewayCommunityHTTPClient: GatewayCommunityAPI {
    private let configuration: GatewayConfiguration
    private let transport: any GatewayHTTPTransport
    private let now: @Sendable () -> Date
    public var origin: String { configuration.origin.absoluteString }
    public init(
        configuration: GatewayConfiguration,
        transport: any GatewayHTTPTransport = NativeGatewayTransport.community(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }
    public func perform(_ operation: GatewayCommunityOperation, token: GatewaySecret) async throws
        -> GatewayCommunityReply
    {
        guard token.value.utf8.count == 80, gatewayUUID(String(token.value.prefix(36))),
            token.value.dropFirst(36).first == ".",
            token.value.suffix(43).utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                    || $0 == 95
            })
        else { throw GatewayCommunityFailure.invalidInput }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        var request = URLRequest(url: configuration.origin.appendingPathComponent(operation.path))
        request.httpMethod = "POST"
        request.httpBody = try operation.encodedBody()
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer " + token.value, forHTTPHeaderField: "Authorization")
        let response: GatewayHTTPResponse
        do { response = try await transport.send(request) } catch {
            if Task.isCancelled { throw GatewayFailure.cancelled }
            throw GatewayCommunityFailure.unavailable
        }
        if Task.isCancelled { throw GatewayFailure.cancelled }
        let type = response.contentType?.lowercased().replacingOccurrences(of: " ", with: "")
        guard response.body.count <= 262_144,
            type == "application/json" || type == "application/json;charset=utf-8"
        else { throw GatewayCommunityFailure.invalidResponse }
        guard response.status == 200 else { throw try failure(response) }
        do { return try decode(operation, data: response.body) } catch {
            throw GatewayCommunityFailure.invalidResponse
        }
    }
    private func failure(_ response: GatewayHTTPResponse) throws -> any Error {
        struct Body: Decodable {
            let protocolVersion: Int
            let error: String
        }
        guard (400...599).contains(response.status),
            let value = try? JSONDecoder().decode(Body.self, from: response.body), value.protocolVersion == 1
        else { throw GatewayCommunityFailure.invalidResponse }
        let retry: Int? = response.retryAfter.flatMap { raw in
            guard (1...6).contains(raw.utf8.count), raw.utf8.allSatisfy({ (48...57).contains($0) }),
                let seconds = Int(raw), seconds <= 86_400
            else { return nil }
            return seconds
        }
        switch value.error {
        case "INVALID_SESSION", "REAUTH_REQUIRED", "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS":
            return GatewayFailure.signInRequired
        case "COMMUNITY_INPUT", "PUBLIC_INPUT": return GatewayCommunityFailure.invalidInput
        case "COMMUNITY_STALE", "PUBLIC_CONFLICT", "PUBLIC_PENDING", "PUBLIC_ERASED":
            return GatewayCommunityFailure.stale
        case "COMMUNITY_CURSOR": return GatewayCommunityFailure.invalidCursor
        case "COMMUNITY_TEXT_REJECTED": return GatewayCommunityFailure.textRejected
        case "COMMUNITY_RATE_LIMITED", "COMMUNITY_CAPACITY", "PUBLIC_LIMIT", "RATE_LIMITED":
            return GatewayCommunityFailure.limited(retryAfterSeconds: retry)
        default: return GatewayCommunityFailure.unavailable
        }
    }
    private struct Message: Decodable {
        let id: String, authorID: String, name: String, text: String
        let timestamp: Double, expiresAt: Double
        let avatarVersionID: String?
        func validated(serverTime: Double, allowExpired: Bool = false) throws -> ChatMessage {
            guard communityRecordName(id, kind: "message"), gatewayUUID(authorID),
                (try? InputValidation.name(name)) == name,
                (try? InputValidation.message(text)) == text, timestamp.isFinite, timestamp >= 0,
                timestamp <= serverTime + 5000,
                expiresAt == timestamp + 7_200_000, allowExpired || expiresAt > serverTime,
                avatarVersionID == nil || gatewayUUID(avatarVersionID!)
            else { throw GatewayCommunityFailure.invalidResponse }
            return .init(
                id: id, text: text, senderName: name, senderID: authorID, timestamp: timestamp,
                expiresAt: expiresAt, avatarVersionID: avatarVersionID)
        }
    }
    private struct Person: Decodable {
        let id: String, name: String, song: String, songID: String
        let latitude: Double, longitude: Double, updatedAt: Double, expiresAt: Double, distanceMeters: Double
        let avatarVersionID: String?
        func validated(coordinate: Coordinate, serverTime: Double) throws -> NearbyProfile {
            let position = Coordinate(latitude: latitude, longitude: longitude)
            guard gatewayUUID(id), (try? InputValidation.name(name)) == name, position.isValid,
                song.utf16.count <= 300,
                song.isEmpty || (try? InputValidation.message(song)) == song, communityMusicID(songID),
                updatedAt.isFinite, updatedAt >= 0, updatedAt <= serverTime + 5000, expiresAt > serverTime,
                expiresAt == updatedAt + 600_000, distanceMeters.isFinite,
                (0...3000).contains(distanceMeters),
                coordinate.distance(to: position) <= 3000.001,
                abs(coordinate.distance(to: position).rounded() - distanceMeters) <= 1,
                avatarVersionID == nil || gatewayUUID(avatarVersionID!)
            else { throw GatewayCommunityFailure.invalidResponse }
            return .init(
                id: id, name: name, coordinate: position, lastSong: song, appleMusicID: songID,
                expiresAt: expiresAt, avatarVersionID: avatarVersionID)
        }
    }
    private struct Profile: Decodable {
        let name: String, revision: String
        let avatarVersionID: String?
        func validated() throws -> GatewayPublicProfile {
            guard (try? InputValidation.name(name)) == name, communityRevision(revision),
                avatarVersionID == nil || gatewayUUID(avatarVersionID!)
            else {
                throw GatewayCommunityFailure.invalidResponse
            }
            return .init(name: name, revision: revision, avatarVersionID: avatarVersionID)
        }
    }
    private struct Body: Decodable {
        let protocolVersion: Int, serverTime: Double
        let radiusMeters: Int?, presenceLifetimeSeconds: Int?, messageLifetimeSeconds: Int?,
            messagePageSize: Int?, supportURL: String?
        let generation: Int?, visible: Bool?, blocked: Bool?, id: String?, accepted: Bool?, cursor: String?,
            removedIDs: [String]?, accountIDs: [String]?
        let users: [Person]?, messages: [Message]?, message: Message?, profile: Profile?, name: String?,
            revision: String?
    }
    private func decode(_ operation: GatewayCommunityOperation, data: Data) throws -> GatewayCommunityReply {
        let body = try JSONDecoder().decode(Body.self, from: data)
        guard body.protocolVersion == 1, body.serverTime.isFinite,
            body.serverTime.rounded() == body.serverTime,
            body.serverTime > 0, body.serverTime < 9_007_199_254_740_991,
            abs(body.serverTime / 1000 - now().timeIntervalSince1970) <= 300,
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw GatewayCommunityFailure.invalidResponse }
        func fields(_ expected: [String]) throws {
            guard Set(raw.keys) == Set(expected + ["protocolVersion", "serverTime"]) else {
                throw GatewayCommunityFailure.invalidResponse
            }
        }
        func nestedFields(_ value: Any?, required: [String]) throws {
            guard let object = value as? [String: Any],
                Set(required).isSubset(of: Set(object.keys)),
                Set(object.keys).isSubset(of: Set(required + ["avatarVersionID"]))
            else { throw GatewayCommunityFailure.invalidResponse }
        }
        func generation() throws -> Int {
            guard let value = body.generation, value >= 0, value < 9_007_199_254_740_991 else {
                throw GatewayCommunityFailure.invalidResponse
            }
            return value
        }
        let value: GatewayCommunityValue
        switch operation {
        case .configuration:
            try fields([
                "radiusMeters", "presenceLifetimeSeconds", "messageLifetimeSeconds", "messagePageSize",
                "supportURL",
            ])
            guard body.radiusMeters == 3000, body.presenceLifetimeSeconds == 600,
                body.messageLifetimeSeconds == 7200, body.messagePageSize == 50
            else { throw GatewayCommunityFailure.invalidResponse }
            var url: URL?
            if let address = body.supportURL {
                guard address.utf8.count <= 2048, let parts = URLComponents(string: address),
                    parts.user == nil, parts.password == nil, parts.fragment == nil,
                    parts.scheme == "https" && parts.host?.isEmpty == false
                        || parts.scheme == "mailto" && parts.path.contains("@") && parts.query == nil,
                    !address.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }),
                    let parsed = parts.url
                else { throw GatewayCommunityFailure.invalidResponse }
                url = parsed
            }
            value = .configuration(supportURL: url)
        case .visibility:
            try fields(["generation"])
            value = .generation(try generation())
        case .publish, .stop:
            try fields(["id", "generation", "visible"])
            guard let id = body.id, communityRecordName(id, kind: "presence"), let visible = body.visible
            else { throw GatewayCommunityFailure.invalidResponse }
            if case .publish(_, _, _, _, _, _, let expected) = operation {
                guard visible, try generation() == expected else {
                    throw GatewayCommunityFailure.invalidResponse
                }
            }
            if case .stop(_, let previous) = operation {
                guard !visible, try generation() == previous + 1 else {
                    throw GatewayCommunityFailure.invalidResponse
                }
            }
            value = .publication(id: id, generation: try generation(), visible: visible)
        case .nearby(let position):
            try fields(["users"])
            guard let users = body.users, users.count <= 100, Set(users.map(\.id)).count == users.count,
                let rawUsers = raw["users"] as? [Any]
            else {
                throw GatewayCommunityFailure.invalidResponse
            }
            for user in rawUsers {
                try nestedFields(
                    user,
                    required: [
                        "id", "name", "song", "songID", "latitude", "longitude", "updatedAt", "expiresAt",
                        "distanceMeters",
                    ])
            }
            value = .nearby(
                try users.map { try $0.validated(coordinate: position, serverTime: body.serverTime) })
        case .messages(_, _, let known):
            try fields(["messages", "cursor", "removedIDs"])
            guard let messages = body.messages, messages.count <= 50,
                let rawMessages = raw["messages"] as? [Any],
                Set(messages.map(\.id)).count == messages.count,
                let removed = body.removedIDs, removed.count <= 200, Set(removed).count == removed.count,
                Set(removed).isSubset(of: Set(known)), body.cursor == nil || communityCursor(body.cursor!)
            else { throw GatewayCommunityFailure.invalidResponse }
            for message in rawMessages {
                try nestedFields(
                    message, required: ["id", "authorID", "name", "text", "timestamp", "expiresAt"])
            }
            let mapped = try messages.map { try $0.validated(serverTime: body.serverTime) }
            let ordered = mapped.sorted {
                $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
            }
            guard mapped == ordered, Set(mapped.map(\.id)).isDisjoint(with: Set(removed)) else {
                throw GatewayCommunityFailure.invalidResponse
            }
            value = .messages(.init(messages: mapped, nextCursor: body.cursor, removedIDs: removed))
        case .send(_, let expectedName, let expectedText, _):
            try fields(["id", "message"])
            try nestedFields(
                raw["message"], required: ["id", "authorID", "name", "text", "timestamp", "expiresAt"])
            guard let message = body.message, message.id == body.id, message.name == expectedName,
                message.text == expectedText
            else { throw GatewayCommunityFailure.invalidResponse }
            value = .sent(try message.validated(serverTime: body.serverTime, allowExpired: true))
        case .block(_, _, let expected, let previous):
            try fields(["id", "generation", "blocked"])
            guard let id = body.id, communityRecordName(id, kind: "block"), body.blocked == expected,
                try generation() == previous + 1
            else {
                throw GatewayCommunityFailure.invalidResponse
            }
            value = .receipt(id)
        case .blockState:
            try fields(["generation", "blocked"])
            guard let blocked = body.blocked else { throw GatewayCommunityFailure.invalidResponse }
            value = .blockState(generation: try generation(), blocked: blocked)
        case .blocked:
            try fields(["accountIDs"])
            guard let identifiers = body.accountIDs, identifiers.count <= 200,
                Set(identifiers).count == identifiers.count, identifiers.allSatisfy(gatewayUUID)
            else { throw GatewayCommunityFailure.invalidResponse }
            value = .blocked(identifiers)
        case .report:
            try fields(["accepted"])
            guard body.accepted == true else { throw GatewayCommunityFailure.invalidResponse }
            value = .accepted
        case .profile:
            try fields(["profile"])
            if body.profile != nil { try nestedFields(raw["profile"], required: ["name", "revision"]) }
            value = .profile(try body.profile?.validated())
        case .saveProfile(_, let expectedName, _):
            try fields(["name", "revision"])
            guard let name = body.name, name == expectedName, let revision = body.revision else {
                throw GatewayCommunityFailure.invalidResponse
            }
            value = .savedProfile(
                try Profile(name: name, revision: revision, avatarVersionID: nil).validated())
        }
        return .init(serverTime: Date(timeIntervalSince1970: body.serverTime / 1000), value: value)
    }
}

public struct ActivatedGatewayCommunityAPI: GatewayCommunityAPI {
    private let api: any GatewayCommunityAPI
    private let activation: GatewayDevelopmentActivation
    private let now: @Sendable () -> Date
    public var origin: String { api.origin }
    public init(
        api: any GatewayCommunityAPI, activation: GatewayDevelopmentActivation,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard api.origin == activation.configuration.origin.absoluteString else {
            throw GatewayFailure.configuration
        }
        self.api = api
        self.activation = activation
        self.now = now
    }
    public func perform(_ operation: GatewayCommunityOperation, token: GatewaySecret) async throws
        -> GatewayCommunityReply
    {
        guard activation.isActive(at: now()) else { throw GatewayFailure.configuration }
        let result = try await api.perform(operation, token: token)
        guard activation.isActive(at: now()) else { throw GatewayFailure.configuration }
        return result
    }
}
