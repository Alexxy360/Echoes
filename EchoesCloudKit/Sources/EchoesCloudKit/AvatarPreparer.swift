import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum AvatarPreparationFailure: Error, Equatable, LocalizedError {
    case inputTooLarge, unsupportedImage, excessiveDimensions, encodingFailed
    public var errorDescription: String? {
        switch self {
        case .inputTooLarge: "Wybierz zdjęcie mniejsze niż 8 MB."
        case .unsupportedImage: "Wybierz zdjęcie JPEG, PNG lub HEIC."
        case .excessiveDimensions: "Zdjęcie ma zbyt duże wymiary."
        case .encodingFailed: "Nie udało się przygotować zdjęcia."
        }
    }
}

public struct PreparedAvatar: Sendable {
    public let image: Data
    public let thumbnail: Data
}

/// Local preparation only: no uploads, asset URLs or access-policy decisions.
public enum AvatarPreparer {
    public static let maximumInputBytes = 8_000_000
    public static let maximumImageBytes = 256_000
    public static let maximumThumbnailBytes = 32_000

    /// Call outside the UI actor. Decodes a bounded thumbnail, normalizes orientation, and drops source metadata.
    public static func prepare(_ input: Data) throws -> PreparedAvatar {
        guard input.count <= maximumInputBytes else { throw AvatarPreparationFailure.inputTooLarge }
        guard
            let source = CGImageSourceCreateWithData(
                input as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) == 1, let type = CGImageSourceGetType(source) as String?,
            [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.heif.identifier]
                .contains(type),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { throw AvatarPreparationFailure.unsupportedImage }
        guard width.isFinite, height.isFinite, width > 0, height > 0,
            width <= 12_000, height <= 12_000, width * height <= 40_000_000
        else { throw AvatarPreparationFailure.excessiveDimensions }
        return try .init(
            image: encodedThumbnail(source, pixels: 512, maximumBytes: maximumImageBytes),
            thumbnail: encodedThumbnail(source, pixels: 128, maximumBytes: maximumThumbnailBytes))
    }

    private static func encodedThumbnail(_ source: CGImageSource, pixels: Int, maximumBytes: Int) throws
        -> Data
    {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCache: false,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: decoded.width, height: decoded.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw AvatarPreparationFailure.encodingFailed }
        let rect = CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(decoded, in: rect)
        guard let image = context.makeImage() else { throw AvatarPreparationFailure.encodingFailed }
        for quality in [0.85, 0.65, 0.45, 0.25] {
            let output = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    output, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw AvatarPreparationFailure.encodingFailed }
            // Re-encode pixels, never copy GPS/EXIF/camera metadata from the source.
            CGImageDestinationAddImage(
                destination, image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length <= maximumBytes {
                return output as Data
            }
        }
        throw AvatarPreparationFailure.encodingFailed
    }
}
