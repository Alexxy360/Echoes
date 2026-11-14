import AuthenticationServices
import CloudKit
import Foundation
import Observation

#if canImport(UIKit)
    import UIKit
#endif

private final class GatewayIdentityObservers: @unchecked Sendable {
    let center: NotificationCenter
    let tokens: [any NSObjectProtocol]
    init(center: NotificationCenter, tokens: [any NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }
    deinit { for token in tokens { center.removeObserver(token) } }
}

/// Owns the UI authentication boundary. Domain clients must obtain access through this host, so a
/// background/identity event closes the boundary synchronously, before the session actor is reached.
@MainActor @Observable
public final class GatewaySignInHost {
    public enum Phase: Equatable {
        case suspended, checking, signedOut, signingIn, signingOut, ready, unavailable
    }
    public private(set) var phase: Phase = .suspended
    public private(set) var errorMessage: String?
    public private(set) var accountID: String?
    public private(set) var logoutUnconfirmed = false
    public let cloudKitAccount: CloudKitAccountSession
    @ObservationIgnored private let api: any GatewayAuthenticationAPI
    @ObservationIgnored private let session: GatewaySessionController
    @ObservationIgnored private let apple: any AppleGatewayIdentitySource
    @ObservationIgnored private let authorizer: any AppleGatewayAuthorizer
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let clearDomainState: @MainActor () -> Void
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var observers: GatewayIdentityObservers?
    @ObservationIgnored private var barrier: Task<Void, any Error>?
    private var generation = UUID()
    private var foreground = false
    private var authorizedRevision: UInt64?
    private var validatedAt: Date?

    public init(
        api: any GatewayAuthenticationAPI, session: GatewaySessionController,
        cloudKitAccount: CloudKitAccountSession, apple: any AppleGatewayIdentitySource,
        authorizer: any AppleGatewayAuthorizer, isEnabled: @escaping @MainActor () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }, notificationCenter: NotificationCenter = .default,
        clearDomainState: @escaping @MainActor () -> Void
    ) {
        self.api = api
        self.session = session
        self.cloudKitAccount = cloudKitAccount
        self.apple = apple
        self.authorizer = authorizer
        self.isEnabled = isEnabled
        self.now = now
        self.notificationCenter = notificationCenter
        self.clearDomainState = clearDomainState
    }

    public func activate() async {
        foreground = true
        startMonitoring()
        // Apple sheets may make a scene inactive and active again. Do not cancel the user's own sheet.
        guard phase != .signingIn, phase != .signingOut, phase != .checking else { return }
        let operation = fence(to: .checking, erase: false)
        errorMessage = nil
        do {
            try await waitForBarrier(operation)
            let name = try await cloudIdentity(operation)
            guard let saved = try await session.storedIdentity() else {
                try check(operation)
                phase = .signedOut
                return
            }
            try await checkApple(saved.appleUserID, operation: operation)
            let binding = try GatewayIdentityBinding(appleUserID: saved.appleUserID, cloudKitRecordName: name)
            guard binding == saved else { throw GatewayFailure.accountMismatch }
            let revision = cloudKitAccount.identityRevision
            try await session.restore(verifiedBinding: binding)
            try check(operation, cloudRevision: revision)
            if case .ready(let identifier) = await session.state {
                grantUI(identifier: identifier, cloudRevision: revision)
            } else {
                phase = .signedOut
            }
        } catch { await fail(error, operation: operation) }
    }

    /// Explicit user action only. No automatic sheet or code exchange during activate/restore.
    public func signIn() async {
        guard foreground, [.signedOut, .unavailable].contains(phase) else { return }
        let operation = fence(to: .signingIn, erase: false)
        errorMessage = nil
        logoutUnconfirmed = false
        do {
            try await waitForBarrier(operation)
            let originalCloudName = try await cloudIdentity(operation)
            let originalRevision = cloudKitAccount.identityRevision
            let challenge = try await api.challenge(purpose: .login)
            try check(operation, cloudRevision: originalRevision)
            let proof = try await authorizer.authorize(challenge: challenge)
            try check(operation, cloudRevision: originalRevision)
            try await checkApple(proof.appleUserID, operation: operation)
            // Recheck iCloud after the interactive sheet, rather than binding a stale pre-sheet ID.
            let currentCloudName = try await cloudIdentity(operation)
            guard currentCloudName == originalCloudName else { throw GatewayFailure.accountMismatch }
            let currentRevision = cloudKitAccount.identityRevision
            let binding = try GatewayIdentityBinding(
                appleUserID: proof.appleUserID, cloudKitRecordName: currentCloudName)
            try await session.signIn(
                challenge: challenge, identityToken: proof.identityToken,
                authorizationCode: proof.authorizationCode, verifiedBinding: binding)
            try check(operation, cloudRevision: currentRevision)
            guard case .ready(let identifier) = await session.state else {
                throw GatewayFailure.signInRequired
            }
            grantUI(identifier: identifier, cloudRevision: currentRevision)
        } catch { await fail(error, operation: operation) }
    }

    public func accessToken() async throws -> GatewaySecret {
        guard foreground, phase == .ready else { throw GatewayFailure.signInRequired }
        if let validatedAt, now().timeIntervalSince(validatedAt) >= 60 || now() < validatedAt {
            await activate()
        }
        guard phase == .ready, let revision = authorizedRevision else { throw GatewayFailure.signInRequired }
        let operation = generation
        do {
            try check(operation, cloudRevision: revision)
            let token = try await session.accessToken()
            try check(operation, cloudRevision: revision)
            return token
        } catch {
            await fail(error, operation: operation)
            throw error
        }
    }

    public func suspend() {
        foreground = false
        _ = fence(to: .suspended, erase: false)
    }

    public func stop() {
        observers = nil
        suspend()
    }

    public func signOut(allDevices: Bool = false) async {
        let operation = resetUI(to: .signingOut)
        let previous = barrier
        let session = self.session
        // New login/restore waits for this operation, including its durable tombstone. This also
        // prevents an old logout queued behind another barrier from wiping a newly signed-in user.
        let logout = Task {
            _ = try? await previous?.value
            return try await session.signOut(allDevices: allDevices)
        }
        barrier = Task { _ = try await logout.value }
        do {
            let result = try await logout.value
            guard operation == generation else { return }
            logoutUnconfirmed = result == .localOnly
            phase = foreground ? .signedOut : .suspended
            errorMessage = nil
        } catch { await fail(error, operation: operation) }
    }

    private func grantUI(identifier: String, cloudRevision: UInt64) {
        accountID = identifier
        authorizedRevision = cloudRevision
        validatedAt = now()
        phase = .ready
    }
    private func check(_ operation: UUID, cloudRevision: UInt64? = nil) throws {
        guard operation == generation, foreground, !Task.isCancelled else { throw GatewayFailure.superseded }
        guard isEnabled() else { throw GatewayFailure.configuration }
        if let cloudRevision {
            guard cloudKitAccount.state == .ready, cloudKitAccount.identityRevision == cloudRevision else {
                throw GatewayFailure.accountMismatch
            }
        }
    }
    private func waitForBarrier(_ operation: UUID) async throws {
        try await barrier?.value
        try check(operation)
    }
    private func cloudIdentity(_ operation: UUID) async throws -> String {
        try check(operation)
        await cloudKitAccount.refresh()
        try check(operation)
        guard cloudKitAccount.state == .ready, let name = cloudKitAccount.userRecordName else {
            throw cloudKitAccount.failure ?? CloudKitFailure.unavailable
        }
        return name
    }
    private func checkApple(_ userID: String, operation: UUID) async throws {
        let state = try await apple.credentialState(userID: userID)
        try check(operation)
        guard state == .authorized else { throw GatewayFailure.signInRequired }
    }
    private func resetUI(to phase: Phase) -> UUID {
        generation = UUID()
        self.phase = phase
        accountID = nil
        authorizedRevision = nil
        validatedAt = nil
        authorizer.cancel()
        cloudKitAccount.invalidate()
        clearDomainState()
        return generation
    }
    @discardableResult private func fence(to phase: Phase, erase: Bool) -> UUID {
        let operation = resetUI(to: phase)
        let previous = barrier
        let session = self.session
        barrier = Task {
            _ = try? await previous?.value
            if erase { try await session.invalidateForAccountChange() } else { await session.suspendAccess() }
        }
        return operation
    }
    private func fail(_ error: any Error, operation: UUID) async {
        guard operation == generation else { return }
        let failure = error as? GatewayFailure
        let erase = failure == .signInRequired || failure == .accountMismatch
        let next: Phase = erase || failure == .cancelled ? .signedOut : .unavailable
        let newOperation = fence(to: next, erase: erase)
        errorMessage = failure?.localizedDescription ?? CloudKitFailure.classify(error).localizedDescription
        do { try await barrier?.value } catch {
            guard newOperation == generation else { return }
            phase = .unavailable
            errorMessage = GatewayFailure.storageUnavailable.localizedDescription
        }
    }
    private func identityChanged() {
        let operation = fence(to: foreground ? .signedOut : .suspended, erase: true)
        let pending = barrier
        errorMessage = GatewayFailure.signInRequired.localizedDescription
        Task { [weak self] in
            do { try await pending?.value } catch {
                guard let self, self.generation == operation else { return }
                self.phase = .unavailable
                self.errorMessage = GatewayFailure.storageUnavailable.localizedDescription
            }
        }
    }
    private func startMonitoring() {
        guard observers == nil else { return }
        let tokens = [
            Notification.Name.CKAccountChanged, ASAuthorizationAppleIDProvider.credentialRevokedNotification,
        ].map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.identityChanged() }
            }
        }
        #if canImport(UIKit)
            let locked = notificationCenter.addObserver(
                forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            }
            observers = GatewayIdentityObservers(center: notificationCenter, tokens: tokens + [locked])
        #else
            observers = GatewayIdentityObservers(center: notificationCenter, tokens: tokens)
        #endif
    }
}
