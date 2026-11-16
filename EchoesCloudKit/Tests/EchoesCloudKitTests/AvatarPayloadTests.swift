import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EchoesCloudKit

private let avatarOwner = "61000000-0000-4000-8000-000000000001"
private let avatarVersion = "61000000-0000-4000-8000-000000000002"
private let avatarOther = "61000000-0000-4000-8000-000000000003"
private func jpeg(width: Int = 64, height: Int = 32, orientation: Int = 1, png: Bool = false) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(
            data, (png ? UTType.png.identifier : UTType.jpeg.identifier) as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
private func manifestData(_ data: Data, changes: [String: Any] = [:]) throws -> Data {
    var values: [String: Any] = [
        "schemaVersion": 1, "ownerID": avatarOwner, "versionID": avatarVersion, "variant": "image",
        "byteCount": data.count, "width": 64, "height": 32,
        "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
    ]
    values.merge(changes) { _, new in new }
    return try JSONSerialization.data(withJSONObject: values)
}
private func manifest(_ data: Data, changes: [String: Any] = [:], variant: AvatarVariant = .image) throws
    -> AvatarManifest
{
    try AvatarManifest(
        data: manifestData(data, changes: changes),
        expected: AvatarReference(ownerID: avatarOwner, versionID: avatarVersion), variant: variant)
}

@Test func avatarDownloadAcceptsPreparedFullAndThumbnailAsBoundedPixels() throws {
    let prepared = try AvatarPreparer.prepare(jpeg(width: 800, height: 400))
    for (variant, data, width, height) in [
        (AvatarVariant.image, prepared.image, 512, 256),
        (AvatarVariant.thumbnail, prepared.thumbnail, 128, 64),
    ] {
        let value = try manifest(
            data, changes: ["variant": variant.rawValue, "width": width, "height": height], variant: variant)
        let result = try AvatarPayloadValidator.decode(data, manifest: value)
        #expect(result.image.width == width && result.image.height == height)
        #expect(result.manifest.reference.versionID == avatarVersion)
    }
}
@Test func avatarManifestRejectsUnexpectedOwnersVersionsAndVariants() throws {
    let data = try jpeg()
    for changes: [String: Any] in [
        ["ownerID": avatarOther], ["versionID": avatarOther], ["variant": "thumbnail"],
        ["ownerID": "../outside"], ["versionID": "https://example.invalid/file.jpg"],
        ["variant": "large"], ["schemaVersion": 2],
    ] {
        #expect(throws: AvatarPayloadFailure.invalidManifest) { try manifest(data, changes: changes) }
    }
}
@Test func avatarManifestRejectsExtraFieldsOversizeAndNonIntegerValues() throws {
    let data = try jpeg()
    for changes: [String: Any] in [
        ["downloadURL": "https://example.invalid"], ["receipt": "not-a-client-field"],
        ["byteCount": true], ["width": false], ["height": 1.5], ["schemaVersion": true],
        ["byteCount": AvatarPreparer.maximumImageBytes + 1], ["width": 513], ["height": 0],
        ["byteCount": 0], ["sha256": String(repeating: "A", count: 64)], ["sha256": "abcd"],
    ] {
        #expect(throws: AvatarPayloadFailure.invalidManifest) { try manifest(data, changes: changes) }
    }
    let expected = try AvatarReference(ownerID: avatarOwner, versionID: avatarVersion)
    for bytes in [Data(), Data(repeating: 32, count: 2049), Data("[]".utf8)] {
        #expect(throws: AvatarPayloadFailure.invalidManifest) {
            try AvatarManifest(data: bytes, expected: expected, variant: .image)
        }
    }
}
@Test func avatarThumbnailCannotBorrowFullImageLimits() throws {
    let data = try jpeg()
    for changes: [String: Any] in [
        ["variant": "thumbnail", "width": 129],
        ["variant": "thumbnail", "byteCount": AvatarPreparer.maximumThumbnailBytes + 1],
    ] {
        #expect(throws: AvatarPayloadFailure.invalidManifest) {
            try manifest(data, changes: changes, variant: .thumbnail)
        }
    }
}
@Test func avatarDigestAndLengthAreCheckedBeforeDecoding() throws {
    let data = try jpeg()
    let value = try manifest(data)
    var changed = data
    changed[changed.count / 2] ^= 1
    for bytes in [changed, data + Data([0]), Data(data.dropLast())] {
        #expect(throws: AvatarPayloadFailure.mismatchedPayload) {
            try AvatarPayloadValidator.decode(bytes, manifest: value)
        }
    }
}
@Test func avatarDownloadedPixelsMustMatchBoundedManifestDimensionsAndOrientation() throws {
    let data = try jpeg(width: 1024, height: 512)
    #expect(throws: AvatarPayloadFailure.invalidImage) {
        try AvatarPayloadValidator.decode(data, manifest: manifest(data))
    }
    let oriented = try jpeg(orientation: 6)
    #expect(throws: AvatarPayloadFailure.invalidImage) {
        try AvatarPayloadValidator.decode(oriented, manifest: manifest(oriented))
    }
    let normal = try jpeg()
    #expect(throws: AvatarPayloadFailure.invalidImage) {
        try AvatarPayloadValidator.decode(normal, manifest: manifest(normal, changes: ["width": 63]))
    }
}
@Test func avatarDownloadRejectsTruncationDespiteARecomputedDigest() throws {
    let original = try jpeg()
    let invalid = Data(original.prefix(24)) + Data([0xff, 0xd9])
    #expect(throws: AvatarPayloadFailure.invalidImage) {
        try AvatarPayloadValidator.decode(invalid, manifest: manifest(invalid))
    }
}
@Test func avatarDownloadRejectsNonJPEGBytesDespiteARecomputedDigest() throws {
    let png = try jpeg(png: true)
    for (data, error) in [
        (png, AvatarPayloadFailure.mismatchedPayload),
        (Data([0xff, 0xd8, 0xff, 0xd9]), AvatarPayloadFailure.invalidImage),
        (Data("not-an-image".utf8), AvatarPayloadFailure.mismatchedPayload),
    ] {
        #expect(throws: error) {
            try AvatarPayloadValidator.decode(data, manifest: manifest(data))
        }
    }
}

@Test func cancelledAvatarDecodeCannotProducePixels() async throws {
    let data = try jpeg()
    let value = try manifest(data)
    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try AvatarPayloadValidator.decode(data, manifest: value)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}
