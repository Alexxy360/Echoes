import EchoesCore

/// A typed selection hint only. GatewayAvatarClient still requires the current foreground selection
/// predicate, matching viewer scope and a fresh authorized HTTP read for every display attempt.
extension NearbyProfile {
    public var avatarReference: AvatarReference? {
        guard let avatarVersionID else { return nil }
        return try? AvatarReference(ownerID: id, versionID: avatarVersionID)
    }
}
extension ChatMessage {
    public var avatarReference: AvatarReference? {
        guard let avatarVersionID else { return nil }
        return try? AvatarReference(ownerID: senderID, versionID: avatarVersionID)
    }
}
extension GatewayPublicProfile {
    /// ownerID must come from the currently bound native account, not an editable profile field.
    public func avatarReference(ownerID: String) -> AvatarReference? {
        guard let avatarVersionID else { return nil }
        return try? AvatarReference(ownerID: ownerID, versionID: avatarVersionID)
    }
}
