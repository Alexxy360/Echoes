import CryptoKit
import Foundation

/// Exact approved selection. ownerID is a local response assertion and is NEVER sent to the server.
/// Reusing publication metadata does not express consent or authorize publishing.
public struct GatewayAvatarOwnerPreviewQuery: Equatable, Sendable, CustomStringConvertible,
    CustomReflectable
{
    public let ownerID: String
    public let selection: GatewayAvatarPublishIntent
    public init(ownerID: String, selection: GatewayAvatarPublishIntent) throws {
        guard gatewayUUID(ownerID) else { throw GatewayAvatarFailure.invalidInput }
        self.ownerID = ownerID
        self.selection = selection
    }
    func wire() throws -> Data {
        var fields = selection.fields
        fields.removeValue(forKey: "consentVersion")
        let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard body.count <= 512 else { throw GatewayAvatarFailure.invalidInput }
        return body
    }
    public var description: String { "GatewayAvatarOwnerPreviewQuery(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Verified pixels for one bearer/origin/selection and a nonrenewable local 30-second window
/// starting BEFORE network IO. Not a server grant, UI-display acknowledgement or publication consent.
/// The future owner host must still fence native/private/lifecycle scope before exposing the image.
public struct GatewayAvatarOwnerPreview: Sendable, CustomStringConvertible, CustomReflectable {
    public let query: GatewayAvatarOwnerPreviewQuery
    public let avatar: ValidatedAvatar
    let origin: String, sessionFingerprint: String
    let observed: AvatarOwnerPreviewStamp
    func validate(
        query: GatewayAvatarOwnerPreviewQuery, origin: String, token: GatewaySecret,
        stamp: AvatarOwnerPreviewStamp
    ) throws {
        guard self.query == query, self.origin == origin,
            sessionFingerprint == Self.fingerprint(token)
        else { throw GatewayAvatarFailure.superseded }
        try observed.validate(stamp)
    }
    static func fingerprint(_ token: GatewaySecret) -> String {
        SHA256.hash(data: Data(token.value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var description: String { "GatewayAvatarOwnerPreview(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

struct AvatarOwnerPreviewStamp: Sendable {
    let milliseconds: Int, uptime: TimeInterval
    init(date: Date, uptime: TimeInterval) throws {
        let raw = date.timeIntervalSince1970 * 1000
        guard raw.isFinite, raw >= 0, raw < 9_007_199_254_710_991,
            uptime.isFinite, uptime >= 0
        else { throw GatewayAvatarFailure.superseded }
        milliseconds = Int(raw.rounded(.down))
        self.uptime = uptime
    }
    func validate(_ current: Self) throws {
        guard current.milliseconds >= milliseconds, current.milliseconds - milliseconds < 30_000,
            current.uptime >= uptime, current.uptime - uptime < 30
        else { throw GatewayAvatarFailure.superseded }
    }
}

func avatarOwnerPreviewObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
    guard !data.isEmpty, data.count <= 2048, String(data: data, encoding: .utf8) != nil,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        Set(object.keys) == keys
    else { throw GatewayAvatarFailure.invalidResponse }
    return object
}
