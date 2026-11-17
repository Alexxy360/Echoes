import Darwin
import Foundation

/// Actor-owned filesystem primitive. One lifetime flock prevents competing stores/processes from
/// racing leases or erasure. The zero-byte global lock contains no account identity or content.
final class AvatarUploadJournalFiles {
    enum WritePoint: Sendable, Equatable { case beforeRename, afterRename }
    static let namespace = "EchoesAvatarUploads"
    private let root: URL
    private var directory: Int32 = -1
    private var lockFile: Int32 = -1
    private var rootDirectory: Int32 = -1
    private var lockHeld = false
    private let fault: (@Sendable (WritePoint) throws -> Void)?
    var isOpen: Bool { directory >= 0 && lockFile >= 0 }
    init(root: URL, fault: (@Sendable (WritePoint) throws -> Void)? = nil) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), root.standardizedFileURL.path != "/",
            !root.path.utf8.contains(0), root.query == nil, root.fragment == nil
        else { throw GatewayAvatarUploadJournalFailure.unavailable }
        self.root = root.standardizedFileURL
        self.fault = fault
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            rootDirectory = Darwin.open(self.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let parent = rootDirectory
            guard parent >= 0 else { throw GatewayAvatarUploadJournalFailure.unavailable }
            directory = try openDirectory(Self.namespace, parent: parent, create: true)
            lockFile = openat(
                directory, ".store.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
                mode_t(0o600))
            guard lockFile >= 0 else { throw GatewayAvatarUploadJournalFailure.unavailable }
            try regular(lockFile, maximum: 0)
            guard flock(lockFile, LOCK_EX | LOCK_NB) == 0 else {
                throw GatewayAvatarUploadJournalFailure.busy
            }
            lockHeld = true
            try protect(
                lockFile, name: ".store.lock", parent: directory,
                url: namespaceURL.appendingPathComponent(".store.lock"))
            var url = namespaceURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            guard fsync(directory) == 0, fsync(parent) == 0 else {
                throw GatewayAvatarUploadJournalFailure.unavailable
            }
        } catch {
            shutdown()
            if let error = error as? GatewayAvatarUploadJournalFailure { throw error }
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
    }
    deinit { shutdown() }
    func shutdown() {
        if lockFile >= 0 {
            if lockHeld { _ = flock(lockFile, LOCK_UN) }
            Darwin.close(lockFile)
            lockFile = -1
            lockHeld = false
        }
        if directory >= 0 {
            Darwin.close(directory)
            directory = -1
        }
        if rootDirectory >= 0 {
            Darwin.close(rootDirectory)
            rootDirectory = -1
        }
    }
    private var namespaceURL: URL { root.appendingPathComponent(Self.namespace) }
    private func check() throws {
        guard isOpen else { throw GatewayAvatarUploadJournalFailure.inactive }
        var opened = stat()
        var named = stat()
        var folder = stat()
        var namedFolder = stat()
        guard fstat(lockFile, &opened) == 0,
            fstatat(directory, ".store.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
            opened.st_ino == named.st_ino, opened.st_dev == named.st_dev, named.st_nlink == 1,
            named.st_size == 0, named.st_mode & S_IFMT == S_IFREG,
            fstat(directory, &folder) == 0,
            fstatat(rootDirectory, Self.namespace, &namedFolder, AT_SYMLINK_NOFOLLOW) == 0,
            folder.st_ino == namedFolder.st_ino, folder.st_dev == namedFolder.st_dev,
            namedFolder.st_mode & S_IFMT == S_IFDIR
        else {
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
    }
    private func openDirectory(_ name: String, parent: Int32, create: Bool) throws -> Int32 {
        if create, mkdirat(parent, name, mode_t(0o700)) != 0, errno != EEXIST {
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if !create, fd < 0, errno == ENOENT { return -1 }
        guard fd >= 0 else { throw GatewayAvatarUploadJournalFailure.unavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), fchmod(fd, mode_t(0o700)) == 0 else {
            Darwin.close(fd)
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
        return fd
    }
    private func names(_ parent: Int32, maximum: Int) throws -> [String] {
        let copy = dup(parent)
        guard copy >= 0 else { throw GatewayAvatarUploadJournalFailure.unavailable }
        guard let iterator = fdopendir(copy) else {
            Darwin.close(copy)
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
        defer { closedir(iterator) }
        rewinddir(iterator)
        var result: [String] = []
        while true {
            errno = 0
            guard let row = readdir(iterator) else {
                guard errno == 0 else { throw GatewayAvatarUploadJournalFailure.unavailable }
                return result
            }
            let name = withUnsafePointer(to: &row.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(row.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard result.count < maximum else { throw GatewayAvatarUploadJournalFailure.capacity }
            result.append(name)
        }
    }
    private func owners() throws -> [String] {
        try check()
        let values = try names(directory, maximum: 9)
        guard values.contains(".store.lock"),
            values.allSatisfy({ $0 == ".store.lock" || GatewayAvatarQuery.validDigest($0) })
        else {
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
        return values.filter { $0 != ".store.lock" }
    }
    private func leaf(_ scope: GatewayAvatarUploadScope, create: Bool) throws -> Int32 {
        let existing = try owners()
        let ownerName = scope.privateScope.digest
        if create, !existing.contains(ownerName), existing.count >= 8 {
            throw GatewayAvatarUploadJournalFailure.capacity
        }
        let owner = try openDirectory(ownerName, parent: directory, create: create)
        if owner < 0 { return -1 }
        defer { Darwin.close(owner) }
        let scopes = try names(owner, maximum: 2)
        guard scopes.allSatisfy(GatewayAvatarQuery.validDigest) else {
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
        if create, !scopes.contains(scope.digest), scopes.count >= 2 {
            throw GatewayAvatarUploadJournalFailure.capacity
        }
        let result = try openDirectory(scope.digest, parent: owner, create: create)
        if create, result >= 0, fsync(owner) != 0 || fsync(directory) != 0 {
            Darwin.close(result)
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
        return result
    }
    private static func owned(_ name: String) -> Bool {
        name == "record.bin" || name.hasPrefix(".tmp-") && gatewayUUID(String(name.dropFirst(5)))
    }
    private func clean(_ fd: Int32) throws {
        let values = try names(fd, maximum: 4)
        guard values.allSatisfy(Self.owned) else { throw GatewayAvatarUploadJournalFailure.unavailable }
        for name in values where name.hasPrefix(".tmp-") { try unlink(name, parent: fd) }
        if values.contains(where: { $0.hasPrefix(".tmp-") }), fsync(fd) != 0 {
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
    }
    private func regular(_ fd: Int32, maximum: Int = AvatarUploadRecordCodec.maximumFileBytes) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
            info.st_uid == geteuid(),
            info.st_size >= 0, info.st_size <= maximum, fchmod(fd, mode_t(0o600)) == 0
        else { throw GatewayAvatarUploadJournalFailure.unavailable }
    }
    private func protect(_ file: Int32, name: String, parent: Int32, url: URL) throws {
        #if os(iOS)
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
                #if !targetEnvironment(simulator)
                    let values = try FileManager.default.attributesOfItem(atPath: url.path)
                    let protection =
                        (values[.protectionKey] as? FileProtectionType)?.rawValue ?? values[.protectionKey]
                        as? String
                    guard protection == FileProtectionType.complete.rawValue else {
                        throw GatewayAvatarUploadJournalFailure.unavailable
                    }
                #endif
            } catch { throw GatewayAvatarUploadJournalFailure.unavailable }
        #endif
        var opened = stat()
        var named = stat()
        guard fstat(file, &opened) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            opened.st_ino == named.st_ino, opened.st_dev == named.st_dev, named.st_nlink == 1,
            named.st_mode & S_IFMT == S_IFREG
        else {
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
    }
    func read(_ scope: GatewayAvatarUploadScope) throws -> Data? {
        let folder = try leaf(scope, create: false)
        if folder < 0 { return nil }
        defer { Darwin.close(folder) }
        try clean(folder)
        let file = openat(folder, "record.bin", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw GatewayAvatarUploadJournalFailure.unavailable }
        defer { Darwin.close(file) }
        try regular(file)
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress!, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw GatewayAvatarUploadJournalFailure.unavailable }
            if n == 0 { return bytes }
            guard bytes.count + n <= AvatarUploadRecordCodec.maximumFileBytes else {
                throw GatewayAvatarUploadJournalFailure.unavailable
            }
            bytes.append(contentsOf: buffer.prefix(n))
        }
    }
    func write(_ bytes: Data, scope: GatewayAvatarUploadScope) throws {
        try Task.checkCancellation()
        guard !bytes.isEmpty, bytes.count <= AvatarUploadRecordCodec.maximumFileBytes else {
            throw GatewayAvatarUploadJournalFailure.invalidData
        }
        let folder = try leaf(scope, create: true)
        defer { Darwin.close(folder) }
        try clean(folder)
        // Check an existing destination without following a symlink or modifying a hard-linked file.
        let old = openat(folder, "record.bin", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if old >= 0 {
            defer { Darwin.close(old) }
            try regular(old)
        } else if errno != ENOENT {
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
        let name = ".tmp-" + UUID().uuidString.lowercased()
        let file = openat(
            folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw GatewayAvatarUploadJournalFailure.unavailable }
        defer {
            Darwin.close(file)
            _ = unlinkat(folder, name, 0)
        }
        try regular(file)
        let url = namespaceURL.appendingPathComponent(scope.privateScope.digest).appendingPathComponent(
            scope.digest
        ).appendingPathComponent(name)
        try protect(file, name: name, parent: folder, url: url)
        try bytes.withUnsafeBytes { data in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(file, data.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw GatewayAvatarUploadJournalFailure.unavailable }
                offset += n
            }
        }
        try Task.checkCancellation()
        guard fsync(file) == 0 else { throw GatewayAvatarUploadJournalFailure.unavailable }
        try fault?(.beforeRename)
        guard renameat(folder, name, folder, "record.bin") == 0 else {
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
        try fault?(.afterRename)
        guard fsync(folder) == 0 else {
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
    }
    private func unlink(_ name: String, parent: Int32) throws {
        guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else {
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
    }
    func erase(_ scope: PrivateAccountScope) throws {
        _ = try owners()
        let owner = try openDirectory(scope.digest, parent: directory, create: false)
        if owner < 0 { return }
        defer { Darwin.close(owner) }
        for child in try names(owner, maximum: 2) {
            guard GatewayAvatarQuery.validDigest(child) else {
                throw GatewayAvatarUploadJournalFailure.unavailable
            }
            let folder = try openDirectory(child, parent: owner, create: false)
            guard folder >= 0 else { throw GatewayAvatarUploadJournalFailure.unavailable }
            do {
                let values = try names(folder, maximum: 4)
                guard values.allSatisfy(Self.owned) else {
                    throw GatewayAvatarUploadJournalFailure.unavailable
                }
                for name in values { try unlink(name, parent: folder) }
                guard fsync(folder) == 0 else { throw GatewayAvatarUploadJournalFailure.unavailable }
            } catch {
                Darwin.close(folder)
                throw error
            }
            Darwin.close(folder)
            guard unlinkat(owner, child, AT_REMOVEDIR) == 0, fsync(owner) == 0 else {
                throw GatewayAvatarUploadJournalFailure.unavailable
            }
        }
        guard unlinkat(directory, scope.digest, AT_REMOVEDIR) == 0, fsync(directory) == 0 else {
            throw GatewayAvatarUploadJournalFailure.unavailable
        }
    }
}
