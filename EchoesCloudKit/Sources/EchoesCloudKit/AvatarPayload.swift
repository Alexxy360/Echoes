import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum AvatarVariant: String, Sendable {
    case image, thumbnail
    public var maximumBytes: Int {
        self == .image ? AvatarPreparer.maximumImageBytes : AvatarPreparer.maximumThumbnailBytes
    }
    public var maximumPixels: Int { self == .image ? 512 : 128 }
}

/// Obtained from an authorized profile, never an asset URL or an Apple upload receipt.
public struct AvatarReference: Sendable, Equatable {
    public let ownerID: String
    public let versionID: String
    public init(ownerID: String, versionID: String) throws {
        guard gatewayUUID(ownerID), gatewayUUID(versionID) else {
            throw AvatarPayloadFailure.invalidManifest
        }
        self.ownerID = ownerID
        self.versionID = versionID
    }
}

public enum AvatarPayloadFailure: Error, Equatable, LocalizedError {
    case invalidManifest, mismatchedPayload, invalidImage
    public var errorDescription: String? {
        switch self {
        case .invalidManifest: "Nie udało się potwierdzić wersji zdjęcia."
        case .mismatchedPayload: "Pobrane zdjęcie nie pasuje do wybranej wersji."
        case .invalidImage: "Pobrane zdjęcie ma nieprawidłowy format."
        }
    }
}

/// Closed, bounded metadata for one immutable JPEG. A digest proves byte integrity, not access rights.
/// The future gateway must independently authorize both the manifest and every binary response.
public struct AvatarManifest: Sendable, Equatable {
    public let reference: AvatarReference
    public let variant: AvatarVariant
    public let byteCount: Int
    public let width: Int
    public let height: Int
    public let sha256: String
    private struct Payload: Decodable {
        let schemaVersion: Int
        let ownerID: String
        let versionID: String
        let variant: String
        let byteCount: Int
        let width: Int
        let height: Int
        let sha256: String
    }
    public init(data: Data, expected: AvatarReference, variant: AvatarVariant) throws {
        do {
            guard data.count <= 2048,
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(object.keys)
                    == Set([
                        "schemaVersion", "ownerID", "versionID", "variant", "byteCount", "width", "height",
                        "sha256",
                    ])
            else { throw AvatarPayloadFailure.invalidManifest }
            let value = try JSONDecoder().decode(Payload.self, from: data)
            guard value.schemaVersion == 1,
                try AvatarReference(ownerID: value.ownerID, versionID: value.versionID) == expected,
                value.variant == variant.rawValue,
                (1...variant.maximumBytes).contains(value.byteCount),
                (1...variant.maximumPixels).contains(value.width),
                (1...variant.maximumPixels).contains(value.height),
                value.sha256.utf8.count == 64,
                value.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw AvatarPayloadFailure.invalidManifest }
            reference = expected
            self.variant = variant
            byteCount = value.byteCount
            width = value.width
            height = value.height
            sha256 = value.sha256
        } catch { throw AvatarPayloadFailure.invalidManifest }
    }
}

/// Pixels only: source metadata and signed URLs are never handed to the renderer.
public struct ValidatedAvatar: Sendable {
    public let manifest: AvatarManifest
    public let image: CGImage
    fileprivate init(manifest: AvatarManifest, image: CGImage) {
        self.manifest = manifest
        self.image = image
    }
}

public enum AvatarPayloadValidator {
    /// Run off the UI actor. The caller must also bound streaming bytes BEFORE buffering a response,
    /// and fence the result against changes of viewer, block policy, owner and selected version.
    public static func decode(_ data: Data, manifest: AvatarManifest) throws -> ValidatedAvatar {
        try Task.checkCancellation()
        guard data.count == manifest.byteCount, data.count <= manifest.variant.maximumBytes,
            data.starts(with: [0xff, 0xd8]), data.suffix(2).elementsEqual([0xff, 0xd9]),
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == manifest.sha256
        else { throw AvatarPayloadFailure.mismatchedPayload }
        try Task.checkCancellation()
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == manifest.width,
            (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == manifest.height,
            (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue == 8,
            (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1,
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            image.width == manifest.width, image.height == manifest.height,
            image.bitsPerComponent == 8, image.bitsPerPixel <= 32
        else { throw AvatarPayloadFailure.invalidImage }
        try Task.checkCancellation()
        return .init(manifest: manifest, image: image)
    }
}
