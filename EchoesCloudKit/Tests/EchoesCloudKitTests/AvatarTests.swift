import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EchoesCloudKit

private func sampleImage(width: Int, height: Int, properties: [CFString: Any] = [:]) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

private func properties(_ data: Data) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

@Test func avatarDropsLocationAndCameraMetadata() throws {
    let input = try sampleImage(
        width: 64, height: 64,
        properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.1, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 17.0, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Synthetic Camera"],
        ])
    #expect(try properties(input)[kCGImagePropertyGPSDictionary] != nil)
    let avatar = try AvatarPreparer.prepare(input)
    for output in [avatar.image, avatar.thumbnail] {
        let result = try properties(output)
        #expect(result[kCGImagePropertyGPSDictionary] == nil)
        let tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
    }
}

@Test func avatarBoundsImageDimensionsAndTransferSize() throws {
    let avatar = try AvatarPreparer.prepare(sampleImage(width: 1600, height: 1000))
    #expect(avatar.image.count <= AvatarPreparer.maximumImageBytes)
    #expect(avatar.thumbnail.count <= AvatarPreparer.maximumThumbnailBytes)
    let full = try properties(avatar.image)
    let thumb = try properties(avatar.thumbnail)
    #expect((full[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 512)
    #expect((thumb[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 128)
}

@Test func avatarNormalizesOrientationIntoPixels() throws {
    let input = try sampleImage(width: 80, height: 40, properties: [kCGImagePropertyOrientation: 6])
    let result = try properties(AvatarPreparer.prepare(input).image)
    let width = try #require(result[kCGImagePropertyPixelWidth] as? NSNumber)
    let height = try #require(result[kCGImagePropertyPixelHeight] as? NSNumber)
    #expect(width.intValue < height.intValue)
    #expect((result[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1)
}

@Test func avatarRejectsOversizeAndNonImageInput() throws {
    #expect(throws: AvatarPreparationFailure.inputTooLarge) {
        try AvatarPreparer.prepare(Data(count: AvatarPreparer.maximumInputBytes + 1))
    }
    #expect(throws: AvatarPreparationFailure.unsupportedImage) {
        try AvatarPreparer.prepare(Data("not an image".utf8))
    }
}
