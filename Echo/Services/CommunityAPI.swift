import EchoesCore
import FirebaseAuth
import FirebaseCore
import FirebaseFunctions
import Foundation

enum CommunityFailure: LocalizedError {
    case unavailable, response, notConnected
    var errorDescription: String? {
        switch self {
        case .unavailable: "Usługa jest chwilowo niedostępna. Spróbuj ponownie później."
        case .response: "Nie udało się odczytać danych. Spróbuj ponownie."
        case .notConnected: "Połącz się ponownie, aby korzystać z okolicy."
        }
    }
}

@MainActor
final class FirebaseCommunityAPI: CommunityClient {
    private(set) var serverTimeOffset: TimeInterval = 0
    private var functions: Functions { Functions.functions(region: "europe-west1") }

    func connect() async throws -> String {
        guard FirebaseApp.app() != nil else { throw CommunityFailure.unavailable }
        let auth = Auth.auth()
        if let user = auth.currentUser { return user.uid }
        return try await auth.signInAnonymously().user.uid
    }

    private func call(_ name: String, _ payload: [String: Any] = [:]) async throws -> Any {
        guard FirebaseApp.app() != nil, Auth.auth().currentUser != nil else {
            throw CommunityFailure.notConnected
        }
        let function = functions.httpsCallable(name)
        function.timeoutInterval = 20
        do {
            let started = Date()
            let result = try await function.call(payload).data
            if let milliseconds = (result as? [String: Any])?["serverTime"] as? Double,
                milliseconds.isFinite
            {
                let midpoint = started.timeIntervalSince1970 + Date().timeIntervalSince(started) / 2
                serverTimeOffset = milliseconds / 1000 - midpoint
            }
            return result
        } catch {
            let nsError = error as NSError
            if nsError.domain == FunctionsErrorDomain,
                let code = FunctionsErrorCode(rawValue: nsError.code),
                [
                    .invalidArgument, .resourceExhausted, .permissionDenied, .failedPrecondition,
                    .alreadyExists,
                ].contains(code)
            {
                throw error
            }
            throw CommunityFailure.unavailable
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        guard JSONSerialization.isValidJSONObject(value) else { throw CommunityFailure.response }
        do {
            return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
        } catch { throw CommunityFailure.response }
    }

    private func locationPayload(_ coordinate: Coordinate) -> [String: Double] {
        ["latitude": coordinate.latitude, "longitude": coordinate.longitude]
    }

    func configuration() async throws -> URL? {
        let value = try await call("communityConfig") as? [String: Any]
        guard let raw = value?["supportURL"] as? String,
            let url = URL(string: raw), ["https", "mailto"].contains(url.scheme)
        else { return nil }
        return url
    }

    func visibilityGeneration() async throws -> Int {
        guard let data = try await call("communityVisibility") as? [String: Any],
            let generation = data["generation"] as? Int
        else { throw CommunityFailure.response }
        return generation
    }

    func publish(
        name: String, coordinate: Coordinate, measuredAt: Date,
        song: String, songID: String, generation: Int
    ) async throws {
        _ = try await call(
            "communityPublish",
            [
                "name": name, "coordinate": locationPayload(coordinate),
                "measuredAt": (measuredAt.timeIntervalSince1970 + serverTimeOffset) * 1000,
                "lastSong": song,
                "appleMusicID": songID, "generation": generation,
            ])
    }

    func stopSharing() async throws -> Int {
        guard let value = try await call("communityStopSharing") as? [String: Any],
            let generation = value["generation"] as? Int
        else { throw CommunityFailure.response }
        return generation
    }

    func nearby(coordinate: Coordinate) async throws -> [NearbyProfile] {
        struct Response: Decodable { let users: [NearbyProfile] }
        return try decode(
            Response.self,
            from: await call("communityNearby", ["coordinate": locationPayload(coordinate)])
        ).users
    }

    func messages(coordinate: Coordinate, cursor: String?, knownIDs: [String]) async throws
        -> MessagePage
    {
        var data: [String: Any] = [
            "coordinate": locationPayload(coordinate), "knownIDs": Array(knownIDs.prefix(200)),
        ]
        if let cursor { data["cursor"] = cursor }
        return try decode(MessagePage.self, from: await call("communityMessages", data))
    }

    func send(text: String, name: String, coordinate: Coordinate, requestID: String) async throws
        -> ChatMessage
    {
        try decode(
            ChatMessage.self,
            from: await call(
                "communitySend",
                [
                    "text": text, "name": name,
                    "coordinate": locationPayload(coordinate), "requestID": requestID,
                ]))
    }

    func block(userID: String, blocked: Bool) async throws {
        _ = try await call("communityBlock", ["userID": userID, "blocked": blocked])
    }

    func blockedUsers() async throws -> [String] {
        guard let data = try await call("communityBlockedUsers") as? [String: Any],
            let ids = data["userIDs"] as? [String]
        else { throw CommunityFailure.response }
        return ids
    }

    func report(messageID: String, reason: String) async throws {
        _ = try await call("communityReport", ["messageID": messageID, "reason": reason])
    }

    func deleteOwnData() async throws {
        _ = try await call("communityDeleteOwnData")
        try Auth.auth().signOut()
    }
}
