import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import EchoesCloudKit

@Test func serverNormalizedJPEGMatchesNativeManifestAndRealImageIOPixels() throws {
    let directory = "Fixtures/avatar-normalized"
    let jsonURL = try #require(
        Bundle.module.url(forResource: "manifests", withExtension: "json", subdirectory: directory))
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
    let manifests = try #require(object["manifests"] as? [String: Any])
    let reference = try AvatarReference(
        ownerID: "64000000-0000-4000-8000-000000000001",
        versionID: "64000000-0000-4000-8000-000000000002")
    for variant in [AvatarVariant.image, .thumbnail] {
        let raw = try #require(manifests[variant.rawValue])
        let manifest = try AvatarManifest(
            data: JSONSerialization.data(withJSONObject: raw), expected: reference, variant: variant)
        let url = try #require(
            Bundle.module.url(forResource: variant.rawValue, withExtension: "jpg", subdirectory: directory))
        let data = try Data(contentsOf: url)
        let decoded = try AvatarPayloadValidator.decode(data, manifest: manifest)
        #expect(decoded.image.width == (variant == .image ? 256 : 128))
        #expect(decoded.image.height == (variant == .image ? 128 : 64))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyExifDictionary] == nil)
        #expect(properties[kCGImagePropertyTIFFDictionary] == nil)
        let image = decoded.image
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = try #require(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        let center = ((image.height / 2) * image.width + image.width / 2) * 4
        #expect(abs(Int(pixels[center]) - 128) < 20)
        #expect(abs(Int(pixels[center + 1]) - 128) < 20)
        #expect(abs(Int(pixels[center + 2]) - 110) < 20)
        #expect(pixels[center + 3] == 255)
    }
}
