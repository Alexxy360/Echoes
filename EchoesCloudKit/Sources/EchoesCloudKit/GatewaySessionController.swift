import Foundation

/// One controller per service origin. The host must check native Apple credential state and current
/// CloudKit identity before restore, and invalidate immediately on either account-change notification.
public actor GatewaySessionController {
    public enum State: Equatable, Sendable {
        case signedOut, restoring, signingIn
        case ready(accountID: String)
        case renewing(accountID: String)
        case signInRequired, storageBlocked
    }
    public enum LogoutResult: Equatable, Sendable { case serverConfirmed, localOnly }
    public private(set) var state: State = .signedOut
    private let api: any GatewayAuthenticationAPI
    private let storage: any GatewaySessionStorage
    private let now: @Sendable () -> Date
    private var revision = UUID()
    private var binding: GatewayIdentityBinding?
    private var pair: GatewaySessionPair?
    private var renewalTask: Task<GatewaySessionPair, any Error>?

    public init(
        api: any GatewayAuthenticationAPI, storage: any GatewaySessionStorage,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.storage = storage
        self.now = now
    }

    /// A hint for getCredentialState(forUserID:), not proof of an authenticated user.
    public func storedIdentity() throws -> GatewayIdentityBinding? {
        let saved = try read()
        return saved?.state == .ready ? saved?.binding : nil
    }

    public func restore(verifiedBinding: GatewayIdentityBinding) async throws {
        guard pair == nil, renewalTask == nil, state != .restoring, state != .signingIn else {
            throw GatewayFailure.operationInProgress
        }
        revision = UUID()
        let operation = revision
        state = .restoring
        do {
            guard let saved = try read(), saved.state != .signedOut else {
                state = .signedOut
                return
            }
            guard saved.state == .ready, saved.binding == verifiedBinding, let storedPair = saved.pair else {
                try persist(state: .signedOut, binding: nil, pair: nil)
                throw GatewayFailure.signInRequired
            }
            try storedPair.validate(now: now(), allowExpiredAccess: true)
            binding = verifiedBinding
            pair = storedPair
            if Double(storedPair.expiresAt) <= now().timeIntervalSince1970 + 30 {
                _ = try await rotatedPair()
            } else {
                let status = try await api.session(token: storedPair.sessionToken)
                guard operation == revision else { throw GatewayFailure.superseded }
                guard status.protocolVersion == 1, status.accountID == storedPair.accountID,
                    status.expiresAt == storedPair.expiresAt
                else {
                    throw GatewayFailure.accountMismatch
                }
            }
            guard operation == revision else { throw GatewayFailure.superseded }
            state = .ready(accountID: storedPair.accountID)
        } catch {
            guard operation == revision else { throw GatewayFailure.superseded }
            pair = nil
            binding = nil
            if state != .storageBlocked {
                state = .signInRequired
                if error as? GatewayFailure != .transport {
                    try persist(state: .signedOut, binding: nil, pair: nil)
                }
            }
            throw error
        }
    }

    /// The proof must come from the native request bound to this challenge and verifiedBinding.
    /// No retry of a code, no silent replacement of the five-device grant limit.
    public func signIn(
        challenge: GatewayChallenge, identityToken: GatewaySecret,
        authorizationCode: GatewaySecret, verifiedBinding: GatewayIdentityBinding
    ) async throws {
        guard pair == nil, renewalTask == nil, state != .signingIn, state != .restoring else {
            throw GatewayFailure.operationInProgress
        }
        try challenge.validate(now: now())
        try clear(to: .signingIn)
        let operation = revision
        do {
            let result = try await api.login(
                challengeID: challenge.challengeID,
                identityToken: identityToken, authorizationCode: authorizationCode)
            guard operation == revision else {
                try? await api.logout(token: result.renewalToken)
                throw GatewayFailure.superseded
            }
            try result.validate(now: now())
            do { try persist(state: .ready, binding: verifiedBinding, pair: result) } catch {
                try? await api.logout(token: result.renewalToken)
                throw error
            }
            binding = verifiedBinding
            pair = result
            state = .ready(accountID: result.accountID)
        } catch {
            guard operation == revision else { throw GatewayFailure.superseded }
            if state != .storageBlocked { state = .signInRequired }
            throw error
        }
    }

    /// Coalesces callers onto one rotation. Cancellation of a caller does not cancel another caller's
    /// rotation. Sign-out/account invalidation still fences the operation and its late result.
    public func accessToken() async throws -> GatewaySecret {
        if Task.isCancelled { throw GatewayFailure.cancelled }
        switch state {
        case .restoring, .signingIn: throw GatewayFailure.operationInProgress
        case .storageBlocked: throw GatewayFailure.storageUnavailable
        case .ready, .renewing: break
        default: throw GatewayFailure.signInRequired
        }
        let operation = revision
        if let renewalTask {
            let result = try await renewalTask.value
            guard operation == revision else { throw GatewayFailure.superseded }
            if Task.isCancelled { throw GatewayFailure.cancelled }
            return result.sessionToken
        }
        guard let pair, binding != nil else { throw GatewayFailure.signInRequired }
        if Double(pair.expiresAt) > now().timeIntervalSince1970 + 30 { return pair.sessionToken }
        let result = try await rotatedPair()
        if Task.isCancelled { throw GatewayFailure.cancelled }
        return result.sessionToken
    }

    public func signOut(allDevices: Bool = false) async throws -> LogoutResult {
        let saved = pair == nil ? try read() : nil
        let previous = pair ?? (saved?.state == .ready ? saved?.pair : nil)
        let hadPendingOperation =
            state == .signingIn || state == .restoring || renewalTask != nil
            || saved?.state == .renewalPending
        // Durable tombstone first. If Keychain fails, report failure instead of promising durable logout.
        try clear(to: .signedOut)
        guard let previous else { return hadPendingOperation ? .localOnly : .serverConfirmed }
        do {
            if allDevices {
                try await api.logoutAll(token: previous.sessionToken)
            } else {
                try await api.logout(token: previous.renewalToken)
            }
            return .serverConfirmed
        } catch {
            return .localOnly
        }
    }

    /// Call before replacing/clearing account-scoped UI and caches. Never awaits network.
    public func invalidateForAccountChange() throws { try clear(to: .signInRequired) }

    private func rotatedPair() async throws -> GatewaySessionPair {
        if let renewalTask { return try await renewalTask.value }
        guard let previous = pair, let currentBinding = binding,
            Double(previous.renewalExpiresAt) > now().timeIntervalSince1970
        else {
            try clear(to: .signInRequired)
            throw GatewayFailure.signInRequired
        }
        let operation = revision
        // The old proof is removed from durable storage BEFORE dispatch. A process crash or lost
        // response can never cause restore to send it a second time.
        try persist(state: .renewalPending, binding: currentBinding, pair: nil)
        state = .renewing(accountID: previous.accountID)
        let task = Task {
            try await self.finishRotation(previous: previous, binding: currentBinding, operation: operation)
        }
        renewalTask = task
        return try await task.value
    }

    private func finishRotation(
        previous: GatewaySessionPair, binding currentBinding: GatewayIdentityBinding,
        operation: UUID
    ) async throws -> GatewaySessionPair {
        do {
            guard operation == revision else { throw GatewayFailure.superseded }
            let result = try await api.renew(token: previous.renewalToken)
            guard operation == revision else {
                try? await api.logout(token: result.renewalToken)
                throw GatewayFailure.superseded
            }
            try result.validate(now: now())
            guard result.accountID == previous.accountID,
                result.renewalExpiresAt <= previous.renewalExpiresAt,
                result.renewalToken != previous.renewalToken
            else { throw GatewayFailure.accountMismatch }
            do { try persist(state: .ready, binding: currentBinding, pair: result) } catch {
                try? await api.logout(token: result.renewalToken)
                throw error
            }
            guard operation == revision else { throw GatewayFailure.superseded }
            pair = result
            state = .ready(accountID: result.accountID)
            renewalTask = nil
            return result
        } catch {
            guard operation == revision else { throw GatewayFailure.superseded }
            pair = nil
            binding = nil
            renewalTask = nil
            if state != .storageBlocked { state = .signInRequired }
            // Keep renewalPending if failure was uncertain. No path retries the old proof.
            throw error
        }
    }

    private func clear(to state: State) throws {
        revision = UUID()
        pair = nil
        binding = nil
        renewalTask = nil
        try persist(state: .signedOut, binding: nil, pair: nil)
        self.state = state
    }
    private func read() throws -> StoredGatewaySession? {
        do {
            guard let bytes = try storage.read() else { return nil }
            guard bytes.count <= 8_192 else { throw GatewayFailure.storageUnavailable }
            let saved = try JSONDecoder().decode(StoredGatewaySession.self, from: bytes)
            guard saved.version == 1, saved.origin == api.origin else {
                throw GatewayFailure.storageUnavailable
            }
            return saved
        } catch {
            state = .storageBlocked
            throw GatewayFailure.storageUnavailable
        }
    }
    private func persist(
        state: StoredGatewaySession.State, binding: GatewayIdentityBinding?, pair: GatewaySessionPair?
    ) throws {
        do {
            let bytes = try JSONEncoder().encode(
                StoredGatewaySession(
                    version: 1, origin: api.origin,
                    binding: binding, state: state, pair: pair))
            try storage.write(bytes)
        } catch {
            self.state = .storageBlocked
            throw GatewayFailure.storageUnavailable
        }
    }
}
