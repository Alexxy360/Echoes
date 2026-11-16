import Darwin
import Foundation

/// Derived from verified native identity and gateway configuration, never an HTTP payload.
public struct GatewayAvatarCacheScope: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    let privateScope: PrivateAccountScope
    let communityScope: GatewayCommunityScope
    let binding: GatewayIdentityBinding
    public init(
        configuration: GatewayConfiguration, privateScope: PrivateAccountScope,
        binding: GatewayIdentityBinding
    ) throws {
        self.privateScope = privateScope
        self.binding = binding
        communityScope = try .init(configuration: configuration, privateScope: privateScope, binding: binding)
    }
    public var description: String { "GatewayAvatarCacheScope(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public struct GatewayAvatarCacheLease: Sendable, CustomStringConvertible, CustomReflectable {
    fileprivate let id: UUID
    fileprivate let scope: GatewayAvatarCacheScope
    public var description: String { "GatewayAvatarCacheLease(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
/// A candidate, not an authorization to display. Every use still needs fresh gateway revalidation
/// and viewer/visibility/version fences. A successful local read cannot authorize offline rendering.
public struct GatewayAvatarCacheEntry: Equatable, Sendable, CustomStringConvertible, CustomReflectable {
    public let manifest: AvatarManifest
    public let bytes: Data
    public var description: String { "GatewayAvatarCacheEntry(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
public enum GatewayAvatarCacheFailure: Error, Equatable, Sendable, LocalizedError {
    case inactive, invalidData, unavailable, capacity
    public var errorDescription: String? {
        switch self {
        case .inactive: "Dostęp do zapisanych zdjęć został zamknięty."
        case .invalidData: "Zapisane zdjęcie ma nieprawidłowy format."
        case .unavailable, .capacity: "Nie udało się bezpiecznie zapisać lub usunąć lokalnego zdjęcia."
        }
    }
}

/// Reproducible, bounded cache under a trusted sandbox cachesDirectory. One actor owns this tree;
/// there are no awaits during IO. Reads/writes never follow file or scope symlinks or accept hardlinks.
/// The envelope holds no bearer, coordinates, provider URL or receipt. JPEG bytes must already
/// be normalized by the gateway; this cache verifies integrity and ImageIO, not metadata removal.
public actor GatewayAvatarCache {
    struct Limits: Sendable {
        var entries = 64
        var bytes = 8 * 1024 * 1024
        var lifetime: TimeInterval = 86_400
    }
    private static let namespace = "EchoesAvatarCache"
    private static let magic = Data("ECHOESAVATAR1\n".utf8)
    private static let maximumEnvelope = 256_000 + 4096
    private let root: URL
    private let clock: @Sendable () -> Date
    private let limits: Limits
    private var active: GatewayAvatarCacheLease?
    public init(root: URL, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.root = try Self.validateRoot(root)
        self.clock = clock
        limits = .init()
    }
    // Reduced limits for deterministic quota/expiry tests; production limits cannot be raised here.
    init(root: URL, clock: @escaping @Sendable () -> Date, limits: Limits) throws {
        guard (1...64).contains(limits.entries), (1...(8 * 1024 * 1024)).contains(limits.bytes),
            limits.lifetime > 0, limits.lifetime <= 86_400
        else { throw GatewayAvatarCacheFailure.invalidData }
        self.root = try Self.validateRoot(root)
        self.clock = clock
        self.limits = limits
    }
    /// The upcoming native client must acquire only after checking its current authorization snapshot.
    /// Replacing a lease fences all earlier reads/writes. The lease itself does not prove server access.
    public func activate(scope: GatewayAvatarCacheScope) -> GatewayAvatarCacheLease {
        let lease = GatewayAvatarCacheLease(id: UUID(), scope: scope)
        active = lease
        return lease
    }
    public func fence(_ lease: GatewayAvatarCacheLease) {
        if active?.id == lease.id { active = nil }
    }
    public func fence(binding: GatewayIdentityBinding, accountID: String?) {
        guard let active, active.scope.binding == binding,
            accountID == nil || active.scope.privateScope.accountID == accountID
        else { return }
        self.active = nil
    }
    public func read(
        reference: AvatarReference, variant: AvatarVariant, lease: GatewayAvatarCacheLease
    ) throws -> GatewayAvatarCacheEntry? {
        try check(lease)
        let directory = try openViewer(lease.scope, create: false)
        if directory < 0 { return nil }
        defer { close(directory) }
        try sweep(directory)
        let name = Self.filename(reference, variant)
        guard let data = try readFile(name, at: directory, maximum: variant.maximumBytes + 4096) else {
            return nil
        }
        do {
            let (entry, storedAt) = try decode(data, reference: reference, variant: variant)
            let now = try timestamp()
            guard storedAt <= now + 300, now - storedAt < limits.lifetime else {
                try remove(name, at: directory)
                return nil
            }
            _ = try AvatarPayloadValidator.decode(entry.bytes, manifest: entry.manifest)
            // Only eviction recency changes. The envelope's creation time never extends on a hit.
            var times = [
                timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(now), tv_nsec: 0),
            ]
            guard utimensat(directory, name, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw GatewayAvatarCacheFailure.unavailable
            }
            return entry
        } catch is CancellationError { throw CancellationError() } catch {
            // Corrupt local candidates are discarded and treated as misses, never rendered.
            try remove(name, at: directory)
            return nil
        }
    }
    public func store(
        _ bytes: Data, manifest: AvatarManifest, lease: GatewayAvatarCacheLease
    ) throws {
        try check(lease)
        do { _ = try AvatarPayloadValidator.decode(bytes, manifest: manifest) } catch is CancellationError {
            throw CancellationError()
        } catch { throw GatewayAvatarCacheFailure.invalidData }
        let now = try timestamp()
        let data = try encode(bytes, manifest: manifest, storedAt: now)
        guard data.count <= limits.bytes else { throw GatewayAvatarCacheFailure.capacity }
        let directory = try openViewer(lease.scope, create: true)
        defer { close(directory) }
        try sweep(directory)
        let name = Self.filename(manifest.reference, manifest.variant)
        var entries = try files(at: directory).filter { $0.name.hasSuffix(".bin") }
        if entries.contains(where: { $0.name == name }) {
            // Immutable version keys cannot silently acquire different bytes or metadata.
            guard
                let current = try readFile(
                    name, at: directory, maximum: manifest.variant.maximumBytes + 4096),
                let (value, _) = try? decode(
                    current, reference: manifest.reference, variant: manifest.variant),
                value.manifest == manifest, value.bytes == bytes
            else { throw GatewayAvatarCacheFailure.invalidData }
            // Repeated authorization does not renew the retention timer of existing bytes.
            return
        }
        entries.sort { $0.modified == $1.modified ? $0.name < $1.name : $0.modified < $1.modified }
        var total = entries.reduce(0) { $0 + $1.size }
        while entries.count >= limits.entries || total + data.count > limits.bytes {
            guard !entries.isEmpty else { throw GatewayAvatarCacheFailure.capacity }
            let oldest = entries.removeFirst()
            try remove(oldest.name, at: directory)
            total -= oldest.size
        }
        let temporary = ".tmp-" + UUID().uuidString.lowercased()
        let file = openat(
            directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
            mode_t(0o600))
        guard file >= 0 else { throw GatewayAvatarCacheFailure.unavailable }
        defer {
            close(file)
            _ = unlinkat(directory, temporary, 0)
        }
        try regular(file)
        #if os(iOS)
            // Set public Foundation protection BEFORE any content. Random O_EXCL temp names, no
            // awaits and an inode check keep ordinary linked files outside the write boundary.
            let url = viewerURL(lease.scope).appendingPathComponent(temporary)
            do {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
                #if !targetEnvironment(simulator)
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let protection =
                        (attributes[.protectionKey] as? FileProtectionType)?.rawValue
                        ?? (attributes[.protectionKey] as? String)
                    guard protection == FileProtectionType.complete.rawValue else {
                        throw GatewayAvatarCacheFailure.unavailable
                    }
                #endif
            } catch { throw GatewayAvatarCacheFailure.unavailable }
            var opened = stat()
            var named = stat()
            guard fstat(file, &opened) == 0,
                fstatat(directory, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
                opened.st_ino == named.st_ino, opened.st_dev == named.st_dev, named.st_nlink == 1,
                named.st_mode & S_IFMT == S_IFREG
            else { throw GatewayAvatarCacheFailure.unavailable }
        #endif
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw GatewayAvatarCacheFailure.unavailable }
                offset += n
            }
        }
        try Task.checkCancellation()
        guard fsync(file) == 0, renameat(directory, temporary, directory, name) == 0,
            fsync(directory) == 0
        else { throw GatewayAvatarCacheFailure.unavailable }
    }
    /// Exact private-account cleanup across all its gateway/native bindings. Fences matching access
    /// first. Unknown names/directories cause failure instead of a false local-deletion ACK.
    public func erase(scope: PrivateAccountScope) throws {
        if active?.scope.privateScope == scope { active = nil }
        let namespace = try openNamespace(create: false)
        if namespace < 0 { return }
        defer { close(namespace) }
        let owner = try openDirectory(scope.digest, at: namespace, create: false)
        if owner < 0 { return }
        defer { close(owner) }
        for viewer in try names(at: owner, maximum: 2) {
            guard GatewayAvatarQuery.validDigest(viewer) else { throw GatewayAvatarCacheFailure.unavailable }
            let directory = try openDirectory(viewer, at: owner, create: false)
            guard directory >= 0 else { throw GatewayAvatarCacheFailure.unavailable }
            do {
                for name in try names(at: directory, maximum: 128) {
                    guard Self.ownedFilename(name) else { throw GatewayAvatarCacheFailure.unavailable }
                    // unlinkat does not follow a known filename's symlink or delete its target.
                    try remove(name, at: directory)
                }
                guard fsync(directory) == 0 else { throw GatewayAvatarCacheFailure.unavailable }
            } catch {
                close(directory)
                throw error
            }
            close(directory)
            guard unlinkat(owner, viewer, AT_REMOVEDIR) == 0, fsync(owner) == 0 else {
                throw GatewayAvatarCacheFailure.unavailable
            }
        }
        guard unlinkat(namespace, scope.digest, AT_REMOVEDIR) == 0 || errno == ENOENT else {
            throw GatewayAvatarCacheFailure.unavailable
        }
        guard fsync(namespace) == 0 else { throw GatewayAvatarCacheFailure.unavailable }
    }
    private func check(_ lease: GatewayAvatarCacheLease) throws {
        try Task.checkCancellation()
        guard active?.id == lease.id, active?.scope == lease.scope else {
            throw GatewayAvatarCacheFailure.inactive
        }
    }
    private static func validateRoot(_ root: URL) throws -> URL {
        guard root.isFileURL, root.path.hasPrefix("/"), root.standardizedFileURL.path != "/",
            !root.path.utf8.contains(0), root.query == nil, root.fragment == nil
        else { throw GatewayAvatarCacheFailure.unavailable }
        return root.standardizedFileURL
    }
    private func timestamp() throws -> Double {
        let value = clock().timeIntervalSince1970
        guard value.isFinite, value >= 0, value < 9_007_199_254_740 else {
            throw GatewayAvatarCacheFailure.unavailable
        }
        return value
    }
    private static func filename(_ reference: AvatarReference, _ variant: AvatarVariant) -> String {
        communityDigest(
            "echoes/avatar-cache/v1\0" + reference.ownerID + "\0" + reference.versionID + "\0"
                + variant.rawValue) + ".bin"
    }
    private static func ownedFilename(_ name: String) -> Bool {
        name.hasSuffix(".bin") && GatewayAvatarQuery.validDigest(String(name.dropLast(4)))
            || name.hasPrefix(".tmp-") && gatewayUUID(String(name.dropFirst(5)))
    }
    private func encode(_ bytes: Data, manifest: AvatarManifest, storedAt: Double) throws -> Data {
        let raw: [String: Any] = [
            "schemaVersion": 1, "ownerID": manifest.reference.ownerID,
            "versionID": manifest.reference.versionID,
            "variant": manifest.variant.rawValue, "byteCount": manifest.byteCount, "width": manifest.width,
            "height": manifest.height, "sha256": manifest.sha256,
        ]
        let json = try JSONSerialization.data(
            withJSONObject: ["storedAt": storedAt, "manifest": raw], options: [.sortedKeys])
        guard json.count <= 3072 else { throw GatewayAvatarCacheFailure.invalidData }
        let count = UInt32(json.count)
        var data = Self.magic
        data.append(contentsOf: [
            UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255),
        ])
        data.append(json)
        data.append(bytes)
        return data
    }
    private func decode(_ data: Data, reference: AvatarReference, variant: AvatarVariant) throws
        -> (GatewayAvatarCacheEntry, Double)
    {
        let offset = Self.magic.count
        guard data.starts(with: Self.magic), data.count > offset + 4 else {
            throw GatewayAvatarCacheFailure.invalidData
        }
        let count = data[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }
        guard (1...3072).contains(count), data.count > offset + 4 + count,
            let object = try JSONSerialization.jsonObject(
                with: data.subdata(in: (offset + 4)..<(offset + 4 + count))) as? [String: Any],
            Set(object.keys) == Set(["storedAt", "manifest"]), let raw = object["manifest"],
            let storedAt = object["storedAt"] as? NSNumber,
            CFGetTypeID(storedAt) != CFBooleanGetTypeID(), storedAt.doubleValue.isFinite,
            storedAt.doubleValue >= 0
        else { throw GatewayAvatarCacheFailure.invalidData }
        let manifest = try AvatarManifest(
            data: JSONSerialization.data(withJSONObject: raw), expected: reference, variant: variant)
        let bytes = data.subdata(in: (offset + 4 + count)..<data.count)
        guard bytes.count == manifest.byteCount else { throw GatewayAvatarCacheFailure.invalidData }
        return (.init(manifest: manifest, bytes: bytes), storedAt.doubleValue)
    }
    private func viewerURL(_ scope: GatewayAvatarCacheScope) -> URL {
        root.appendingPathComponent(Self.namespace).appendingPathComponent(scope.privateScope.digest)
            .appendingPathComponent(scope.communityScope.digest)
    }
    private func openNamespace(create: Bool) throws -> Int32 {
        if create {
            do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) } catch
            {
                throw GatewayAvatarCacheFailure.unavailable
            }
        }
        let base = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if !create, base < 0, errno == ENOENT { return -1 }
        guard base >= 0 else { throw GatewayAvatarCacheFailure.unavailable }
        defer { close(base) }
        let directory = try openDirectory(Self.namespace, at: base, create: create)
        if create {
            do {
                var url = root.appendingPathComponent(Self.namespace)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            } catch {
                close(directory)
                throw GatewayAvatarCacheFailure.unavailable
            }
        }
        return directory
    }
    private func openViewer(_ scope: GatewayAvatarCacheScope, create: Bool) throws -> Int32 {
        let namespace = try openNamespace(create: create)
        if namespace < 0 { return -1 }
        defer { close(namespace) }
        try directoryCapacity(namespace, name: scope.privateScope.digest, maximum: 8, create: create)
        let owner = try openDirectory(scope.privateScope.digest, at: namespace, create: create)
        if owner < 0 { return -1 }
        defer { close(owner) }
        try directoryCapacity(owner, name: scope.communityScope.digest, maximum: 2, create: create)
        return try openDirectory(scope.communityScope.digest, at: owner, create: create)
    }
    private func directoryCapacity(_ directory: Int32, name: String, maximum: Int, create: Bool) throws {
        let existing = try names(at: directory, maximum: maximum)
        guard existing.allSatisfy({ GatewayAvatarQuery.validDigest($0) }) else {
            throw GatewayAvatarCacheFailure.unavailable
        }
        if create, !existing.contains(name), existing.count >= maximum {
            throw GatewayAvatarCacheFailure.capacity
        }
    }
    private func openDirectory(_ name: String, at parent: Int32, create: Bool) throws -> Int32 {
        if create, mkdirat(parent, name, mode_t(0o700)) != 0, errno != EEXIST {
            throw GatewayAvatarCacheFailure.unavailable
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if !create, fd < 0, errno == ENOENT { return -1 }
        guard fd >= 0 else { throw GatewayAvatarCacheFailure.unavailable }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == geteuid(), fchmod(fd, mode_t(0o700)) == 0 else {
            close(fd)
            throw GatewayAvatarCacheFailure.unavailable
        }
        return fd
    }
    private func names(at directory: Int32, maximum: Int) throws -> [String] {
        let copy = dup(directory)
        guard copy >= 0 else { throw GatewayAvatarCacheFailure.unavailable }
        guard let iterator = fdopendir(copy) else {
            close(copy)
            throw GatewayAvatarCacheFailure.unavailable
        }
        defer { closedir(iterator) }
        // dup shares the open-file offset; rewind before every independent scan.
        rewinddir(iterator)
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(iterator) else {
                guard errno == 0 else { throw GatewayAvatarCacheFailure.unavailable }
                return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard result.count < maximum else { throw GatewayAvatarCacheFailure.capacity }
            result.append(name)
        }
    }
    private struct FileEntry {
        let name: String
        let size: Int
        let modified: Double
    }
    private func files(at directory: Int32) throws -> [FileEntry] {
        try names(at: directory, maximum: 128).map { name in
            guard Self.ownedFilename(name) else { throw GatewayAvatarCacheFailure.unavailable }
            var metadata = stat()
            guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(), metadata.st_nlink == 1,
                metadata.st_size >= 0, metadata.st_size <= Self.maximumEnvelope
            else { throw GatewayAvatarCacheFailure.unavailable }
            return FileEntry(
                name: name, size: Int(metadata.st_size),
                modified: Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec)
                    / 1_000_000_000)
        }
    }
    private func sweep(_ directory: Int32) throws {
        let now = try timestamp()
        for entry in try files(at: directory) {
            if entry.name.hasPrefix(".tmp-") || entry.modified > now + 300
                || now - entry.modified >= limits.lifetime
            {
                try remove(entry.name, at: directory)
            }
        }
    }
    private func regular(_ file: Int32) throws {
        var metadata = stat()
        guard fstat(file, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_nlink == 1, metadata.st_uid == geteuid(), metadata.st_size >= 0,
            metadata.st_size <= Self.maximumEnvelope, fchmod(file, mode_t(0o600)) == 0
        else { throw GatewayAvatarCacheFailure.unavailable }
    }
    private func readFile(_ name: String, at directory: Int32, maximum: Int) throws -> Data? {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw GatewayAvatarCacheFailure.unavailable }
        defer { close(file) }
        try regular(file)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress!, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw GatewayAvatarCacheFailure.unavailable }
            if n == 0 { return result }
            guard result.count + n <= maximum else {
                throw GatewayAvatarCacheFailure.unavailable
            }
            result.append(contentsOf: buffer.prefix(n))
        }
    }
    private func remove(_ name: String, at directory: Int32) throws {
        guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else {
            throw GatewayAvatarCacheFailure.unavailable
        }
    }
}
