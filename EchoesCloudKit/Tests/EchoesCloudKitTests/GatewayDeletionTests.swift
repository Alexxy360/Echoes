import Foundation
import Testing

@testable import EchoesCloudKit

private let deletionTestID = "30000000-0000-4000-8000-000000000003"
private let deletionAccountID = "40000000-0000-4000-8000-000000000004"
private let deletionChallengeID = "50000000-0000-4000-8000-000000000005"
private let deletionNow = Date(timeIntervalSince1970: 1_800_000_000)
private let deletionOrigin = "https://gateway.example.invalid"
private func deletionTicket() throws -> GatewayDeletionTicket {
    try .init(
        deletionID: deletionTestID,
        statusToken: .init(deletionTestID + "." + String(repeating: "A", count: 43)))
}
private func deletionProof() throws -> GatewayDeletionProof {
    try .init(
        challengeID: deletionChallengeID, identityToken: .init("synthetic-deletion-identity"),
        expectedAccountID: deletionAccountID)
}
private func deletionBody(_ updates: [String: Any] = [:]) throws -> Data {
    var body: [String: Any] = [
        "protocolVersion": 1, "deletionID": deletionTestID, "accountID": deletionAccountID,
        "publicData": "pending", "privateData": "awaiting-device", "appleAuthorization": "pending",
        "localAccount": "blocked", "attentionRequired": false, "completed": false,
    ]
    body.merge(updates) { _, next in next }
    return try JSONSerialization.data(withJSONObject: body)
}
private actor DeletionTransport: GatewayHTTPTransport {
    var requests: [URLRequest] = []
    let response: GatewayHTTPResponse
    let fails: Bool
    init(body: Data, status: Int = 200, fails: Bool = false) {
        response = .init(status: status, contentType: "application/json", body: body)
        self.fails = fails
    }
    func send(_ request: URLRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        if fails { throw GatewayFailure.transport }
        return response
    }
}
private func deletionClient(_ transport: DeletionTransport) throws -> GatewayHTTPClient {
    try .init(
        configuration: .init(origin: URL(string: deletionOrigin)!), transport: transport, now: { deletionNow }
    )
}

@Test func deletionTicketsUseCanonicalRandomProofAndRedactDescriptionsAndReflection() throws {
    let a = try GatewayDeletionTicket.create()
    let b = try GatewayDeletionTicket.create()
    #expect(a != b)
    #expect(a.statusToken.value.count == 80)
    #expect(try JSONDecoder().decode(GatewayDeletionTicket.self, from: JSONEncoder().encode(a)) == a)
    #expect(!String(describing: a).contains(a.statusToken.value))
    #expect(!String(reflecting: a).contains(a.statusToken.value))
    #expect(Mirror(reflecting: a).children.isEmpty)
    for suffix in [
        String(repeating: "A", count: 42), String(repeating: "+", count: 43),
        String(repeating: "A", count: 42) + "B",
    ] {
        #expect(throws: GatewayFailure.invalidInput) {
            try GatewayDeletionTicket(
                deletionID: deletionTestID, statusToken: .init(deletionTestID + "." + suffix))
        }
    }
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            GatewayDeletionTicket.self, from: Data("{\"deletionID\":\"bad\",\"statusToken\":\"bad\"}".utf8))
    }
}

@Test func nativeDeletionRequestAndLostResponseLookupUseOnlyTheTicketAndPurposeBoundProof() async throws {
    let transport = DeletionTransport(body: try deletionBody(), status: 202)
    let client = try deletionClient(transport)
    let ticket = try deletionTicket()
    let proof = try deletionProof()
    #expect(try await client.requestDeletion(ticket: ticket, proof: proof).accountID == deletionAccountID)
    _ = try await client.requestDeletion(ticket: ticket, proof: nil)
    let requests = await transport.requests
    #expect(requests.count == 2)
    for request in requests {
        #expect(request.url?.absoluteString == deletionOrigin + "/v1/account/deletion")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + ticket.statusToken.value)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    }
    let first = try JSONDecoder().decode([String: String].self, from: #require(requests.first?.httpBody))
    #expect(Set(first.keys) == ["deletionID", "challengeID", "identityToken", "expectedAccountID"])
    let second = try JSONDecoder().decode([String: String].self, from: #require(requests.last?.httpBody))
    #expect(second == ["deletionID": deletionTestID])
}

@Test func nativeRecoveryAcceptsOnlyMatchingStatusAndCapabilityWithoutSendingAccessOrAuthorizationCode()
    async throws
{
    let ticket = try deletionTicket()
    let transport = DeletionTransport(body: try deletionBody(["statusToken": ticket.statusToken.value]))
    let client = try deletionClient(transport)
    let proof = try deletionProof()
    let response = try await client.recoverDeletion(proof: proof)
    #expect(response.ticket == ticket)
    #expect(response.status.accountID == deletionAccountID)
    let request = try #require(await transport.requests.first)
    #expect(request.url?.absoluteString == deletionOrigin + "/v1/account/deletion/recover")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let fields = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
    #expect(Set(fields.keys) == ["challengeID", "identityToken", "expectedAccountID"])
    for updates in [
        ["accountID": UUID().uuidString.lowercased(), "statusToken": ticket.statusToken.value],
        ["statusToken": "invalid-ticket"],
        ["statusToken": try GatewayDeletionTicket.create().statusToken.value],
    ] {
        let bad = DeletionTransport(body: try deletionBody(updates))
        await #expect(throws: GatewayFailure.invalidResponse) {
            try await deletionClient(bad).recoverDeletion(proof: proof)
        }
    }
}

@Test func nativeDeletionStatusRejectsForeignIDsUnknownStatesAndContradictoryCompletion() async throws {
    for updates: [String: Any] in [
        ["protocolVersion": 2], ["accountID": "invalid"], ["deletionID": UUID().uuidString.lowercased()],
        ["publicData": "unknown"], ["privateData": "server-verified"],
        ["appleAuthorization": "deleted-apple-account"],
        ["completed": true], ["localAccount": "removed"],
        ["attentionRequired": true, "publicData": "deleted"],
        [
            "completed": true, "localAccount": "removed", "publicData": "deleted",
            "privateData": "device-acknowledged",
        ],
    ] {
        let transport = DeletionTransport(body: try deletionBody(updates))
        await #expect(throws: GatewayFailure.invalidResponse) {
            try await deletionClient(transport).deletionStatus(ticket: deletionTicket())
        }
    }
    let valid = DeletionTransport(
        body: try deletionBody([
            "completed": true, "localAccount": "removed",
            "publicData": "deleted", "privateData": "device-acknowledged",
            "appleAuthorization": "manual-required",
        ]))
    let result = try await deletionClient(valid).deletionStatus(ticket: deletionTicket())
    #expect(result.completed)
    #expect(result.appleAuthorization == .manualRequired)
}

@Test func nativePrivateAcknowledgementRequiresConfirmedDeviceClaimAndKeepsTheNarrowRequestShape()
    async throws
{
    let waiting = DeletionTransport(body: try deletionBody())
    await #expect(throws: GatewayFailure.invalidResponse) {
        try await deletionClient(waiting).acknowledgePrivateCleanup(ticket: deletionTicket())
    }
    let accepted = DeletionTransport(body: try deletionBody(["privateData": "device-acknowledged"]))
    let result = try await deletionClient(accepted).acknowledgePrivateCleanup(ticket: deletionTicket())
    #expect(result.privateData == .deviceAcknowledged)
    let request = try #require(await accepted.requests.first)
    #expect(request.url?.path == "/v1/account/deletion/private-cleanup")
    let body = try JSONDecoder().decode([String: String].self, from: #require(request.httpBody))
    #expect(body == ["deletionID": deletionTestID])
}

@Test func nativeDeletionUsesExactSuccessStatusesAndNeverRetriesAnUnknownResult() async throws {
    let wrong = DeletionTransport(body: try deletionBody())
    await #expect(throws: GatewayFailure.invalidResponse) {
        try await deletionClient(wrong).requestDeletion(ticket: deletionTicket(), proof: deletionProof())
    }
    let absent = DeletionTransport(
        body: Data("{\"protocolVersion\":1,\"error\":\"NO_DELETION\"}".utf8), status: 404)
    await #expect(throws: GatewayFailure.server(.noDeletion, status: 404, retryAfterSeconds: nil)) {
        try await deletionClient(absent).recoverDeletion(proof: deletionProof())
    }
    let lost = DeletionTransport(body: Data(), fails: true)
    await #expect(throws: GatewayFailure.transport) {
        try await deletionClient(lost).recoverDeletion(proof: deletionProof())
    }
    #expect(await lost.requests.count == 1)
}

@Test func nativeDeletionChallengeHasSeparateCreationAndRecoveryPurposes() async throws {
    let body = try JSONSerialization.data(withJSONObject: [
        "protocolVersion": 1, "challengeID": deletionChallengeID,
        "nonce": String(repeating: "A", count: 43), "expiresAt": Int(deletionNow.timeIntervalSince1970) + 300,
    ])
    let transport = DeletionTransport(body: body)
    let client = try deletionClient(transport)
    _ = try await client.deletionChallenge(recovering: false)
    _ = try await client.deletionChallenge(recovering: true)
    let requests = await transport.requests
    let purposes = try requests.map {
        try JSONDecoder().decode([String: String].self, from: #require($0.httpBody))["purpose"]
    }
    #expect(purposes == ["account_deletion", "deletion_recovery"])
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
}

@Test func nativeDeletionActivationFencesEveryCallAndRejectsAnotherOrigin() async throws {
    let activation = try GatewayDevelopmentActivation(
        infoDictionary: [
            "EchoesGatewayDevelopment": [
                "enabled": true, "origin": deletionOrigin,
                "expiresAt": ISO8601DateFormatter().string(from: deletionNow + 60),
                "container": "iCloud.mpvEcho.Echo",
            ]
        ], bundleIdentifier: "mpvEcho.Echo", now: deletionNow)
    let transport = DeletionTransport(body: try deletionBody())
    let client = try deletionClient(transport)
    let expired = try ActivatedGatewayAccountDeletionAPI(
        api: client, activation: activation, now: { deletionNow + 61 })
    await #expect(throws: GatewayFailure.configuration) {
        try await expired.deletionChallenge(recovering: true)
    }
    await #expect(throws: GatewayFailure.configuration) {
        try await expired.requestDeletion(ticket: deletionTicket(), proof: nil)
    }
    await #expect(throws: GatewayFailure.configuration) {
        try await expired.recoverDeletion(proof: deletionProof())
    }
    await #expect(throws: GatewayFailure.configuration) {
        try await expired.deletionStatus(ticket: deletionTicket())
    }
    await #expect(throws: GatewayFailure.configuration) {
        try await expired.acknowledgePrivateCleanup(ticket: deletionTicket())
    }
    #expect(await transport.requests.isEmpty)
    let foreign = try GatewayHTTPClient(
        configuration: .init(origin: URL(string: "https://other.example.invalid")!), transport: transport)
    #expect(throws: GatewayFailure.configuration) {
        try ActivatedGatewayAccountDeletionAPI(api: foreign, activation: activation)
    }
}
