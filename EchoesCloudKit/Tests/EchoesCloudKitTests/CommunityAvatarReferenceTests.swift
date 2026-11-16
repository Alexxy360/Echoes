import EchoesCore
import Foundation
import Testing

@testable import EchoesCloudKit

private actor MetadataTransport: GatewayHTTPTransport {
    let body: Data
    init(_ body: Data) { self.body = body }
    func send(_ request: URLRequest) async throws -> GatewayHTTPResponse {
        .init(status: 200, contentType: "application/json", body: body)
    }
}
struct NativeCommunityAvatarFixture: Sendable {
    let data: Data
    let ownerID: String
    let versionID: String
    init() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "responses", withExtension: "json", subdirectory: "Fixtures/community-avatar"))
        data = try Data(contentsOf: url)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["schemaVersion"] as? Int == 1)
        ownerID = try #require(root["ownerID"] as? String)
        versionID = try #require(root["versionID"] as? String)
    }
    func object(action: String, phase: String) throws -> [String: Any] {
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        #expect(cases.count == 9)
        return try #require(
            cases.first { $0["action"] as? String == action && $0["phase"] as? String == phase }?["response"]
                as? [String: Any])
    }
    func coordinate() throws -> Coordinate {
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        let entry = try #require(cases.first { $0["action"] as? String == "nearby" })
        let request = try #require(entry["request"] as? [String: Any])
        let value = try #require(request["coordinate"] as? [String: Double])
        return .init(latitude: try #require(value["latitude"]), longitude: try #require(value["longitude"]))
    }
    func reply(action: String, phase: String, altered: Data? = nil) async throws -> GatewayCommunityReply {
        let object = try object(action: action, phase: phase)
        let milliseconds = try #require(object["serverTime"] as? Double)
        let now = Date(timeIntervalSince1970: milliseconds / 1000)
        let client = GatewayCommunityHTTPClient(
            configuration: try .init(origin: URL(string: "https://metadata.example.invalid")!),
            transport: MetadataTransport(try altered ?? JSONSerialization.data(withJSONObject: object)),
            now: { now })
        let operation: GatewayCommunityOperation
        switch action {
        case "profile": operation = .profile
        case "nearby": operation = .nearby(coordinate: try coordinate())
        default: operation = .messages(coordinate: try coordinate(), cursor: nil, knownIDs: [])
        }
        return try await client.perform(
            operation, token: .init(ownerID + "." + String(repeating: "a", count: 43)))
    }
    func photoResponse(revalidated: Bool = false) throws -> GatewayAvatarHTTPResponse {
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let value = try #require(root[revalidated ? "revalidated" : "downloaded"] as? [String: Any])
        let url = try #require(
            Bundle.module.url(
                forResource: "thumbnail", withExtension: "jpg", subdirectory: "Fixtures/community-avatar"))
        return .init(
            status: try #require(value["status"] as? Int),
            headers: try #require(value["headers"] as? [String: String]),
            body: revalidated ? Data() : try Data(contentsOf: url))
    }
}

@Test(arguments: ["published", "cleared", "disabled"])
func nativeCommunityAvatarConsumesConcreteServerProfileMapAndMessageVersions(_ phase: String) async throws {
    let wire = try NativeCommunityAvatarFixture()
    let expected = phase == "published" ? wire.versionID : nil
    guard case .profile(let profile) = try await wire.reply(action: "profile", phase: phase).value,
        case .nearby(let users) = try await wire.reply(action: "nearby", phase: phase).value,
        case .messages(let page) = try await wire.reply(action: "messages", phase: phase).value
    else {
        Issue.record("Missing typed response")
        return
    }
    #expect(profile?.avatarVersionID == expected)
    #expect(users.count == 1 && users[0].avatarVersionID == expected)
    #expect(page.messages.count == 1 && page.messages[0].avatarVersionID == expected)
    let references = [
        profile?.avatarReference(ownerID: wire.ownerID), users[0].avatarReference,
        page.messages[0].avatarReference,
    ]
    for reference in references {
        #expect(reference?.versionID == expected)
        #expect(reference?.ownerID == (expected == nil ? nil : wire.ownerID))
    }
}

@Test func nativeCommunityAvatarRejectsWrongVersionTypesAndNoncanonicalIDs() async throws {
    let wire = try NativeCommunityAvatarFixture()
    let values: [Any] = [
        "", "ABCDEF00-0000-4000-8000-000000000001", "https://example.invalid/photo", wire.versionID + " ", 1,
        true, ["id": wire.versionID], [wire.versionID],
    ]
    for action in ["profile", "nearby", "messages"] {
        for value in values {
            var body = try wire.object(action: action, phase: "published")
            if action == "profile" {
                var object = try #require(body["profile"] as? [String: Any])
                object["avatarVersionID"] = value
                body["profile"] = object
            } else {
                let key = action == "nearby" ? "users" : "messages"
                var rows = try #require(body[key] as? [[String: Any]])
                rows[0]["avatarVersionID"] = value
                body[key] = rows
            }
            let data = try JSONSerialization.data(withJSONObject: body)
            await #expect(throws: GatewayCommunityFailure.invalidResponse) {
                try await wire.reply(action: action, phase: "published", altered: data)
            }
        }
    }
}

@Test func nativeCommunityAvatarRejectsUnknownNestedFieldsAndForgedTopLevelMetadata() async throws {
    let wire = try NativeCommunityAvatarFixture()
    for action in ["profile", "nearby", "messages"] {
        for field in ["downloadURL", "receipt", "ownerID", "avatarManifest"] {
            var body = try wire.object(action: action, phase: "published")
            if action == "profile" {
                var object = try #require(body["profile"] as? [String: Any])
                object[field] = "PRIVATE"
                body["profile"] = object
            } else {
                let key = action == "nearby" ? "users" : "messages"
                var rows = try #require(body[key] as? [[String: Any]])
                rows[0][field] = "PRIVATE"
                body[key] = rows
            }
            let data = try JSONSerialization.data(withJSONObject: body)
            await #expect(throws: GatewayCommunityFailure.invalidResponse) {
                try await wire.reply(action: action, phase: "published", altered: data)
            }
        }
        var body = try wire.object(action: action, phase: "published")
        body["avatarVersionID"] = wire.versionID
        let data = try JSONSerialization.data(withJSONObject: body)
        await #expect(throws: GatewayCommunityFailure.invalidResponse) {
            try await wire.reply(action: action, phase: "published", altered: data)
        }
    }
}

@Test func nativeCommunityAvatarTypedReferencesNeverAcceptAnAssetURLOrInvalidOwner() throws {
    let wire = try NativeCommunityAvatarFixture()
    let position = try wire.coordinate()
    func person(owner: String, version: String?) -> NearbyProfile {
        .init(
            id: owner, name: "Maja", coordinate: position, lastSong: "", appleMusicID: "",
            expiresAt: 1_794_604_200_000, avatarVersionID: version)
    }
    #expect(person(owner: wire.ownerID, version: nil).avatarReference == nil)
    #expect(person(owner: "firebase-legacy-id", version: wire.versionID).avatarReference == nil)
    #expect(person(owner: wire.ownerID, version: "https://example.invalid/photo").avatarReference == nil)
    let reference = try #require(person(owner: wire.ownerID, version: wire.versionID).avatarReference)
    let query = try GatewayAvatarQuery(reference: reference, variant: .thumbnail, coordinate: position)
    let body = try #require(JSONSerialization.jsonObject(with: query.encodedBody()) as? [String: Any])
    #expect(Set(body.keys) == ["ownerID", "versionID", "variant", "coordinate"])
    #expect(body["versionID"] as? String == wire.versionID)
}
