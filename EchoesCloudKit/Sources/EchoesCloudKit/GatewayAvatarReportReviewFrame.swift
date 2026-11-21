import CryptoKit
import Foundation

let avatarReportReviewInspectionType = "application/vnd.echoes.avatar-report-inspection.v1"

/// Entire bounded frame validated before a reason or any pixels reach the caller.
/// Actual RGB decoding remains mandatory and runs through the existing off-main-actor decoder.
struct AvatarReportReviewFrame {
    let inspectionID: String, contentHash: String, reason: String
    let expiresAt: Int
    let target: GatewayAvatarReportReviewPhotoTarget?
    let manifest: AvatarManifest?
    let image: Data?
    init(_ data: Data, item: GatewayAvatarReportReviewItem, now: Int) throws {
        guard (6...268292).contains(data.count) else {
            throw GatewayAvatarReportReviewFailure.invalidResponse
        }
        let prefix = Array(data.prefix(4))
        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...12288).contains(length), length <= data.count - 4 else {
            throw GatewayAvatarReportReviewFailure.invalidResponse
        }
        let metadata = Data(data.dropFirst(4).prefix(length))
        let root = try avatarReportReviewObject(
            metadata,
            keys: [
                "protocolVersion", "schemaVersion", "inspectionID", "inspectionExpiresAt", "contentHash",
                "reportID", "createdAt", "expiresAt", "reason", "photo",
            ])
        struct Wire: Decodable {
            let protocolVersion: Int, schemaVersion: Int, inspectionExpiresAt: Int, createdAt: Int,
                expiresAt: Int
            let inspectionID: String, contentHash: String, reportID: String, reason: String
            let photo: Photo?
            struct Photo: Decodable {
                let ownerID: String, versionID: String
                let publicationGeneration: Int
            }
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: metadata),
            wire.protocolVersion == 1, wire.schemaVersion == 1,
            wire.reportID == item.reportID, wire.createdAt == item.createdAtMilliseconds,
            wire.expiresAt == item.expiresAtMilliseconds,
            reportReviewDates(
                created: wire.createdAt, expires: wire.expiresAt, lifetime: 2_592_000_000, now: now),
            gatewayUUID(wire.inspectionID), reportReviewHash(wire.contentHash),
            reportReviewText(wire.reason, maximum: 500),
            wire.inspectionExpiresAt > now, wire.inspectionExpiresAt <= now + 90_000,
            wire.inspectionExpiresAt <= wire.expiresAt
        else { throw GatewayAvatarReportReviewFailure.invalidResponse }
        inspectionID = wire.inspectionID
        contentHash = wire.contentHash
        reason = wire.reason
        expiresAt = wire.inspectionExpiresAt
        if let photo = wire.photo {
            guard let fields = root["photo"] as? [String: Any],
                Set(fields.keys) == ["ownerID", "versionID", "publicationGeneration", "manifest"],
                let rawManifest = fields["manifest"] as? [String: Any],
                let target = try? GatewayAvatarReportReviewPhotoTarget(
                    ownerID: photo.ownerID, versionID: photo.versionID,
                    publicationGeneration: photo.publicationGeneration),
                let expected = try? AvatarReference(ownerID: photo.ownerID, versionID: photo.versionID),
                let manifestData = try? JSONSerialization.data(withJSONObject: rawManifest),
                let manifest = try? AvatarManifest(data: manifestData, expected: expected, variant: .image)
            else { throw GatewayAvatarReportReviewFailure.invalidResponse }
            let image = Data(data.dropFirst(4 + length))
            guard image.count == manifest.byteCount,
                image.starts(with: [0xff, 0xd8]), image.suffix(2).elementsEqual([0xff, 0xd9]),
                SHA256.hash(data: image).map({ String(format: "%02x", $0) }).joined() == manifest.sha256
            else { throw GatewayAvatarReportReviewFailure.invalidResponse }
            self.target = target
            self.manifest = manifest
            self.image = image
        } else {
            guard root["photo"] is NSNull, data.count == 4 + length else {
                throw GatewayAvatarReportReviewFailure.invalidResponse
            }
            target = nil
            manifest = nil
            image = nil
        }
    }
}
