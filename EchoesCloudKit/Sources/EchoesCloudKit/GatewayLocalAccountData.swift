import Darwin
import Foundation

public enum GatewayLocalDataFailure: Error, LocalizedError, Equatable {
    case inactive, invalidData, unavailable
    public var errorDescription: String? {
        switch self {
        case .inactive: "Lokalny dostęp do tych danych został zamknięty."
        case .invalidData: "Lokalne dane mają nieprawidłowy rozmiar."
        case .unavailable: "Nie udało się bezpiecznie odczytać lub usunąć lokalnych plików."
        }
    }
}
public enum GatewayLocalDataKind: String, Sendable, CaseIterable {
    case profile = "profile.json"
    case avatar = "avatar.jpg"
    case thumbnail = "thumbnail.jpg"
    var limit: Int { self == .avatar ? 262_144 : 32_768 }
}
public struct GatewayLocalDataLease: Sendable, CustomStringConvertible, CustomReflectable {
    fileprivate let id: UUID
    fileprivate let scope: PrivateAccountScope
    fileprivate let binding: GatewayIdentityBinding
    public var description: String { "<local-data-lease>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Owns ONLY this application's scoped, reproducible CloudKit cache. Never Firebase or arbitrary
/// paths. The trusted root comes from the sandbox's cachesDirectory. No awaits occur during file IO.
public actor GatewayLocalAccountData {
    private let root: URL
    private var active: GatewayLocalDataLease?
    public init(root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), root.standardizedFileURL.path != "/" else {
            throw GatewayLocalDataFailure.unavailable
        }
        self.root = root.standardizedFileURL
    }
    /// Call only after verified native identity and gateway authorization; no UI-selectable scope.
    public func activate(scope: PrivateAccountScope, binding: GatewayIdentityBinding) throws
        -> GatewayLocalDataLease
    {
        guard scope.cloudKitAccountHash == binding.cloudKitAccountHash else {
            throw GatewayFailure.accountMismatch
        }
        let lease = GatewayLocalDataLease(id: UUID(), scope: scope, binding: binding)
        active = lease
        return lease
    }
    public func fence(binding: GatewayIdentityBinding, accountID: String?) {
        guard let active, active.binding == binding,
            accountID == nil || active.scope.accountID == accountID
        else { return }
        self.active = nil
    }
    public func write(_ data: Data, kind: GatewayLocalDataKind, lease: GatewayLocalDataLease) throws {
        try check(lease)
        guard !data.isEmpty, data.count <= kind.limit else { throw GatewayLocalDataFailure.invalidData }
        let base = try openBase(create: true)
        defer { close(base) }
        let directory = try openScope(lease.scope, at: base, create: true)
        defer { close(directory) }
        let file = openat(
            directory, kind.rawValue, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw GatewayLocalDataFailure.unavailable }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_nlink == 1, ftruncate(file, 0) == 0
        else { throw GatewayLocalDataFailure.unavailable }
        do {
            #if os(iOS)
                // Protect BEFORE writing content. The actor serializes all access and paths have fixed names.
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: root.appendingPathComponent("EchoesCloudKitData").appendingPathComponent(
                        lease.scope.digest
                    ).appendingPathComponent(kind.rawValue).path)
            #endif
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n < 0, errno == EINTR { continue }
                    guard n > 0 else { throw GatewayLocalDataFailure.unavailable }
                    offset += n
                }
            }
        } catch {
            _ = unlinkat(directory, kind.rawValue, 0)
            throw GatewayLocalDataFailure.unavailable
        }
    }
    public func read(kind: GatewayLocalDataKind, lease: GatewayLocalDataLease) throws -> Data? {
        try check(lease)
        let base = try openBase(create: false)
        if base < 0 { return nil }
        defer { close(base) }
        let directory = try openScope(lease.scope, at: base, create: false)
        if directory < 0 { return nil }
        defer { close(directory) }
        let file = openat(directory, kind.rawValue, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw GatewayLocalDataFailure.unavailable }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
            metadata.st_size >= 0, metadata.st_size <= kind.limit
        else { throw GatewayLocalDataFailure.unavailable }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw GatewayLocalDataFailure.unavailable }
            if count == 0 { return result }
            guard result.count + count <= kind.limit else { throw GatewayLocalDataFailure.unavailable }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
    /// Idempotent exact-scope cleanup. Late writes lose their lease. Symlinks are never followed;
    /// unexpected files keep the directory nonempty and fail cleanup instead of producing a false ACK.
    public func erase(scope: PrivateAccountScope) throws {
        if active?.scope == scope { active = nil }
        let base = try openBase(create: false)
        if base < 0 { return }
        defer { close(base) }
        let directory = try openScope(scope, at: base, create: false)
        if directory < 0 { return }
        for kind in GatewayLocalDataKind.allCases {
            if unlinkat(directory, kind.rawValue, 0) != 0, errno != ENOENT {
                close(directory)
                throw GatewayLocalDataFailure.unavailable
            }
        }
        close(directory)
        guard unlinkat(base, scope.digest, AT_REMOVEDIR) == 0 || errno == ENOENT else {
            throw GatewayLocalDataFailure.unavailable
        }
    }
    private func check(_ lease: GatewayLocalDataLease) throws {
        guard active?.id == lease.id, active?.scope == lease.scope, active?.binding == lease.binding else {
            throw GatewayLocalDataFailure.inactive
        }
    }
    private func openBase(create: Bool) throws -> Int32 {
        if create {
            do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) } catch
            { throw GatewayLocalDataFailure.unavailable }
        }
        let base = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if !create, base < 0, errno == ENOENT { return -1 }
        guard base >= 0 else { throw GatewayLocalDataFailure.unavailable }
        defer { close(base) }
        if create, mkdirat(base, "EchoesCloudKitData", mode_t(0o700)) != 0, errno != EEXIST {
            throw GatewayLocalDataFailure.unavailable
        }
        let folder = openat(base, "EchoesCloudKitData", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if !create, folder < 0, errno == ENOENT { return -1 }
        guard folder >= 0 else { throw GatewayLocalDataFailure.unavailable }
        return folder
    }
    private func openScope(_ scope: PrivateAccountScope, at base: Int32, create: Bool) throws -> Int32 {
        if create, mkdirat(base, scope.digest, mode_t(0o700)) != 0, errno != EEXIST {
            throw GatewayLocalDataFailure.unavailable
        }
        let directory = openat(base, scope.digest, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if !create, directory < 0, errno == ENOENT { return -1 }
        guard directory >= 0 else { throw GatewayLocalDataFailure.unavailable }
        return directory
    }
}
