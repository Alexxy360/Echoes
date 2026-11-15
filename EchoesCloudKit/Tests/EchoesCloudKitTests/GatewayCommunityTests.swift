import EchoesCore
import Foundation
import Testing

@testable import EchoesCloudKit

private let communityOrigin = "https://community.example.invalid"
private let communityToken = try! GatewaySecret(
    "11111111-1111-4111-8111-111111111111." + String(repeating: "a", count: 43))
private let communityNow = Date(timeIntervalSince1970: 1_794_603_600)
private let sampleID = "22222222-2222-4222-8222-222222222222"
private let samplePosition = Coordinate(latitude: 51.1123456, longitude: 17.0345678)

private actor CommunityHTTPPlan: GatewayHTTPTransport {
    private let response: GatewayHTTPResponse
    private let hold: Bool
    private var requests: [URLRequest] = []
    private var observer: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<GatewayHTTPResponse, Never>?
    init(
        body: Data, status: Int = 200, type: String = "application/json", retry: String? = nil,
        hold: Bool = false
    ) {
        response = .init(status: status, contentType: type, retryAfter: retry, body: body)
        self.hold = hold
    }
    func send(_ request: URLRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        observer?.resume()
        observer = nil
        if hold { return await withCheckedContinuation { waiting = $0 } }
        return response
    }
    func waitForRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() {
        waiting?.resume(returning: response)
        waiting = nil
    }
    func captured() -> [URLRequest] { requests }
}
private func communityClient(_ plan: CommunityHTTPPlan, now: Date = communityNow) throws
    -> GatewayCommunityHTTPClient
{
    .init(
        configuration: try GatewayConfiguration(origin: URL(string: communityOrigin)!), transport: plan,
        now: { now })
}
private func encoded(_ body: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
}
private func fixtureCases() throws -> [[String: Any]] {
    let url = Bundle.module.url(
        forResource: "community-roundtrip", withExtension: "json", subdirectory: "Fixtures")!
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    #expect(root["version"] as? Int == 1)
    return root["cases"] as! [[String: Any]]
}
private func fixture(_ action: String) throws -> (request: [String: Any], response: [String: Any]) {
    let entry = try fixtureCases().first { $0["action"] as? String == action }!
    return (entry["request"] as! [String: Any], entry["response"] as! [String: Any])
}
private func operation(_ action: String, _ body: [String: Any]) -> GatewayCommunityOperation {
    func position() -> Coordinate {
        let p = body["coordinate"] as! [String: Double]
        return .init(latitude: p["latitude"]!, longitude: p["longitude"]!)
    }
    func string(_ name: String) -> String { body[name] as! String }
    switch action {
    case "config": return .configuration
    case "visibility": return .visibility
    case "blocked": return .blocked
    case "profile": return .profile
    case "publish":
        return .publish(
            requestID: string("requestID"), name: string("name"), coordinate: position(),
            measuredAt: Date(timeIntervalSince1970: (body["measuredAt"] as! Double) / 1000),
            song: string("song"), songID: string("songID"), generation: body["generation"] as! Int)
    case "stop": return .stop(requestID: string("requestID"), generation: body["generation"] as! Int)
    case "nearby": return .nearby(coordinate: position())
    case "messages":
        return .messages(
            coordinate: position(), cursor: body["cursor"] as? String, knownIDs: body["knownIDs"] as! [String]
        )
    case "send":
        return .send(
            requestID: string("requestID"), name: string("name"), text: string("text"), coordinate: position()
        )
    case "block":
        return .block(
            requestID: string("requestID"), accountID: string("accountID"), blocked: body["blocked"] as! Bool,
            generation: body["generation"] as! Int)
    case "block/state": return .blockState(accountID: string("accountID"))
    case "report":
        return .report(
            requestID: string("requestID"), messageID: string("messageID"), reason: string("reason"),
            coordinate: position())
    default:
        return .saveProfile(
            requestID: string("requestID"), name: string("name"), revision: body["revision"] as? String)
    }
}

@Test func nativeCommunityConsumesActualOfflineGatewayResponsesAndEncodesExactlyItsClosedRequests()
    async throws
{
    let cases = try fixtureCases()
    #expect(cases.count == 14)
    for entry in cases {
        let action = entry["action"] as! String
        let body = entry["request"] as! [String: Any]
        let response = entry["response"] as! [String: Any]
        let plan = CommunityHTTPPlan(body: try encoded(response))
        let client = try communityClient(plan)
        let op = operation(action, body)
        let reply = try await client.perform(op, token: communityToken)
        #expect(reply.serverTime == communityNow)
        let request = try #require(await plan.captured().first)
        #expect(request.url?.absoluteString == communityOrigin + "/v1/community/" + action)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + communityToken.value)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(NSDictionary(dictionary: payload).isEqual(to: body))
        let saved = try JSONEncoder().encode(op)
        #expect(try JSONDecoder().decode(GatewayCommunityOperation.self, from: saved) == op)
        switch (action, reply.value) {
        case ("config", .configuration(let address)): #expect(address == nil)
        case ("visibility", .generation(let generation)): #expect(generation == 0)
        case ("publish", .publication(_, let generation, let visible)): #expect(generation == 0 && visible)
        case ("stop", .publication(_, let generation, let visible)): #expect(generation == 1 && !visible)
        case ("nearby", .nearby(let people)):
            #expect(people.count == 1)
            #expect(people.first?.name == "Maja")
        case ("messages", .messages(let page)):
            #expect(page.messages.count == 1)
            #expect(page.nextCursor == nil)
            #expect(page.removedIDs.isEmpty)
        case ("send", .sent(let message)):
            #expect(message.text == body["text"] as? String)
            #expect(message.timestamp == communityNow.timeIntervalSince1970 * 1000)
        case ("blocked", .blocked(let identifiers)): #expect(identifiers.count == 1)
        case ("block/state", .blockState): break
        case ("block", .receipt), ("report", .accepted), ("profile", .profile),
            ("profile/save", .savedProfile):
            break
        default: Issue.record("Unexpected typed community result")
        }
    }
}

@Test func nativeCommunityAcceptsFullUnicodeChatPageAboveTheAuthTransportLimit() async throws {
    var source = try fixture("messages").response
    let base = (source["messages"] as! [[String: Any]])[0]
    source["messages"] = (0..<50).map { index in
        var message = base
        message["id"] = "community-v1-message-" + String(format: "%064x", index)
        message["text"] = String(repeating: "🎵", count: 250)
        return message
    }
    let data = try encoded(source)
    #expect(data.count > 32_768)
    let plan = CommunityHTTPPlan(body: data)
    let client = try communityClient(plan)
    let result = try await client.perform(
        .messages(coordinate: samplePosition, cursor: nil, knownIDs: []), token: communityToken)
    guard case .messages(let page) = result.value else {
        Issue.record("Missing message page")
        return
    }
    #expect(page.messages.count == 50)
}

@Test func nativeCommunityRejectsMalformedOrInconsistentPagesInsteadOfShowingPartialData() async throws {
    let mutations: [(inout [String: Any]) -> Void] = [
        { $0["protocolVersion"] = 2 }, { $0["serverTime"] = 1_794_603_901_000.0 },
        { $0["ownerKey"] = "unexpected" },
        { $0["messages"] = Array(repeating: ($0["messages"] as! [[String: Any]])[0], count: 2) },
        { $0["removedIDs"] = ["community-v1-message-" + String(repeating: "f", count: 64)] },
        { $0["cursor"] = "v1." + String(repeating: "a", count: 20_000) },
        {
            var rows = $0["messages"] as! [[String: Any]]
            rows[0]["expiresAt"] = 1_794_603_600_001.0
            $0["messages"] = rows
        },
        {
            var rows = $0["messages"] as! [[String: Any]]
            rows[0]["text"] = "bad\u{202e}text"
            $0["messages"] = rows
        },
        {
            let base = ($0["messages"] as! [[String: Any]])[0]
            var a = base
            var b = base
            a["id"] = "community-v1-message-" + String(repeating: "f", count: 64)
            b["id"] = "community-v1-message-" + String(repeating: "a", count: 64)
            $0["messages"] = [a, b]
        },
    ]
    for mutate in mutations {
        var source = try fixture("messages").response
        mutate(&source)
        let plan = CommunityHTTPPlan(body: try encoded(source))
        let client = try communityClient(plan)
        await #expect(throws: GatewayCommunityFailure.invalidResponse) {
            try await client.perform(
                .messages(coordinate: samplePosition, cursor: nil, knownIDs: []), token: communityToken)
        }
    }
}

@Test func nativeCommunityChecksNearbyAndMutationAcknowledgements() async throws {
    let near = try fixture("nearby")
    for coordinate in [Coordinate(latitude: 52, longitude: 20)] {
        let plan = CommunityHTTPPlan(body: try encoded(near.response))
        let client = try communityClient(plan)
        await #expect(throws: GatewayCommunityFailure.invalidResponse) {
            try await client.perform(.nearby(coordinate: coordinate), token: communityToken)
        }
    }
    var duplicates = near.response
    duplicates["users"] = Array(repeating: (duplicates["users"] as! [[String: Any]])[0], count: 2)
    let plan = CommunityHTTPPlan(body: try encoded(duplicates))
    let client = try communityClient(plan)
    await #expect(throws: GatewayCommunityFailure.invalidResponse) {
        try await client.perform(.nearby(coordinate: samplePosition), token: communityToken)
    }
    let sent = try fixture("send")
    let op = operation("send", sent.request)
    var changed = sent.response
    var message = changed["message"] as! [String: Any]
    message["text"] = "Obca treść"
    changed["message"] = message
    let badPlan = CommunityHTTPPlan(body: try encoded(changed))
    let badClient = try communityClient(badPlan)
    await #expect(throws: GatewayCommunityFailure.invalidResponse) {
        try await badClient.perform(op, token: communityToken)
    }
    let profile = try fixture("profile/save")
    var profileResponse = profile.response
    profileResponse["name"] = "Inna nazwa"
    let profilePlan = CommunityHTTPPlan(body: try encoded(profileResponse))
    await #expect(throws: GatewayCommunityFailure.invalidResponse) {
        try await communityClient(profilePlan).perform(
            operation("profile/save", profile.request), token: communityToken)
    }
}

@Test func nativeCommunityCanReconcileAnExpiredSendAcknowledgementWithoutInventingANewTimestamp() async throws
{
    let original = try fixture("send")
    var reply = original.response
    let later = communityNow.addingTimeInterval(8000)
    reply["serverTime"] = later.timeIntervalSince1970 * 1000
    let plan = CommunityHTTPPlan(body: try encoded(reply))
    let client = try communityClient(plan, now: later)
    let result = try await client.perform(operation("send", original.request), token: communityToken)
    guard case .sent(let message) = result.value else {
        Issue.record("Missing confirmed send")
        return
    }
    #expect(message.timestamp == communityNow.timeIntervalSince1970 * 1000)
    #expect(message.expiresAt < later.timeIntervalSince1970 * 1000)
    #expect(!message.isValid(at: later))
}

@Test func nativeCommunityRejectsInvalidClientFieldsBeforeAnyTransportCall() async throws {
    let plan = CommunityHTTPPlan(body: Data())
    let client = try communityClient(plan)
    let operations: [GatewayCommunityOperation] = [
        .send(
            requestID: sampleID.uppercased().replacingOccurrences(of: "2222", with: "AAAA"), name: "Maja",
            text: "Treść", coordinate: samplePosition),
        .stop(requestID: sampleID, generation: -1), .nearby(coordinate: .init(latitude: 91, longitude: 0)),
        .messages(coordinate: samplePosition, cursor: "https://elsewhere.invalid", knownIDs: []),
        .messages(
            coordinate: samplePosition, cursor: nil,
            knownIDs: Array(
                repeating: "community-v1-message-" + String(repeating: "a", count: 64), count: 201)),
        .publish(
            requestID: sampleID, name: "Maja", coordinate: samplePosition,
            measuredAt: Date(timeIntervalSince1970: .infinity), song: "", songID: "", generation: 0),
        .saveProfile(requestID: sampleID, name: "Maja", revision: "bad tag"),
    ]
    for op in operations {
        await #expect(throws: GatewayCommunityFailure.invalidInput) {
            try await client.perform(op, token: communityToken)
        }
    }
    await #expect(throws: GatewayCommunityFailure.invalidInput) {
        try await client.perform(.configuration, token: GatewaySecret("not-an-access-token"))
    }
    #expect(await plan.captured().isEmpty)
}

@Test func nativeCommunityUsesClosedErrorsWithoutExposingUpstreamTextAndBoundsTheResponse() async throws {
    for (status, raw, expected) in [
        (429, "COMMUNITY_CAPACITY", GatewayCommunityFailure.limited(retryAfterSeconds: 5)),
        (409, "PUBLIC_PENDING", .stale), (400, "COMMUNITY_TEXT_REJECTED", .textRejected),
        (400, "COMMUNITY_CURSOR", .invalidCursor),
        (503, "PRIVATE-PROVIDER-REASON", .unavailable),
    ] {
        let plan = CommunityHTTPPlan(
            body: try encoded(["protocolVersion": 1, "error": raw, "reason": "PRIVATE-RAW-DETAIL"]),
            status: status, retry: "5")
        let client = try communityClient(plan)
        do {
            _ = try await client.perform(.configuration, token: communityToken)
            Issue.record("Expected service failure")
        } catch {
            #expect(error as? GatewayCommunityFailure == expected)
            #expect(!String(reflecting: error).contains("PRIVATE"))
            #expect(!error.localizedDescription.contains("PRIVATE"))
        }
    }
    for (type, data) in [
        ("text/html", Data("<html>PRIVATE</html>".utf8)),
        ("application/json", Data(repeating: 32, count: 262_145)),
    ] {
        let plan = CommunityHTTPPlan(body: data, type: type)
        let client = try communityClient(plan)
        await #expect(throws: GatewayCommunityFailure.invalidResponse) {
            try await client.perform(.configuration, token: communityToken)
        }
    }
    let authPlan = CommunityHTTPPlan(
        body: try encoded(["protocolVersion": 1, "error": "INVALID_SESSION"]), status: 401)
    await #expect(throws: GatewayFailure.signInRequired) {
        try await communityClient(authPlan).perform(.configuration, token: communityToken)
    }
}

private final class CommunityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = communityNow
    func now() -> Date { lock.withLock { date } }
    func advance() { lock.withLock { date += 61 } }
}
@Test func nativeCommunityActivationAndCancellationFenceLateResponses() async throws {
    let clock = CommunityClock()
    let response = try encoded(fixture("config").response)
    let plan = CommunityHTTPPlan(body: response, hold: true)
    let activation = try GatewayDevelopmentActivation(
        infoDictionary: [
            "EchoesGatewayDevelopment": [
                "enabled": true, "origin": communityOrigin, "container": "iCloud.mpvEcho.Echo",
                "expiresAt": ISO8601DateFormatter().string(from: communityNow.addingTimeInterval(60)),
            ]
        ], bundleIdentifier: "mpvEcho.Echo", now: communityNow)
    let api = try ActivatedGatewayCommunityAPI(
        api: communityClient(plan), activation: activation, now: { clock.now() })
    let task = Task { try await api.perform(.configuration, token: communityToken) }
    await plan.waitForRequest()
    clock.advance()
    await plan.release()
    await #expect(throws: GatewayFailure.configuration) { try await task.value }
    await #expect(throws: GatewayFailure.configuration) {
        try await api.perform(.configuration, token: communityToken)
    }
    #expect(await plan.captured().count == 1)
    let cancelledPlan = CommunityHTTPPlan(body: response, hold: true)
    let client = try communityClient(cancelledPlan)
    let cancelled = Task { try await client.perform(.configuration, token: communityToken) }
    await cancelledPlan.waitForRequest()
    cancelled.cancel()
    await cancelledPlan.release()
    await #expect(throws: GatewayFailure.cancelled) { try await cancelled.value }
}
