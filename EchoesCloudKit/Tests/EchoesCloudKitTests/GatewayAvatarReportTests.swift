import EchoesCore
import Foundation
import Testing

@testable import EchoesCloudKit

let photoReportOrigin = URL(string: "https://photo-report.example.invalid")!
struct PhotoReportWireFixture: Sendable {
    let now: Int, token: GatewaySecret, submission: GatewayAvatarReportSubmission,
        unknown: GatewayAvatarReportIdentity
    let cases: [String: GatewayAvatarReportHTTPResponse]
    init() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "responses", withExtension: "json", subdirectory: "Fixtures/avatar-report"))
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(root["synthetic"] as? String == "owned-local-avatar-report-runtime-v1")
        now = try #require(root["now"] as? Int)
        token = try GatewaySecret(#require(root["token"] as? String))
        let account = try #require(root["accountID"] as? String)
        let input = try #require(root["submit"] as? [String: Any])
        let coordinate = try #require(input["coordinate"] as? [String: Double])
        submission = try .init(
            identity: .init(accountID: account, requestID: #require(input["requestID"] as? String)),
            reference: .init(
                ownerID: #require(input["ownerID"] as? String),
                versionID: #require(input["versionID"] as? String)),
            reason: #require(input["reason"] as? String),
            coordinate: .init(
                latitude: #require(coordinate["latitude"]), longitude: #require(coordinate["longitude"])))
        let unknownInput = try #require(root["unknown"] as? [String: String])
        unknown = try .init(accountID: account, requestID: #require(unknownInput["requestID"]))
        var values: [String: GatewayAvatarReportHTTPResponse] = [:]
        for (key, value) in try #require(root["responses"] as? [String: [String: Any]]) {
            values[key] = .init(
                status: try #require(value["status"] as? Int),
                headers: try #require(value["headers"] as? [String: String]),
                body: Data(try #require(value["body"] as? String).utf8))
        }
        cases = values
    }
}
let photoReportHeaders = [
    "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
]
func photoReportJSON(
    _ fields: [String: Any], status: Int = 200, headers: [String: String] = photoReportHeaders
) throws -> GatewayAvatarReportHTTPResponse {
    try .init(
        status: status, headers: headers,
        body: JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
}
actor PhotoReportStub: GatewayAvatarReportTransport {
    let response: GatewayAvatarReportHTTPResponse
    let effect: (@Sendable () async throws -> Void)?
    var requests: [URLRequest] = []
    init(_ response: GatewayAvatarReportHTTPResponse, effect: (@Sendable () async throws -> Void)? = nil) {
        self.response = response
        self.effect = effect
    }
    func send(_ request: URLRequest, operation: GatewayAvatarReportOperation) async throws
        -> GatewayAvatarReportHTTPResponse
    {
        requests.append(request)
        try await effect?()
        return response
    }
}
func photoReportClient(
    _ transport: any GatewayAvatarReportTransport, clock: ReviewClock, origin: URL = photoReportOrigin
) throws -> GatewayAvatarReportHTTPClient {
    try .init(
        configuration: .init(origin: origin), transport: transport, isEnabled: { clock.enabled() },
        date: { clock.date() }, uptime: { clock.up() })
}

@Test func avatarReportNativeDecodesConcreteRuntimeSubmissionAndBothRecoveryOutcomes() async throws {
    let f = try PhotoReportWireFixture()
    let submit = try await photoReportClient(PhotoReportStub(f.cases["submit"]!), clock: ReviewClock(f.now))
        .submit(f.submission, token: f.token)
    #expect(submit.identity == f.submission.identity && submit.outcome == .accepted)
    let recover = try await photoReportClient(
        PhotoReportStub(f.cases["recover-accepted"]!), clock: ReviewClock(f.now)
    ).recover(f.submission.identity, token: f.token)
    #expect(recover == submit)
    #expect(
        try await photoReportClient(
            PhotoReportStub(f.cases["recover-unconfirmed"]!), clock: ReviewClock(f.now)
        ).recover(f.unknown, token: f.token).outcome == .unconfirmed)
}
@Test func avatarReportNativeWireOmitsReporterPrivilegesHashGenerationAndRecoveryMaterial() async throws {
    let f = try PhotoReportWireFixture()
    let submit = PhotoReportStub(f.cases["submit"]!)
    let recover = PhotoReportStub(f.cases["recover-accepted"]!)
    _ = try await photoReportClient(submit, clock: ReviewClock(f.now)).submit(f.submission, token: f.token)
    _ = try await photoReportClient(recover, clock: ReviewClock(f.now)).recover(
        f.submission.identity, token: f.token)
    let request = try #require(await submit.requests.first)
    let query = try #require(await recover.requests.first)
    let requestData = try #require(request.httpBody)
    let queryData = try #require(query.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
    let recovery = try #require(
        JSONSerialization.jsonObject(with: queryData) as? [String: String])
    #expect(Set(body.keys) == ["requestID", "ownerID", "versionID", "reason", "coordinate"])
    #expect(recovery == ["requestID": f.submission.identity.requestID])
    #expect(
        request.url?.path == "/v1/community/avatar/report"
            && query.url?.path == "/v1/community/avatar/report/recover")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + f.token.value)
    #expect(String(data: query.httpBody!, encoding: .utf8)?.contains(f.submission.reason) == false)
    #expect(
        request.value(forHTTPHeaderField: "Cookie") == nil
            && request.value(forHTTPHeaderField: "Origin") == nil)
}
@Test func avatarReportNativeDefaultDisabledMalformedTokenAndCancelledTaskDoNotDispatch() async throws {
    let f = try PhotoReportWireFixture()
    let stub = PhotoReportStub(f.cases["submit"]!)
    let disabled = try GatewayAvatarReportHTTPClient(
        configuration: .init(origin: photoReportOrigin), transport: stub)
    await #expect(throws: GatewayAvatarReportFailure.unavailable) {
        try await disabled.submit(f.submission, token: f.token)
    }
    for token in ["x", f.token.value.uppercased(), String(f.token.value.prefix(79))] {
        await #expect(throws: GatewayAvatarReportFailure.invalidInput) {
            try await photoReportClient(stub, clock: ReviewClock(f.now)).submit(
                f.submission, token: GatewaySecret(token))
        }
    }
    let task = Task {
        try await Task.sleep(for: .milliseconds(10))
        return try await photoReportClient(stub, clock: ReviewClock(f.now)).submit(
            f.submission, token: f.token)
    }
    task.cancel()
    _ = await task.result
    #expect(await stub.requests.isEmpty)
}
@Test func avatarReportNativeReasonUsesServerNFCTrimUTF16AndControlRules() throws {
    let f = try PhotoReportWireFixture()
    let build: (String) throws -> GatewayAvatarReportSubmission = {
        try .init(
            identity: f.submission.identity, reference: f.submission.reference, reason: $0,
            coordinate: f.submission.coordinate)
    }
    #expect(try build("\u{feff} Cafe\u{0301} \n").reason == "Café")
    #expect(try build(String(repeating: "🎵", count: 250)).reason.utf16.count == 500)
    for reason in [
        " ", String(repeating: "🎵", count: 251), "a\u{0000}b", "a\u{202e}b", "a\u{2068}b",
        String(repeating: "a", count: 501),
    ] {
        #expect(throws: GatewayAvatarReportFailure.invalidInput) { try build(reason) }
    }
}
@Test func avatarReportNativeModelsRejectSelfInvalidCoordinatesAndMalformedIDsAndRedactMaterial() throws {
    let f = try PhotoReportWireFixture()
    for id in ["bad", f.submission.identity.accountID.uppercased()] {
        #expect(throws: GatewayAvatarReportFailure.invalidInput) {
            try GatewayAvatarReportIdentity(accountID: id, requestID: f.unknown.requestID)
        }
    }
    #expect(throws: GatewayAvatarReportFailure.invalidInput) {
        try GatewayAvatarReportSubmission(
            identity: f.submission.identity,
            reference: .init(
                ownerID: f.submission.identity.accountID, versionID: f.submission.reference.versionID),
            reason: "reason", coordinate: f.submission.coordinate)
    }
    for coordinate in [
        Coordinate(latitude: .nan, longitude: 0), .init(latitude: 91, longitude: 0),
        .init(latitude: 0, longitude: .infinity),
    ] {
        #expect(throws: GatewayAvatarReportFailure.invalidInput) {
            try GatewayAvatarReportSubmission(
                identity: f.submission.identity, reference: f.submission.reference, reason: "reason",
                coordinate: coordinate)
        }
    }
    for value: Any in [
        f.submission, f.submission.identity, GatewayAvatarReportOperation.submit(f.submission),
        f.cases["submit"]!,
    ] {
        #expect(String(describing: value).contains("redacted"))
        #expect(Mirror(reflecting: value).children.isEmpty)
    }
}
@Test func avatarReportNativeResponsePinsExactOwnRequestAndRejectsExtraGPSOrWrongOutcomes() async throws {
    let f = try PhotoReportWireFixture()
    let valid = try #require(JSONSerialization.jsonObject(with: f.cases["submit"]!.body) as? [String: Any])
    let otherAccount = try GatewayAvatarReportIdentity(
        accountID: UUID().uuidString.lowercased(), requestID: f.submission.identity.requestID)
    for fields in [
        ["requestID": f.unknown.requestID], ["reportID": otherAccount.reportID],
        ["reportID": "community-v1-report-" + String(repeating: "a", count: 64)], ["reason": "private"],
        ["latitude": 1], ["schemaVersion": true], ["protocolVersion": 2], ["outcome": "unconfirmed"],
        ["outcome": "confirmed"],
    ] as [[String: Any]] {
        let response = try photoReportJSON(valid.merging(fields) { _, n in n })
        await #expect(throws: GatewayAvatarReportFailure.invalidResponse) {
            try await photoReportClient(PhotoReportStub(response), clock: ReviewClock(f.now)).submit(
                f.submission, token: f.token)
        }
    }
}
@Test func avatarReportNativeResponseRejectsBooleanOrMissingVersionNullAndInvalidUTF8() async throws {
    let f = try PhotoReportWireFixture()
    for body in [
        "null", "[]", "{}",
        "{\"protocolVersion\":true,\"schemaVersion\":1,\"requestID\":\"x\",\"reportID\":\"x\",\"outcome\":\"accepted\"}",
    ] {
        let response = GatewayAvatarReportHTTPResponse(
            status: 200, headers: photoReportHeaders, body: Data(body.utf8))
        await #expect(throws: GatewayAvatarReportFailure.invalidResponse) {
            try await photoReportClient(PhotoReportStub(response), clock: ReviewClock(f.now)).recover(
                f.unknown, token: f.token)
        }
    }
    let response = GatewayAvatarReportHTTPResponse(
        status: 200, headers: photoReportHeaders, body: Data([0xff]))
    await #expect(throws: GatewayAvatarReportFailure.invalidResponse) {
        try await photoReportClient(PhotoReportStub(response), clock: ReviewClock(f.now)).recover(
            f.unknown, token: f.token)
    }
}
@Test func avatarReportNativeBoundaryRejectsCacheCompressionRangeMIMEHeaderCollisionsAndLengths() async throws
{
    let f = try PhotoReportWireFixture()
    let valid = f.cases["submit"]!
    for changes in [
        ["Content-Type": "image/jpeg"], ["Cache-Control": "public"], ["Content-Encoding": "gzip"],
        ["Content-Range": "bytes 0-1/2"], ["X-Echoes-Avatar-Selection": "private"],
        ["Content-Length": "2049"], ["Content-Length": "1"], ["Content-Length": "01"],
        ["X-Content-Type-Options": ""], ["CONTENT-TYPE": "application/json"],
    ] {
        let response = GatewayAvatarReportHTTPResponse(
            status: valid.status, headers: photoReportHeaders.merging(changes) { _, n in n }, body: valid.body
        )
        await #expect(throws: GatewayAvatarReportFailure.invalidResponse) {
            try await photoReportClient(PhotoReportStub(response), clock: ReviewClock(f.now)).submit(
                f.submission, token: f.token)
        }
    }
    let large = GatewayAvatarReportHTTPResponse(
        status: 200, headers: photoReportHeaders, body: Data(repeating: 32, count: 2049))
    await #expect(throws: GatewayAvatarReportFailure.invalidResponse) {
        try await photoReportClient(PhotoReportStub(large), clock: ReviewClock(f.now)).recover(
            f.unknown, token: f.token)
    }
}
@Test func avatarReportNativeErrorsBindStatusDomainAndNeverExposeProviderErrorsOrRetryWrite() async throws {
    let f = try PhotoReportWireFixture()
    for (code, status, expected) in [
        ("AVATAR_REPORT_CONFLICT", 409, GatewayAvatarReportFailure.conflict),
        ("AVATAR_REPORT_NOT_FOUND", 404, .notFound),
        ("AVATAR_REPORT_LIMIT", 429, .limited(retryAfterSeconds: 5)),
        ("PUBLIC_REGISTRY_UNVERIFIED", 503, .unavailable), ("ACCOUNT_DISABLED", 403, .denied),
    ] {
        let response = try photoReportJSON(
            ["protocolVersion": 1, "error": code], status: status,
            headers: photoReportHeaders.merging(["Retry-After": "5"]) { _, n in n })
        let stub = PhotoReportStub(response)
        await #expect(throws: expected) {
            try await photoReportClient(stub, clock: ReviewClock(f.now)).submit(f.submission, token: f.token)
        }
        #expect(await stub.requests.count == 1)
    }
    for (code, status) in [
        ("PRIVATE_PROVIDER_ERROR", 503), ("REPORT_REVIEW_SCOPE", 403), ("AVATAR_REPORT_SCOPE", 403),
    ] {
        let response = try photoReportJSON(["protocolVersion": 1, "error": code], status: status)
        await #expect(throws: GatewayAvatarReportFailure.invalidResponse) {
            try await photoReportClient(PhotoReportStub(response), clock: ReviewClock(f.now)).recover(
                f.unknown, token: f.token)
        }
    }
    await #expect(throws: GatewayFailure.signInRequired) {
        try await photoReportClient(PhotoReportStub(f.cases["scope"]!), clock: ReviewClock(f.now)).recover(
            f.unknown, token: f.token)
    }
}
@Test func avatarReportNativeLateDisabledRollbackAndExpiredResponsesCannotClaimAccepted() async throws {
    let f = try PhotoReportWireFixture()
    for mode in ["disabled", "wallRollback", "uptimeRollback", "wallExpiry", "uptimeExpiry"] {
        let clock = ReviewClock(f.now)
        let stub = PhotoReportStub(
            f.cases["submit"]!,
            effect: {
                switch mode {
                case "disabled": clock.disable()
                case "wallRollback": clock.move(wall: -1)
                case "uptimeRollback": clock.move(monotonic: -1)
                case "wallExpiry": clock.move(wall: 15000)
                default: clock.move(monotonic: 15)
                }
            })
        await #expect(throws: GatewayAvatarReportFailure.unavailable) {
            try await photoReportClient(stub, clock: clock).submit(f.submission, token: f.token)
        }
        #expect(await stub.requests.count == 1)
    }
}
@Test func avatarReportNativeUnknownTransportErrorIsRedactedAndRecoveryUsesOnlyOriginalIdentity() async throws
{
    let f = try PhotoReportWireFixture()
    let failing = PhotoReportStub(
        f.cases["submit"]!,
        effect: { throw URLError(.networkConnectionLost, userInfo: ["private": "PRIVATE_PROVIDER_SECRET"]) })
    await #expect(throws: GatewayAvatarReportFailure.unavailable) {
        try await photoReportClient(failing, clock: ReviewClock(f.now)).submit(f.submission, token: f.token)
    }
    #expect(await failing.requests.count == 1)
    let recovery = PhotoReportStub(f.cases["recover-accepted"]!)
    #expect(
        try await photoReportClient(recovery, clock: ReviewClock(f.now)).recover(
            f.submission.identity, token: f.token
        ).outcome == .accepted)
    #expect(await recovery.requests.count == 1)
}

@Test func avatarReportNativeCancellationUsesUUIDOnlyAndDecodesRecoveryOfCancelledAttempt() async throws {
    let f = try PhotoReportWireFixture()
    let stub = PhotoReportStub(f.cases["cancel"]!)
    let result = try await photoReportClient(stub, clock: ReviewClock(f.now)).cancel(
        f.submission.identity, token: f.token)
    #expect(result.identity == f.submission.identity && result.outcome == .cancelled)
    let request = try #require(await stub.requests.first)
    #expect(request.url?.path == "/v1/community/avatar/report/cancel")
    #expect(
        try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
            == ["requestID": f.submission.identity.requestID])
    let recovered = try await photoReportClient(
        PhotoReportStub(f.cases["recover-cancelled"]!), clock: ReviewClock(f.now)
    ).recover(f.submission.identity, token: f.token)
    #expect(recovered == result)
}
@Test func avatarReportNativeCancellationDoesNotAcceptOriginalAcceptedOrUnconfirmedResult() async throws {
    let f = try PhotoReportWireFixture()
    for name in ["submit", "recover-accepted", "recover-unconfirmed"] {
        await #expect(throws: GatewayAvatarReportFailure.invalidResponse) {
            try await photoReportClient(PhotoReportStub(f.cases[name]!), clock: ReviewClock(f.now))
                .cancel(name == "recover-unconfirmed" ? f.unknown : f.submission.identity, token: f.token)
        }
    }
    await #expect(throws: GatewayAvatarReportFailure.invalidResponse) {
        try await photoReportClient(PhotoReportStub(f.cases["cancel"]!), clock: ReviewClock(f.now))
            .submit(f.submission, token: f.token)
    }
}
@Test func avatarReportNativeCancellationRechecksActivationAfterIOAndDoesNotRetry() async throws {
    let f = try PhotoReportWireFixture()
    let clock = ReviewClock(try PhotoReportWireFixture().now)
    let stub = PhotoReportStub(f.cases["cancel"]!, effect: { clock.disable() })
    await #expect(throws: GatewayAvatarReportFailure.unavailable) {
        try await photoReportClient(stub, clock: clock).cancel(f.submission.identity, token: f.token)
    }
    #expect(await stub.requests.count == 1)
}
