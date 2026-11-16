#if DEBUG
    import Darwin
    import Foundation

    public enum PrivateProfileProbeClaimFailure: Error, Equatable { case inactive, replayed, storage }

    /// One process uses a trusted app-owned directory. Exclusive, synced markers survive relaunch.
    @MainActor public struct PrivateProfileProbeClaim {
        private let directory: URL
        public init(directory: URL) throws {
            guard directory.isFileURL, directory.path.hasPrefix("/"),
                directory.standardizedFileURL.path != "/"
            else {
                throw PrivateProfileProbeClaimFailure.storage
            }
            self.directory = directory.standardizedFileURL
        }
        public func claim(_ plan: PrivateProfileProbePlan, at now: Date = Date()) throws {
            guard plan.isActive(at: now) else { throw PrivateProfileProbeClaimFailure.inactive }
            let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw PrivateProfileProbeClaimFailure.storage }
            defer { close(parent) }
            let name = plan.runID + ".claim"
            let descriptor = openat(
                parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard descriptor >= 0 else {
                if errno == EEXIST { throw PrivateProfileProbeClaimFailure.replayed }
                throw PrivateProfileProbeClaimFailure.storage
            }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                metadata.st_nlink == 1
            else {
                throw PrivateProfileProbeClaimFailure.storage
            }
            #if os(iOS)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: directory.appendingPathComponent(name).path)
            #endif
            guard fsync(descriptor) == 0, fsync(parent) == 0 else {
                throw PrivateProfileProbeClaimFailure.storage
            }
        }
    }
#endif
