import Foundation

public enum GatewayAvatarMutationFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidInput, invalidResponse, unavailable, busy, stale, pending, rejected, denied
    case limited(retryAfterSeconds: Int?)
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Nie udało się przygotować żądania zdjęcia."
        case .invalidResponse, .unavailable:
            "Nie udało się potwierdzić wyniku. Sprawdź stan tej samej operacji."
        case .busy: "Poczekaj na zakończenie bieżącej operacji zdjęcia."
        case .stale: "Zdjęcie zmieniło się. Odśwież stan przed kolejną zmianą."
        case .pending: "Operacja nie została jeszcze potwierdzona. Sprawdź jej stan."
        case .rejected: "To zdjęcie nie zostało zatwierdzone do publikacji."
        case .denied: "Ta operacja zdjęcia nie jest teraz dostępna."
        case .limited: "Odczekaj chwilę przed kolejną operacją zdjęcia."
        }
    }
}

public struct GatewayAvatarUploadIntent: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let requestID: String
    public let versionID: String
    public let expectedGeneration: Int
    public let consentVersion: Int
    public init(
        requestID: String, versionID: String, expectedGeneration: Int, consentVersion: Int = 1
    ) throws {
        guard gatewayUUID(requestID), gatewayUUID(versionID),
            (0..<9_007_199_254_740_991).contains(expectedGeneration), consentVersion == 1
        else { throw GatewayAvatarMutationFailure.invalidInput }
        self.requestID = requestID
        self.versionID = versionID
        self.expectedGeneration = expectedGeneration
        self.consentVersion = consentVersion
    }
    var fields: [String: Any] {
        [
            "requestID": requestID, "versionID": versionID, "expectedGeneration": expectedGeneration,
            "consentVersion": consentVersion,
        ]
    }
    public var description: String { "GatewayAvatarUploadIntent(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Closed owner actions. The future owner host must persist the intent before any mutation dispatch.
/// image is the prepared, metadata-stripped JPEG; the server independently normalizes it again.
public enum GatewayAvatarMutation: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    case upload(intent: GatewayAvatarUploadIntent, image: Data)
    case recover(requestID: String)
    case publish(requestID: String)
    case clear(requestID: String, expectedGeneration: Int)
    case status
    var action: String {
        switch self {
        case .upload: "upload"
        case .recover: "recover"
        case .publish: "publish"
        case .clear: "clear"
        case .status: "status"
        }
    }
    var isUpload: Bool { if case .upload = self { true } else { false } }
    func wire() throws -> (body: Data, intentHeader: String?) {
        let fields: [String: Any]
        switch self {
        case .upload(let intent, let image):
            guard (4...256_000).contains(image.count), image.starts(with: [0xff, 0xd8]),
                image.suffix(2).elementsEqual([0xff, 0xd9])
            else { throw GatewayAvatarMutationFailure.invalidInput }
            let data = try JSONSerialization.data(withJSONObject: intent.fields, options: [.sortedKeys])
            guard data.count <= 512, data.allSatisfy({ (32...126).contains($0) }),
                let header = String(data: data, encoding: .utf8)
            else { throw GatewayAvatarMutationFailure.invalidInput }
            return (image, header)
        case .recover(let id), .publish(let id):
            guard gatewayUUID(id) else { throw GatewayAvatarMutationFailure.invalidInput }
            fields = ["requestID": id]
        case .clear(let id, let generation):
            guard gatewayUUID(id), (0..<9_007_199_254_740_991).contains(generation) else {
                throw GatewayAvatarMutationFailure.invalidInput
            }
            fields = ["requestID": id, "expectedGeneration": generation]
        case .status: fields = [:]
        }
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard data.count <= 512 else { throw GatewayAvatarMutationFailure.invalidInput }
        return (data, nil)
    }
    public var description: String { "GatewayAvatarMutation(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public enum GatewayAvatarOwnerStatus: String, Equatable, Sendable {
    case none, clearing, uploading
    case pendingReview = "pending-review"
    case approved, rejected, published
}

/// A current owner snapshot, never an authorization to display a peer photo or publish by itself.
public struct GatewayAvatarOwnerSnapshot: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let generation: Int
    public let requestID: String?
    public let versionID: String?
    public let publishedVersionID: String?
    public let status: GatewayAvatarOwnerStatus
    public let reviewRevision: String?
    private struct Wire: Decodable {
        let protocolVersion: Int, generation: Int
        let requestID: String?, versionID: String?, publishedVersionID: String?, reviewRevision: String?
        let status: String
    }
    public init(data: Data) throws {
        do {
            guard data.count <= 2048,
                let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(fields.keys)
                    == Set([
                        "protocolVersion", "generation", "requestID", "versionID", "publishedVersionID",
                        "status", "reviewRevision",
                    ])
            else { throw GatewayAvatarMutationFailure.invalidResponse }
            let value = try JSONDecoder().decode(Wire.self, from: data)
            guard value.protocolVersion == 1, (0...9_007_199_254_740_991).contains(value.generation),
                let status = GatewayAvatarOwnerStatus(rawValue: value.status),
                [value.requestID, value.versionID, value.publishedVersionID, value.reviewRevision]
                    .allSatisfy({ $0 == nil || gatewayUUID($0!) })
            else { throw GatewayAvatarMutationFailure.invalidResponse }
            if value.generation == 0 {
                guard status == .none, value.requestID == nil, value.versionID == nil,
                    value.publishedVersionID == nil, value.reviewRevision == nil
                else { throw GatewayAvatarMutationFailure.invalidResponse }
            } else {
                guard value.requestID != nil else { throw GatewayAvatarMutationFailure.invalidResponse }
            }
            if value.versionID == nil {
                guard status == .none || status == .clearing, value.reviewRevision == nil,
                    value.publishedVersionID == nil
                else { throw GatewayAvatarMutationFailure.invalidResponse }
            } else {
                guard status != .none, status != .clearing, value.reviewRevision != nil,
                    status == .published
                        ? value.publishedVersionID == value.versionID : value.publishedVersionID == nil
                else { throw GatewayAvatarMutationFailure.invalidResponse }
            }
            generation = value.generation
            requestID = value.requestID
            versionID = value.versionID
            publishedVersionID = value.publishedVersionID
            self.status = status
            reviewRevision = value.reviewRevision
        } catch { throw GatewayAvatarMutationFailure.invalidResponse }
    }
    func validate(for operation: GatewayAvatarMutation) throws {
        switch operation {
        case .status: break
        case .upload(let intent, _):
            guard requestID == intent.requestID, versionID == intent.versionID,
                generation == intent.expectedGeneration + 1, status != .uploading
            else { throw GatewayAvatarMutationFailure.invalidResponse }
        case .recover(let id):
            guard requestID == id, status != .uploading, status != .clearing else {
                throw GatewayAvatarMutationFailure.invalidResponse
            }
        case .publish(let id):
            guard requestID == id, status == .published else {
                throw GatewayAvatarMutationFailure.invalidResponse
            }
        case .clear(let id, let previous):
            guard requestID == id, generation == previous + 1, status == .none, versionID == nil else {
                throw GatewayAvatarMutationFailure.invalidResponse
            }
        }
    }
    public var description: String { "GatewayAvatarOwnerSnapshot(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public protocol GatewayAvatarMutationAPI: Sendable {
    var origin: String { get }
    func perform(_ operation: GatewayAvatarMutation, token: GatewaySecret) async throws
        -> GatewayAvatarOwnerSnapshot
}
public protocol GatewayAvatarMutationTransport: Sendable {
    func send(_ request: URLRequest, isUpload: Bool) async throws -> GatewayAvatarHTTPResponse
}

/// Inactive by default. A persistent owner journal and native/private fencing must wrap this API
/// before Runtime/UI activation; the API does not infer permissions from an old snapshot.
public struct GatewayAvatarMutationHTTPClient: GatewayAvatarMutationAPI {
    private let configuration: GatewayConfiguration
    private let transport: any GatewayAvatarMutationTransport
    private let isEnabled: @Sendable () -> Bool
    public var origin: String { configuration.origin.absoluteString }
    public init(
        configuration: GatewayConfiguration,
        transport: any GatewayAvatarMutationTransport = NativeGatewayAvatarMutationTransport(),
        isEnabled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.isEnabled = isEnabled
    }
    private func check() throws {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        guard isEnabled() else { throw GatewayAvatarMutationFailure.unavailable }
    }
    public func perform(_ operation: GatewayAvatarMutation, token: GatewaySecret) async throws
        -> GatewayAvatarOwnerSnapshot
    {
        try check()
        guard token.value.utf8.count == 80, gatewayUUID(String(token.value.prefix(36))),
            token.value.dropFirst(36).first == ".",
            token.value.suffix(43).utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                    || $0 == 95
            })
        else { throw GatewayAvatarMutationFailure.invalidInput }
        let wire = try operation.wire()
        var request = URLRequest(
            url: configuration.origin.appendingPathComponent("/v1/community/avatar/" + operation.action),
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = wire.body
        request.setValue(
            operation.isUpload ? "image/jpeg" : "application/json; charset=utf-8",
            forHTTPHeaderField: "Content-Type")
        request.setValue(String(wire.body.count), forHTTPHeaderField: "Content-Length")
        request.setValue(wire.intentHeader, forHTTPHeaderField: "X-Echoes-Avatar-Intent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer " + token.value, forHTTPHeaderField: "Authorization")
        let response: GatewayAvatarHTTPResponse
        do { response = try await transport.send(request, isUpload: operation.isUpload) } catch {
            try check()
            if error is CancellationError || error as? GatewayFailure == .cancelled {
                throw GatewayFailure.cancelled
            }
            if let failure = error as? GatewayAvatarMutationFailure { throw failure }
            throw GatewayAvatarMutationFailure.unavailable
        }
        try check()
        let boundary = try AvatarMutationResponseBoundary(status: response.status, headers: response.headers)
        try boundary.validate(response.body)
        guard response.status == 200 else { throw try mutationFailure(response, headers: boundary.headers) }
        let snapshot = try GatewayAvatarOwnerSnapshot(data: response.body)
        try snapshot.validate(for: operation)
        try check()
        return snapshot
    }
    private func mutationFailure(_ response: GatewayAvatarHTTPResponse, headers: [String: String]) throws
        -> any Error
    {
        struct Failure: Decodable { let protocolVersion: Int, error: String }
        guard let raw = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            Set(raw.keys) == Set(["protocolVersion", "error"]),
            let value = try? JSONDecoder().decode(Failure.self, from: response.body),
            value.protocolVersion == 1
        else { throw GatewayAvatarMutationFailure.invalidResponse }
        let retry = headers["retry-after"].flatMap { text -> Int? in
            guard (1...6).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }),
                let count = Int(text), count <= 86_400
            else { return nil }
            return count
        }
        let status: Int
        let error: any Error
        switch value.error {
        case "INVALID_SESSION", "REAUTH_REQUIRED": (status, error) = (401, GatewayFailure.signInRequired)
        case "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS":
            (status, error) = (403, GatewayFailure.signInRequired)
        case "AVATAR_INPUT", "INVALID_REQUEST", "HTTPS_REQUIRED", "PUBLIC_INPUT":
            (status, error) = (400, GatewayAvatarMutationFailure.invalidInput)
        case "BODY_TOO_LARGE": (status, error) = (413, GatewayAvatarMutationFailure.invalidInput)
        case "UNSUPPORTED_MEDIA_TYPE": (status, error) = (415, GatewayAvatarMutationFailure.invalidInput)
        case "AVATAR_STALE", "PUBLIC_CONFLICT", "PUBLIC_ERASED":
            (status, error) = (409, GatewayAvatarMutationFailure.stale)
        case "AVATAR_PENDING", "PUBLIC_PENDING": (status, error) = (409, GatewayAvatarMutationFailure.pending)
        case "AVATAR_REJECTED": (status, error) = (409, GatewayAvatarMutationFailure.rejected)
        case "AVATAR_SCOPE", "ORIGIN_NOT_ALLOWED":
            (status, error) = (403, GatewayAvatarMutationFailure.denied)
        case "AVATAR_RATE", "AVATAR_CAPACITY", "RATE_LIMITED", "PUBLIC_LIMIT":
            (status, error) = (429, GatewayAvatarMutationFailure.limited(retryAfterSeconds: retry))
        case "CAPACITY_LIMITED", "LIMIT_UNAVAILABLE", "UNAVAILABLE", "AVATAR_UNAVAILABLE", "AVATAR_RESPONSE",
            "FEATURE_DISABLED", "GATEWAY_DISABLED", "PUBLIC_THROTTLED", "PUBLIC_UNAVAILABLE":
            (status, error) = (503, GatewayAvatarMutationFailure.unavailable)
        case "NOT_FOUND": (status, error) = (404, GatewayAvatarMutationFailure.unavailable)
        case "METHOD_NOT_ALLOWED": (status, error) = (405, GatewayAvatarMutationFailure.unavailable)
        case "REQUEST_TIMEOUT": (status, error) = (408, GatewayAvatarMutationFailure.unavailable)
        default: throw GatewayAvatarMutationFailure.invalidResponse
        }
        guard status == response.status else { throw GatewayAvatarMutationFailure.invalidResponse }
        return error
    }
}
