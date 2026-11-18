#if DEBUG
    import CryptoKit
    import EchoesCloudKit
    import Foundation
    import UIKit

    enum CommunityAvatarPreviewData {
        nonisolated static let ownerA = "11111111-1111-4111-8111-111111111111"
        nonisolated static let ownerB = "22222222-2222-4222-8222-222222222222"
        nonisolated static let version = "68000000-0000-4000-8000-000000000001"
    }

    /// Explicitly synthetic local UI provider. It never constructs a URLSession or Apple database.
    actor CommunityAvatarPreviewAPI: GatewayAvatarReadAPI {
        nonisolated let origin = "https://community-preview.example.invalid"
        private struct Picture: Sendable {
            let bytes: Data
            let side: Int
        }
        private let pictures: [String: Picture]
        private var delayed: Bool
        private var denied: Bool
        private var corrupt: Bool
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var damaged: Set<String> = []
        private init(pictures: [String: Picture], mode: String) {
            self.pictures = pictures
            delayed = mode == "avatars-delayed"
            denied = mode == "avatars-denied"
            corrupt = mode == "avatars-corrupt"
        }
        @MainActor static func make(mode: String) -> CommunityAvatarPreviewAPI {
            var pictures: [String: Picture] = [:]
            for owner in [CommunityAvatarPreviewData.ownerA, CommunityAvatarPreviewData.ownerB] {
                for side in [128, 512] {
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    format.opaque = true
                    let renderer = UIGraphicsImageRenderer(
                        size: .init(width: CGFloat(side), height: CGFloat(side)), format: format)
                    let bytes = renderer.jpegData(withCompressionQuality: 0.8) { context in
                        (owner == CommunityAvatarPreviewData.ownerA
                            ? UIColor.systemTeal : UIColor.systemOrange).setFill()
                        context.fill(.init(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
                        let symbol = UIImage(
                            systemName: "person.fill",
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: CGFloat(side) * 0.55))?
                            .withTintColor(.white, renderingMode: .alwaysOriginal)
                        symbol?.draw(
                            in: .init(
                                x: CGFloat(side) * 0.2, y: CGFloat(side) * 0.2, width: CGFloat(side) * 0.6,
                                height: CGFloat(side) * 0.6))
                    }
                    pictures[owner + "/" + String(side)] = .init(bytes: bytes, side: side)
                }
            }
            return .init(pictures: pictures, mode: mode)
        }
        func repair() {
            corrupt = false
            denied = false
        }
        func release() {
            delayed = false
            let values = waiting
            waiting.removeAll()
            for value in values { value.resume() }
        }
        func read(_ query: GatewayAvatarQuery, token: GatewaySecret) async throws -> GatewayAvatarReply {
            guard query.reference.versionID == CommunityAvatarPreviewData.version,
                let picture = pictures[
                    query.reference.ownerID + "/" + (query.variant == .image ? "512" : "128")],
                [CommunityAvatarPreviewData.ownerA, CommunityAvatarPreviewData.ownerB].contains(
                    query.reference.ownerID)
            else { throw GatewayAvatarFailure.notFound }
            let refuse = denied
            let damage =
                corrupt && damaged.insert(query.reference.ownerID + "/" + query.variant.rawValue).inserted
            // Intentionally ignores cancellation to exercise fences.
            if delayed { await withCheckedContinuation { waiting.append($0) } }
            if refuse { throw GatewayAvatarFailure.notFound }
            let digest = SHA256.hash(data: picture.bytes).map { String(format: "%02x", $0) }.joined()
            let fields: [String: Any] = [
                "schemaVersion": 1, "ownerID": query.reference.ownerID,
                "versionID": query.reference.versionID,
                "variant": query.variant.rawValue, "byteCount": picture.bytes.count, "width": picture.side,
                "height": picture.side, "sha256": digest,
            ]
            let manifest = try AvatarManifest(
                data: JSONSerialization.data(withJSONObject: fields), expected: query.reference,
                variant: query.variant)
            if query.knownSHA256 == digest { return .revalidated(manifest: manifest) }
            var bytes = picture.bytes
            if damage { bytes[bytes.count / 2] ^= 1 }
            return .downloaded(manifest: manifest, bytes: bytes)
        }
    }
#endif
