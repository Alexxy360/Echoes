import Foundation

public enum CommunityPolicy {
    public static let radiusMeters = 3_000.0
    public static let presenceLifetime = 600.0
    public static let messageLifetime = 7_200.0
    public static let maximumLocationAge = 60.0
    public static let maximumAccuracyMeters = 500.0
    public static let maximumNameLength = 40
    public static let maximumMessageLength = 500
}

public struct Coordinate: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }

    public func distance(to other: Coordinate) -> Double {
        guard isValid, other.isValid else { return .infinity }
        let radians = Double.pi / 180
        let lat = (other.latitude - latitude) * radians
        let lon = (other.longitude - longitude) * radians
        let a =
            pow(sin(lat / 2), 2) + cos(latitude * radians) * cos(other.latitude * radians)
            * pow(sin(lon / 2), 2)
        return 6_371_000 * 2 * atan2(sqrt(min(1, a)), sqrt(max(0, 1 - a)))
    }
}

public enum ValidationError: LocalizedError, Equatable, Sendable {
    case name, message, location

    public var errorDescription: String? {
        switch self {
        case .name: "Wpisz pseudonim od 1 do 40 znaków."
        case .message: "Wiadomość musi zawierać od 1 do 500 znaków."
        case .location: "Poczekaj na aktualną, dokładniejszą pozycję GPS."
        }
    }
}

public enum InputValidation {
    public static func name(_ value: String) throws -> String {
        let result = normalized(value)
        guard !result.isEmpty, result.utf16.count <= CommunityPolicy.maximumNameLength,
            !hasForbiddenControls(result)
        else { throw ValidationError.name }
        return result
    }

    public static func message(_ value: String) throws -> String {
        let result = normalized(value)
        guard !result.isEmpty, result.utf16.count <= CommunityPolicy.maximumMessageLength,
            !hasForbiddenControls(result)
        else { throw ValidationError.message }
        return result
    }

    public static func usableLocation(
        coordinate: Coordinate, accuracy: Double,
        measuredAt: Date, now: Date
    ) -> Bool {
        coordinate.isValid && accuracy.isFinite && accuracy >= 0
            && accuracy <= CommunityPolicy.maximumAccuracyMeters
            && now.timeIntervalSince(measuredAt) >= -5
            && now.timeIntervalSince(measuredAt) <= CommunityPolicy.maximumLocationAge
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasForbiddenControls(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            ($0.value < 0x20 && $0 != "\n" && $0 != "\t") || $0.value == 0x7f
                || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
        }
    }
}

public struct NearbyProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let coordinate: Coordinate
    public let lastSong: String
    public let appleMusicID: String
    public let expiresAt: Double

    public init(
        id: String, name: String, coordinate: Coordinate, lastSong: String,
        appleMusicID: String, expiresAt: Double
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.lastSong = lastSong
        self.appleMusicID = appleMusicID
        self.expiresAt = expiresAt
    }

    public func isValid(at date: Date) -> Bool {
        !id.isEmpty && coordinate.isValid && (try? InputValidation.name(name)) != nil
            && expiresAt.isFinite && expiresAt > date.timeIntervalSince1970 * 1000
            && lastSong.utf16.count <= 300
    }
}

public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let senderName: String
    public let senderID: String
    public let timestamp: Double
    public let expiresAt: Double

    public init(
        id: String, text: String, senderName: String, senderID: String,
        timestamp: Double, expiresAt: Double
    ) {
        self.id = id
        self.text = text
        self.senderName = senderName
        self.senderID = senderID
        self.timestamp = timestamp
        self.expiresAt = expiresAt
    }

    public func isValid(at date: Date) -> Bool {
        !id.isEmpty && !senderID.isEmpty && (try? InputValidation.message(text)) != nil
            && (try? InputValidation.name(senderName)) != nil && timestamp.isFinite && expiresAt.isFinite
            && timestamp <= date.timeIntervalSince1970 * 1000 + 5_000
            && expiresAt > date.timeIntervalSince1970 * 1000 && expiresAt > timestamp
    }
}

public struct MessagePage: Codable, Sendable {
    public let messages: [ChatMessage]
    public let nextCursor: String?
    public let removedIDs: [String]
    public init(messages: [ChatMessage], nextCursor: String?, removedIDs: [String] = []) {
        self.messages = messages
        self.nextCursor = nextCursor
        self.removedIDs = removedIDs
    }
}

public enum MessageTimeline {
    public static func merge(
        _ existing: [ChatMessage], with incoming: [ChatMessage],
        now: Date, blocked: Set<String> = []
    ) -> [ChatMessage] {
        var messages: [String: ChatMessage] = [:]
        for message in existing + incoming
        where message.isValid(at: now) && !blocked.contains(message.senderID) {
            messages[message.id] = message
        }
        return messages.values.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        }
    }
}

public enum MusicLink {
    public static func url(id: String, title: String) -> URL? {
        if !id.isEmpty && id != "0" && id.utf8.count <= 30
            && id.utf8.allSatisfy({ (48...57).contains($0) })
        {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "music.apple.com"
            components.path = "/song/" + id
            return components.url
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.apple.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "term", value: title)]
        return components.url
    }
}
