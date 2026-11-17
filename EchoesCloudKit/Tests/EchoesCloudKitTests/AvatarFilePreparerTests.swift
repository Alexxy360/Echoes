import Darwin
import Foundation
import ImageIO
import Testing

@testable import EchoesCloudKit

private struct AvatarFileFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "echoes-photo-file-" + UUID().uuidString)
    let file: URL
    let bytes: Data
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        file = root.appendingPathComponent("selected.jpg")
        bytes = try MutationWireFixture().image
        try bytes.write(to: file)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
@Test func avatarFileImportPreparesBoundedCopiesWithoutChangingTheProviderFile() throws {
    let f = try AvatarFileFixture()
    defer { f.cleanup() }
    let prepared = try AvatarFilePreparer.prepare(f.file)
    #expect(prepared.image.count <= 256000 && prepared.thumbnail.count <= 32000)
    #expect(try Data(contentsOf: f.file) == f.bytes)
    let source = try #require(CGImageSourceCreateWithData(prepared.image as CFData, nil))
    let fields = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(fields[kCGImagePropertyGPSDictionary] == nil && fields[kCGImagePropertyTIFFDictionary] == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path) == ["selected.jpg"])
}
@Test func avatarFileImportRejectsSparseOversizedInputBeforeDecoding() throws {
    let f = try AvatarFileFixture()
    defer { f.cleanup() }
    let file = open(f.file.path, O_WRONLY)
    #expect(file >= 0)
    defer { close(file) }
    #expect(ftruncate(file, off_t(AvatarPreparer.maximumInputBytes + 1)) == 0)
    #expect(throws: AvatarPreparationFailure.inputTooLarge) { try AvatarFilePreparer.prepare(f.file) }
}
@Test func avatarFileImportDoesNotFollowSymlinksOrBlockOnFIFOOrReadDirectories() throws {
    let f = try AvatarFileFixture()
    defer { f.cleanup() }
    let link = f.root.appendingPathComponent("alias.jpg")
    let pipe = f.root.appendingPathComponent("pipe.jpg")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.file)
    #expect(mkfifo(pipe.path, 0o600) == 0)
    for value in [link, pipe, f.root, URL(string: "https://photo.example.invalid/private.jpg")!] {
        #expect(throws: AvatarPreparationFailure.unsupportedImage) { try AvatarFilePreparer.prepare(value) }
    }
    #expect(try Data(contentsOf: f.file) == f.bytes)
}
@Test func avatarFileImportCancellationPrecedesOpeningAndNeverCopiesOriginal() async throws {
    let f = try AvatarFileFixture()
    defer { f.cleanup() }
    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try AvatarFilePreparer.prepare(f.root.appendingPathComponent("missing.jpg"))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path) == ["selected.jpg"])
}
@Test func avatarFileImportRejectsEmptyAndMalformedImagesWithoutExposingFilePaths() throws {
    let f = try AvatarFileFixture()
    defer { f.cleanup() }
    for bytes in [Data(), Data("PRIVATE-FILE-PATH-AND-INVALID-CONTENT".utf8)] {
        try bytes.write(to: f.file)
        #expect(throws: AvatarPreparationFailure.unsupportedImage) { try AvatarFilePreparer.prepare(f.file) }
    }
}
@Test func avatarFileImportAcceptsAnImageAtTheExactOriginalByteLimit() throws {
    let f = try AvatarFileFixture()
    defer { f.cleanup() }
    var bytes = f.bytes
    bytes.append(Data(repeating: 0, count: AvatarPreparer.maximumInputBytes - bytes.count))
    try bytes.write(to: f.file)
    let image = try AvatarFilePreparer.prepare(f.file)
    #expect(image.image.count <= AvatarPreparer.maximumImageBytes)
    #expect(try Data(contentsOf: f.file).count == AvatarPreparer.maximumInputBytes)
}
