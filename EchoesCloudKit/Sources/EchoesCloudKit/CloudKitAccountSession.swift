import CloudKit
import Foundation
import Observation

// Immutable token; NotificationCenter permits removing an observer from any thread.
private final class AccountNotificationToken: @unchecked Sendable {
    let value: any NSObjectProtocol
    init(_ value: any NSObjectProtocol) { self.value = value }
    deinit { NotificationCenter.default.removeObserver(value) }
}

public enum CloudKitAccountAvailability: Equatable, Sendable {
    case available, noAccount, restricted, temporarilyUnavailable, unknown
}

@MainActor
public protocol CloudKitAccountSource {
    func availability() async throws -> CloudKitAccountAvailability
    func userRecordName() async throws -> String
}

/// Only initialize inside a host app with verified CloudKit provisioning and entitlements.
/// The migration deliberately does not install guessed container identifiers into the app.
@MainActor
public final class NativeCloudKitAccountSource: CloudKitAccountSource {
    private let container: CKContainer

    public init(configuration: CloudKitConfiguration) {
        container = CKContainer(identifier: configuration.containerIdentifier)
    }

    public func availability() async throws -> CloudKitAccountAvailability {
        switch try await container.accountStatus() {
        case .available: .available
        case .noAccount: .noAccount
        case .restricted: .restricted
        case .temporarilyUnavailable: .temporarilyUnavailable
        case .couldNotDetermine: .unknown
        @unknown default: .unknown
        }
    }

    public func userRecordName() async throws -> String {
        try await container.userRecordID().recordName
    }
}

@MainActor
@Observable
public final class CloudKitAccountSession {
    public enum State: Equatable { case idle, checking, ready, unavailable }
    public private(set) var state: State = .idle
    public private(set) var availability: CloudKitAccountAvailability = .unknown
    public private(set) var userRecordName: String?
    public private(set) var failure: CloudKitFailure?
    /// Changes before each identity recheck, so consumers can invalidate account-scoped caches.
    public private(set) var identityRevision: UInt64 = 0
    @ObservationIgnored private let source: any CloudKitAccountSource
    @ObservationIgnored private var observer: AccountNotificationToken?

    public init(source: any CloudKitAccountSource) { self.source = source }

    /// The host calls start/stop with its lifecycle; no notification observer is leaked.
    public func startMonitoring() {
        guard observer == nil else { return }
        observer = AccountNotificationToken(
            NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.observer != nil else { return }
                    await self.refresh()
                }
            })
    }

    public func stopMonitoring() {
        observer = nil
        invalidate()
    }

    public func refresh() async {
        invalidate()
        let revision = identityRevision
        state = .checking
        defer {
            if revision == identityRevision, state == .checking {
                state = .idle
                availability = .unknown
            }
        }
        do {
            let current = try await source.availability()
            guard revision == identityRevision, !Task.isCancelled else { return }
            availability = current
            guard current == .available else {
                state = .unavailable
                failure =
                    switch current {
                    case .noAccount: .notAuthenticated
                    case .restricted: .restricted
                    default: .unavailable
                    }
                return
            }
            let name = try await source.userRecordName()
            guard revision == identityRevision, !Task.isCancelled else { return }
            guard !name.isEmpty, name != CKCurrentUserDefaultName else {
                throw CloudKitFailure.notAuthenticated
            }
            userRecordName = name
            state = .ready
        } catch {
            guard revision == identityRevision else { return }
            state = .unavailable
            failure = CloudKitFailure.classify(error)
        }
    }

    /// Must be called before clearing/replacing account-owned domain state in the host app.
    public func invalidate() {
        identityRevision &+= 1
        userRecordName = nil
        availability = .unknown
        failure = nil
        state = .idle
    }
}
