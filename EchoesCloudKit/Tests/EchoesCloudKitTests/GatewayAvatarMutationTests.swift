import CryptoKit
import Foundation
import Testing

@testable import EchoesCloudKit

let mutationRequestID = "69000000-0000-4000-8000-000000000001"
let mutationVersionID = "69000000-0000-4000-8000-000000000002"
let mutationRevisionID = "69000000-0000-4000-8000-000000000003"
let mutationBearer = try! GatewaySecret(
    "69000000-0000-4000-8000-000000000099." + String(repeating: "a", count: 43))
let mutationOrigin = URL(string: "https://avatar-mutation.example.invalid")!
let mutationHeaders = [
    "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
]

func mutationBody(_ status: GatewayAvatarOwnerStatus = .pendingReview) -> [String: Any] {
    [
        "protocolVersion": 1, "generation": status == .none ? 0 : 1,
        "requestID": status == .none ? NSNull() : mutationRequestID,
        "versionID": status == .none || status == .clearing ? NSNull() : mutationVersionID,
        "publishedVersionID": status == .published ? mutationVersionID : NSNull(), "status": status.rawValue,
        "reviewRevision": status == .none || status == .clearing ? NSNull() : mutationRevisionID,
    ]
}
func mutationResponse(
    _ body: [String: Any] = mutationBody(), status: Int = 200, headers: [String: String] = mutationHeaders
) throws -> GatewayAvatarHTTPResponse {
    .init(status: status, headers: headers, body: try JSONSerialization.data(withJSONObject: body))
}
func mutationUpload(_ image: Data = Data([0xff, 0xd8, 0xff, 0xd9])) throws -> GatewayAvatarMutation {
    .upload(
        intent: try .init(requestID: mutationRequestID, versionID: mutationVersionID, expectedGeneration: 0),
        image: image)
}
actor MutationHTTPStub: GatewayAvatarMutationTransport {
    let response: GatewayAvatarHTTPResponse
    let effect: (@Sendable () async -> Void)?
    var requests: [URLRequest] = []
    var uploads: [Bool] = []
    init(_ response: GatewayAvatarHTTPResponse, effect: (@Sendable () async -> Void)? = nil) {
        self.response = response
        self.effect = effect
    }
    func send(_ request: URLRequest, isUpload: Bool) async throws -> GatewayAvatarHTTPResponse {
        requests.append(request)
        uploads.append(isUpload)
        await effect?()
        return response
    }
}
func mutationClient(_ transport: any GatewayAvatarMutationTransport) throws -> GatewayAvatarMutationHTTPClient
{
    try .init(configuration: .init(origin: mutationOrigin), transport: transport, isEnabled: { true })
}
struct MutationWireCase: Sendable {
    let label: String
    let operation: GatewayAvatarMutation
    let response: GatewayAvatarHTTPResponse
}
struct MutationWireFixture: Sendable {
    let image: Data
    let cases: [MutationWireCase]
    init() throws {
        let directory = "Fixtures/avatar-mutation"
        let url = try #require(
            Bundle.module.url(forResource: "responses", withExtension: "json", subdirectory: directory))
        let picture = try #require(
            Bundle.module.url(forResource: "source", withExtension: "jpg", subdirectory: directory))
        let source = try Data(contentsOf: picture)
        image = source
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(raw["schemaVersion"] as? Int == 1)
        #expect(
            raw["imageSHA256"] as? String
                == SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined())
        let rows = try #require(raw["cases"] as? [[String: Any]])
        cases = try rows.map { row in
            let action = try #require(row["action"] as? String)
            let input = try #require(row["input"] as? [String: Any])
            let operation: GatewayAvatarMutation
            switch action {
            case "upload":
                operation = .upload(
                    intent: try .init(
                        requestID: #require(input["requestID"] as? String),
                        versionID: #require(input["versionID"] as? String),
                        expectedGeneration: #require(input["expectedGeneration"] as? Int),
                        consentVersion: #require(input["consentVersion"] as? Int)), image: source)
            case "recover": operation = .recover(requestID: try #require(input["requestID"] as? String))
            case "publish": operation = .publish(requestID: try #require(input["requestID"] as? String))
            case "clear":
                operation = .clear(
                    requestID: try #require(input["requestID"] as? String),
                    expectedGeneration: try #require(input["expectedGeneration"] as? Int))
            case "status": operation = .status
            default: throw GatewayAvatarMutationFailure.invalidResponse
            }
            return try .init(
                label: #require(row["label"] as? String), operation: operation,
                response: .init(
                    status: #require(row["status"] as? Int),
                    headers: #require(row["headers"] as? [String: String]),
                    body: JSONSerialization.data(withJSONObject: #require(row["body"] as? [String: Any]))))
        }
    }
    func entry(_ label: String) throws -> MutationWireCase { try #require(cases.first { $0.label == label }) }
}

@Test func avatarMutationConcreteServerFixtureCoversUploadRecoveryReviewPublicationAndWithdrawal()
    async throws
{
    let fixture = try MutationWireFixture()
    #expect(fixture.cases.count == 10)
    for row in fixture.cases {
        let transport = MutationHTTPStub(row.response)
        let client = try mutationClient(transport)
        switch row.label {
        case "publish-pending":
            await #expect(throws: GatewayAvatarMutationFailure.pending) {
                try await client.perform(row.operation, token: mutationBearer)
            }
        case "upload-disabled":
            await #expect(throws: GatewayAvatarMutationFailure.unavailable) {
                try await client.perform(row.operation, token: mutationBearer)
            }
        case "clear-stale":
            await #expect(throws: GatewayAvatarMutationFailure.stale) {
                try await client.perform(row.operation, token: mutationBearer)
            }
        default:
            let snapshot = try await client.perform(row.operation, token: mutationBearer)
            switch row.label {
            case "upload-pending", "recover-pending":
                #expect(snapshot.status == .pendingReview && snapshot.publishedVersionID == nil)
            case "status-approved":
                #expect(snapshot.status == .approved && snapshot.publishedVersionID == nil)
            case "publish-published":
                #expect(snapshot.status == .published && snapshot.publishedVersionID == snapshot.versionID)
            default: #expect(snapshot.status == .none && snapshot.versionID == nil)
            }
        }
        #expect(await transport.requests.count == 1)
    }
}

@Test func avatarMutationUploadSendsExactBinarySourceAndClosedIntentWithoutOwnerOrProviderMetadata()
    async throws
{
    let fixture = try MutationWireFixture()
    let row = try fixture.entry("upload-pending")
    let transport = MutationHTTPStub(row.response)
    _ = try await mutationClient(transport).perform(row.operation, token: mutationBearer)
    let request = try #require(await transport.requests.first)
    #expect(request.url?.absoluteString == mutationOrigin.absoluteString + "/v1/community/avatar/upload")
    #expect(request.httpMethod == "POST" && request.httpBody == fixture.image)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
    #expect(request.value(forHTTPHeaderField: "Content-Length") == String(fixture.image.count))
    let header = try #require(request.value(forHTTPHeaderField: "X-Echoes-Avatar-Intent"))
    let fields = try #require(JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any])
    #expect(Set(fields.keys) == Set(["requestID", "versionID", "expectedGeneration", "consentVersion"]))
    #expect(header.utf8.count <= 512 && header.utf8.allSatisfy { (32...126).contains($0) })
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + mutationBearer.value)
    #expect(
        request.value(forHTTPHeaderField: "Cookie") == nil
            && request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    #expect(await transport.uploads == [true])
}

@Test func avatarMutationControlActionsUseOnlyTheirClosedJSONAndNeverAnUploadHeader() async throws {
    let fixture = try MutationWireFixture()
    for label in ["status-empty", "recover-pending", "publish-published", "clear-upload-disabled"] {
        let row = try fixture.entry(label)
        let transport = MutationHTTPStub(row.response)
        _ = try await mutationClient(transport).perform(row.operation, token: mutationBearer)
        let request = try #require(await transport.requests.first)
        let body = try #require(request.httpBody)
        #expect(try body == row.operation.wire().body && body.count <= 512)
        #expect(request.value(forHTTPHeaderField: "X-Echoes-Avatar-Intent") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
        #expect(request.url?.path == "/v1/community/avatar/" + row.operation.action)
        #expect(await transport.uploads == [false])
    }
}

@Test func avatarMutationInputAndBearerFailuresNeverDispatchOrGenerateNewIdentifiers() async throws {
    for intent in [
        ("bad", mutationVersionID, 0, 1), (mutationRequestID, "bad", 0, 1),
        (mutationRequestID, mutationVersionID, -1, 1),
        (mutationRequestID, mutationVersionID, 9_007_199_254_740_991, 1),
        (mutationRequestID, mutationVersionID, 0, 0),
    ] {
        #expect(throws: GatewayAvatarMutationFailure.invalidInput) {
            try GatewayAvatarUploadIntent(
                requestID: intent.0, versionID: intent.1, expectedGeneration: intent.2,
                consentVersion: intent.3)
        }
    }
    let transport = MutationHTTPStub(try mutationResponse())
    let client = try mutationClient(transport)
    let intent = try GatewayAvatarUploadIntent(
        requestID: mutationRequestID, versionID: mutationVersionID, expectedGeneration: 0)
    for operation in [
        GatewayAvatarMutation.recover(requestID: "bad"), .publish(requestID: "bad"),
        .clear(requestID: mutationRequestID, expectedGeneration: -1), .upload(intent: intent, image: Data()),
        .upload(intent: intent, image: Data(repeating: 0, count: 256001)),
        .upload(intent: intent, image: Data([0xff, 0xd8, 0, 0])),
    ] {
        await #expect(throws: GatewayAvatarMutationFailure.invalidInput) {
            try await client.perform(operation, token: mutationBearer)
        }
    }
    for raw in [
        "short", mutationRequestID + "." + String(repeating: "!", count: 43),
        "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF." + String(repeating: "a", count: 43),
    ] {
        await #expect(throws: GatewayAvatarMutationFailure.invalidInput) {
            try await client.perform(.status, token: GatewaySecret(raw))
        }
    }
    #expect(await transport.requests.isEmpty)
}

@Test func avatarMutationSnapshotsPreserveAllOwnerStatesWithoutTreatingApprovalAsPublication() throws {
    for status in [
        GatewayAvatarOwnerStatus.none, .clearing, .uploading, .pendingReview, .approved, .rejected,
        .published,
    ] {
        let data = try JSONSerialization.data(withJSONObject: mutationBody(status))
        let snapshot = try GatewayAvatarOwnerSnapshot(data: data)
        #expect(snapshot.status == status)
        #expect((snapshot.publishedVersionID != nil) == (status == .published))
    }
}

@Test func avatarMutationSnapshotRejectsOpenSchemaBooleanCountersMissingNullsAndInconsistentStates() throws {
    let base = mutationBody()
    for changes: [String: Any] in [
        ["url": "https://attacker.invalid"], ["receipt": "private"], ["protocolVersion": 2],
        ["generation": true],
        ["generation": -1], ["generation": 9_007_199_254_740_992], ["generation": 0], ["requestID": NSNull()],
        ["status": "pending"], ["status": "none"], ["status": "clearing"], ["versionID": NSNull()],
        ["reviewRevision": NSNull()],
        ["publishedVersionID": mutationVersionID],
        ["status": "published", "publishedVersionID": mutationRequestID], ["requestID": "bad"],
    ] {
        let data = try JSONSerialization.data(withJSONObject: base.merging(changes) { _, new in new })
        #expect(throws: GatewayAvatarMutationFailure.invalidResponse) {
            try GatewayAvatarOwnerSnapshot(data: data)
        }
    }
    for key in base.keys {
        var fields = base
        fields.removeValue(forKey: key)
        #expect(throws: GatewayAvatarMutationFailure.invalidResponse) {
            try GatewayAvatarOwnerSnapshot(data: JSONSerialization.data(withJSONObject: fields))
        }
    }
}

@Test func avatarMutationRejectsUploadResponseForDifferentRequestVersionOrGeneration() async throws {
    for changes: [String: Any] in [
        ["requestID": mutationRevisionID], ["versionID": mutationRevisionID], ["generation": 2],
        ["status": "uploading"],
    ] {
        let transport = MutationHTTPStub(
            try mutationResponse(mutationBody().merging(changes) { _, new in new }))
        await #expect(throws: GatewayAvatarMutationFailure.invalidResponse) {
            try await mutationClient(transport).perform(mutationUpload(), token: mutationBearer)
        }
    }
}

@Test func avatarMutationRecoveryPublicationAndClearRequireTheirExactAcknowledgements() async throws {
    var clear = mutationBody(.none)
    clear["generation"] = 2
    clear["requestID"] = mutationRequestID
    let pairs: [(GatewayAvatarMutation, [String: Any])] = [
        (.recover(requestID: mutationRevisionID), mutationBody()),
        (.recover(requestID: mutationRequestID), mutationBody(.clearing)),
        (.publish(requestID: mutationRequestID), mutationBody(.approved)),
        (.clear(requestID: mutationRequestID, expectedGeneration: 0), clear),
        (.clear(requestID: mutationRevisionID, expectedGeneration: 1), clear),
    ]
    for (operation, body) in pairs {
        let transport = MutationHTTPStub(try mutationResponse(body))
        await #expect(throws: GatewayAvatarMutationFailure.invalidResponse) {
            try await mutationClient(transport).perform(operation, token: mutationBearer)
        }
    }
}

final class MutationSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func disable() { lock.withLock { value = false } }
    func enabled() -> Bool { lock.withLock { value } }
}
actor MutationGate {
    private var entered = false, released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered = true
        let entries = arrivals
        arrivals.removeAll()
        for value in entries { value.resume() }
        if !released { await withCheckedContinuation { waiting.append($0) } }
    }
    func wait() async { if !entered { await withCheckedContinuation { arrivals.append($0) } } }
    func release() {
        released = true
        let values = waiting
        waiting.removeAll()
        for value in values { value.resume() }
    }
}

@Test func avatarMutationIsDisabledByDefaultAndRechecksActivationAfterAwait() async throws {
    let disabled = MutationHTTPStub(try mutationResponse(mutationBody(.none)))
    let client = try GatewayAvatarMutationHTTPClient(
        configuration: .init(origin: mutationOrigin), transport: disabled)
    await #expect(throws: GatewayAvatarMutationFailure.unavailable) {
        try await client.perform(.status, token: mutationBearer)
    }
    #expect(await disabled.requests.isEmpty)
    let flag = MutationSwitch()
    let transport = MutationHTTPStub(try mutationResponse(mutationBody(.none)), effect: { flag.disable() })
    let active = try GatewayAvatarMutationHTTPClient(
        configuration: .init(origin: mutationOrigin), transport: transport, isEnabled: { flag.enabled() })
    await #expect(throws: GatewayAvatarMutationFailure.unavailable) {
        try await active.perform(.status, token: mutationBearer)
    }
    #expect(await transport.requests.count == 1)
}

@Test func avatarMutationCancellationBeforeAndAfterAnIgnoringAwaitNeverAcceptsTheReply() async throws {
    let gate = MutationGate()
    let transport = MutationHTTPStub(
        try mutationResponse(mutationBody(.none)), effect: { await gate.enter() })
    let client = try mutationClient(transport)
    let task = Task { try await client.perform(.status, token: mutationBearer) }
    await gate.wait()
    task.cancel()
    await gate.release()
    await #expect(throws: GatewayFailure.cancelled) { try await task.value }
    #expect(await transport.requests.count == 1)
    let already = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await client.perform(.status, token: mutationBearer)
    }
    await #expect(throws: GatewayFailure.cancelled) { try await already.value }
    #expect(await transport.requests.count == 1)
}

@Test func avatarMutationMapsClosedErrorCodesAndNeverAutomaticallyRetries() async throws {
    let cases: [(String, Int, GatewayAvatarMutationFailure)] = [
        ("AVATAR_INPUT", 400, .invalidInput), ("AVATAR_STALE", 409, .stale),
        ("AVATAR_PENDING", 409, .pending),
        ("AVATAR_REJECTED", 409, .rejected), ("AVATAR_SCOPE", 403, .denied),
        ("BODY_TOO_LARGE", 413, .invalidInput),
        ("UNSUPPORTED_MEDIA_TYPE", 415, .invalidInput), ("AVATAR_RATE", 429, .limited(retryAfterSeconds: 5)),
        ("FEATURE_DISABLED", 503, .unavailable), ("AVATAR_RESPONSE", 503, .unavailable),
    ]
    for (code, status, failure) in cases {
        let transport = MutationHTTPStub(
            try mutationResponse(
                ["protocolVersion": 1, "error": code], status: status,
                headers: mutationHeaders.merging(["Retry-After": "5"]) { _, n in n }))
        await #expect(throws: failure) {
            try await mutationClient(transport).perform(.status, token: mutationBearer)
        }
        #expect(await transport.requests.count == 1)
    }
    for (code, status) in [("INVALID_SESSION", 401), ("ACCOUNT_DISABLED", 403)] {
        let transport = MutationHTTPStub(
            try mutationResponse(["protocolVersion": 1, "error": code], status: status))
        await #expect(throws: GatewayFailure.signInRequired) {
            try await mutationClient(transport).perform(.status, token: mutationBearer)
        }
    }
}

@Test func avatarMutationRejectsOpenMalformedOrStatusMismatchedErrorEnvelopes() async throws {
    for (body, status): ([String: Any], Int) in [
        (["protocolVersion": 1, "error": "UNKNOWN"], 503),
        (["protocolVersion": 1, "error": "INVALID_SESSION"], 503),
        (["protocolVersion": 1, "error": "AVATAR_PENDING", "receipt": "private"], 409),
        (["protocolVersion": true, "error": "AVATAR_PENDING"], 409), (["error": "AVATAR_PENDING"], 409),
    ] {
        let transport = MutationHTTPStub(try mutationResponse(body, status: status))
        await #expect(throws: GatewayAvatarMutationFailure.invalidResponse) {
            try await mutationClient(transport).perform(.status, token: mutationBearer)
        }
    }
    for retry in ["-1", "999999", "1.5", "+3", "text"] {
        let transport = MutationHTTPStub(
            try mutationResponse(
                ["protocolVersion": 1, "error": "AVATAR_RATE"], status: 429,
                headers: mutationHeaders.merging(["Retry-After": retry]) { _, n in n }))
        await #expect(throws: GatewayAvatarMutationFailure.limited(retryAfterSeconds: nil)) {
            try await mutationClient(transport).perform(.status, token: mutationBearer)
        }
    }
}

@Test func avatarMutationResponseBoundaryRejectsAmbiguousUnsafeHeadersAndUnexpectedStatuses() async throws {
    for changes in [
        ["content-type": "application/json"], ["Content-Type": "text/html"], ["Content-Encoding": "gzip"],
        ["Cache-Control": "public"], ["X-Content-Type-Options": "wrong"], ["Content-Range": "bytes 1-3/8"],
        ["Content-Length": "2049"], ["Content-Length": "0"], ["Content-Length": "+1"],
        ["Content-Length": "2"],
    ] {
        let transport = MutationHTTPStub(
            try mutationResponse(mutationBody(.none), headers: mutationHeaders.merging(changes) { _, n in n })
        )
        await #expect(throws: GatewayAvatarMutationFailure.invalidResponse) {
            try await mutationClient(transport).perform(.status, token: mutationBearer)
        }
    }
    for status in [201, 202, 204, 302, 307, 500] {
        let transport = MutationHTTPStub(try mutationResponse(mutationBody(.none), status: status))
        await #expect(throws: GatewayAvatarMutationFailure.invalidResponse) {
            try await mutationClient(transport).perform(.status, token: mutationBearer)
        }
    }
}

@Test func avatarMutationBoundsInjectedBodiesAndRedactsEveryPublicValue() async throws {
    for (status, bytes) in [(200, 2049), (503, 32769)] {
        let transport = MutationHTTPStub(
            .init(status: status, headers: mutationHeaders, body: Data(repeating: 32, count: bytes)))
        await #expect(throws: GatewayAvatarMutationFailure.invalidResponse) {
            try await mutationClient(transport).perform(.status, token: mutationBearer)
        }
    }
    let upload = try mutationUpload()
    let intent = try GatewayAvatarUploadIntent(
        requestID: mutationRequestID, versionID: mutationVersionID, expectedGeneration: 0)
    let snapshot = try GatewayAvatarOwnerSnapshot(
        data: JSONSerialization.data(withJSONObject: mutationBody()))
    #expect(
        !String(describing: upload).contains(mutationRequestID) && Mirror(reflecting: upload).children.isEmpty
    )
    #expect(
        !String(describing: intent).contains(mutationVersionID) && Mirror(reflecting: intent).children.isEmpty
    )
    #expect(
        !String(describing: snapshot).contains(mutationRequestID)
            && Mirror(reflecting: snapshot).children.isEmpty)
}
