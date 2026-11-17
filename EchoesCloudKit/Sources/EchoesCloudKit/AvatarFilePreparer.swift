import Darwin
import Foundation

/// Read only the selected provider file while its import callback owns access. Never persist the URL
/// or original bytes. Run outside the UI actor; the caller owns the provider's temporary-file lifetime.
public enum AvatarFilePreparer {
    public static func prepare(_ url: URL) throws -> PreparedAvatar {
        try Task.checkCancellation()
        guard url.isFileURL, !url.path.utf8.contains(0), url.query == nil, url.fragment == nil else {
            throw AvatarPreparationFailure.unsupportedImage
        }
        let file = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw AvatarPreparationFailure.unsupportedImage }
        defer { Darwin.close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_size >= 1
        else { throw AvatarPreparationFailure.unsupportedImage }
        guard before.st_size <= AvatarPreparer.maximumInputBytes else {
            throw AvatarPreparationFailure.inputTooLarge
        }
        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: 32768)
        while true {
            try Task.checkCancellation()
            let count = chunk.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw AvatarPreparationFailure.unsupportedImage }
            if count == 0 { break }
            guard bytes.count <= AvatarPreparer.maximumInputBytes - count else {
                throw AvatarPreparationFailure.inputTooLarge
            }
            bytes.append(contentsOf: chunk.prefix(count))
        }
        var after = stat()
        guard fstat(file, &after) == 0, before.st_size == after.st_size, Int64(bytes.count) == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw AvatarPreparationFailure.unsupportedImage }
        try Task.checkCancellation()
        let prepared = try AvatarPreparer.prepare(bytes)
        try Task.checkCancellation()
        return prepared
    }
}
