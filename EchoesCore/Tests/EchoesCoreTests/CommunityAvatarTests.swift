import Foundation
import Testing

@testable import EchoesCore

private let versionA = "68000000-0000-4000-8000-000000000001"
private let versionB = "68000000-0000-4000-8000-000000000002"
private let photoNow = Date(timeIntervalSince1970: 1_794_603_600)
private func profile(_ version: String?) -> NearbyProfile {
    .init(
        id: "legacy-peer", name: "Maja", coordinate: .init(latitude: 51, longitude: 17),
        lastSong: "", appleMusicID: "", expiresAt: 1_794_604_200_000, avatarVersionID: version)
}
private func message(_ version: String?) -> ChatMessage {
    .init(
        id: "legacy-message", text: "Hej", senderName: "Maja", senderID: "legacy-peer",
        timestamp: 1_794_603_599_000, expiresAt: 1_794_610_799_000, avatarVersionID: version)
}

@Test func communityAvatarModelsDecodeLegacyJSONAndRoundTripOptionalVersions() throws {
    for version in [nil, versionA] {
        let person = profile(version)
        let item = message(version)
        #expect(try JSONDecoder().decode(NearbyProfile.self, from: JSONEncoder().encode(person)) == person)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(item)) == item)
        #expect(person.isValid(at: photoNow) && item.isValid(at: photoNow))
    }
    var person = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(profile(versionA))) as? [String: Any])
    var item = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(message(versionA))) as? [String: Any])
    person.removeValue(forKey: "avatarVersionID")
    item.removeValue(forKey: "avatarVersionID")
    #expect(
        try JSONDecoder().decode(NearbyProfile.self, from: JSONSerialization.data(withJSONObject: person))
            .avatarVersionID == nil)
    #expect(
        try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: item))
            .avatarVersionID == nil)
}

@Test func communityAvatarModelsRejectNoncanonicalVersionsDuringValidation() {
    for value in [
        "", versionA.uppercased().replacingOccurrences(of: "6800", with: "ABCD"),
        "https://example.invalid/photo", versionA + " ", String(repeating: "a", count: 1000),
    ] {
        #expect(!profile(value).isValid(at: photoNow))
        #expect(!message(value).isValid(at: photoNow))
        #expect(MessageTimeline.merge([], with: [message(value)], now: photoNow).isEmpty)
    }
}

@Test func communityAvatarEqualityAndTimelineReplaceOrClearVersionsWithoutChangingMessageIdentity() {
    #expect(profile(versionA) != profile(versionB) && profile(versionA) != profile(nil))
    #expect(message(versionA) != message(versionB) && message(versionA) != message(nil))
    let updated = MessageTimeline.merge([message(versionA)], with: [message(versionB)], now: photoNow)
    #expect(updated.count == 1 && updated[0].avatarVersionID == versionB)
    let cleared = MessageTimeline.merge(updated, with: [message(nil)], now: photoNow)
    #expect(cleared.count == 1 && cleared[0].avatarVersionID == nil)
    #expect(MessageTimeline.merge(cleared, with: [], now: photoNow, blocked: ["legacy-peer"]).isEmpty)
}
