import Foundation
import Testing

@testable import EchoesCore

@Test func validationRejectsWhitespaceOversizeAndControls() throws {
    #expect(throws: ValidationError.self) { try InputValidation.name(" \n ") }
    #expect(throws: ValidationError.self) {
        try InputValidation.message(String(repeating: "a", count: 501))
    }
    #expect(throws: ValidationError.self) { try InputValidation.message("hej\u{202E}abc") }
    #expect(try InputValidation.name("  Żółw  ") == "Żółw")
    #expect(try InputValidation.message(" Pierwsza\ndruga ") == "Pierwsza\ndruga")
}

@Test func rejectsOldInaccurateAndFutureLocations() {
    let now = Date()
    let coordinate = Coordinate(latitude: 51.1, longitude: 17.0)
    #expect(
        InputValidation.usableLocation(coordinate: coordinate, accuracy: 10, measuredAt: now, now: now))
    #expect(
        !InputValidation.usableLocation(coordinate: coordinate, accuracy: -1, measuredAt: now, now: now)
    )
    #expect(
        !InputValidation.usableLocation(
            coordinate: coordinate, accuracy: 501, measuredAt: now, now: now))
    #expect(
        !InputValidation.usableLocation(
            coordinate: coordinate, accuracy: 10, measuredAt: now.addingTimeInterval(-61), now: now))
    #expect(
        !InputValidation.usableLocation(
            coordinate: coordinate, accuracy: 10, measuredAt: now.addingTimeInterval(6), now: now))
    #expect(!Coordinate(latitude: .nan, longitude: 0).isValid)
    #expect(!Coordinate(latitude: 91, longitude: 0).isValid)
}

@Test func distanceHandlesDateLineAndRadius() {
    let a = Coordinate(latitude: 0, longitude: 179.99)
    let b = Coordinate(latitude: 0, longitude: -179.99)
    #expect(a.distance(to: b) > 2_200 && a.distance(to: b) < 2_230)
    #expect(a.distance(to: a) == 0)
    #expect(Coordinate(latitude: 90.1, longitude: 0).distance(to: b) == .infinity)
}

@Test func searchPreservesOneCompleteQueryParameter() throws {
    let title = "Żółw & Artist # Remix + live"
    let url = try #require(MusicLink.url(id: "bad#id", title: title))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.queryItems == [URLQueryItem(name: "term", value: title)])
    #expect(components.fragment == nil)
    #expect(MusicLink.url(id: "123456", title: title)?.path == "/song/123456")
    #expect(MusicLink.url(id: "0", title: " ") == nil)
}

@Test func timelineKeepsNewestBeyondHundredAndExpiresWithoutNewEvents() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func message(_ i: Int, sender: String = "sender", expiry: Double = 1_007_200_000) -> ChatMessage {
        .init(
            id: "m\(i)", text: "Hej \(i)", senderName: "Gość", senderID: sender,
            timestamp: 999_000_000 + Double(i), expiresAt: expiry)
    }
    let old = (0..<100).map { message($0) }
    let result = MessageTimeline.merge(old, with: [message(100), message(99)], now: now)
    #expect(result.count == 101)
    #expect(result.last?.id == "m100")
    #expect(MessageTimeline.merge(result, with: [], now: now.addingTimeInterval(8_000)).isEmpty)
    #expect(MessageTimeline.merge(result, with: [], now: now, blocked: ["sender"]).isEmpty)
}
