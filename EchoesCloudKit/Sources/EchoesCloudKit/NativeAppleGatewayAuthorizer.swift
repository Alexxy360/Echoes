#if os(iOS)
    import AuthenticationServices
    import Foundation
    import UIKit

    /// Uses the window hosting the sign-in control, never an arbitrary scene or a new fallback window.
    @MainActor
    public final class NativeAppleGatewayAuthorizer: AppleGatewayAuthorizer {
        private let anchor: @MainActor () -> UIWindow?
        private var current: AppleAuthorizationOperation?
        private var timeout: Task<Void, Never>?
        private let now: @Sendable () -> Date
        public init(
            anchor: @escaping @MainActor () -> UIWindow?, now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.anchor = anchor
            self.now = now
        }
        public func authorize(challenge: GatewayChallenge) async throws -> AppleGatewayProof {
            guard current == nil else { throw GatewayFailure.operationInProgress }
            guard let window = anchor(), !window.isHidden,
                window.windowScene?.activationState == .foregroundActive
            else { throw GatewayFailure.configuration }
            if Task.isCancelled { throw GatewayFailure.cancelled }
            let id = UUID()
            let attempt = try AppleGatewayAuthorizationAttempt(challenge: challenge, now: now)
            let request = try attempt.makeRequest()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(throwing: GatewayFailure.cancelled)
                        return
                    }
                    let operation = AppleAuthorizationOperation(
                        id: id, window: window, attempt: attempt,
                        request: request, continuation: continuation
                    ) { [weak self] id in self?.finish(id: id) }
                    current = operation
                    let expiryDelay = max(0, Double(challenge.expiresAt) - now().timeIntervalSince1970)
                    timeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(expiryDelay)) } catch { return }
                        self?.cancel(id: id)
                    }
                    operation.controller.performRequests()
                }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in self?.cancel(id: id) }
            }
        }
        public func cancel() { if let current { cancel(id: current.id) } }
        private func cancel(id: UUID) {
            guard let operation = current, operation.id == id else { return }
            operation.cancel()
            finish(id: id)
        }
        private func finish(id: UUID) {
            guard current?.id == id else { return }
            timeout?.cancel()
            timeout = nil
            current = nil
        }
    }

    @MainActor
    private final class AppleAuthorizationOperation: NSObject, ASAuthorizationControllerDelegate,
        ASAuthorizationControllerPresentationContextProviding
    {
        let id: UUID
        let controller: ASAuthorizationController
        private let window: UIWindow
        private let attempt: AppleGatewayAuthorizationAttempt
        private var continuation: CheckedContinuation<AppleGatewayProof, any Error>?
        private let finished: @MainActor (UUID) -> Void
        init(
            id: UUID, window: UIWindow, attempt: AppleGatewayAuthorizationAttempt,
            request: ASAuthorizationAppleIDRequest,
            continuation: CheckedContinuation<AppleGatewayProof, any Error>,
            finished: @escaping @MainActor (UUID) -> Void
        ) {
            self.id = id
            self.window = window
            self.attempt = attempt
            self.continuation = continuation
            self.finished = finished
            controller = ASAuthorizationController(authorizationRequests: [request])
            super.init()
            controller.delegate = self
            controller.presentationContextProvider = self
        }
        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window }
        func authorizationController(
            controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
        ) {
            guard controller === self.controller, continuation != nil else { return }
            do {
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                    throw GatewayFailure.invalidInput
                }
                complete(.success(try attempt.complete(credential)))
            } catch { complete(.failure(error as? GatewayFailure ?? .invalidResponse)) }
        }
        func authorizationController(
            controller: ASAuthorizationController, didCompleteWithError error: any Error
        ) {
            guard controller === self.controller else { return }
            let cancelled = (error as? ASAuthorizationError)?.code == .canceled
            complete(.failure(cancelled ? GatewayFailure.cancelled : GatewayFailure.transport))
        }
        func cancel() {
            attempt.cancel()
            complete(.failure(GatewayFailure.cancelled))
            controller.cancel()
        }
        private func complete(_ result: Result<AppleGatewayProof, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            controller.delegate = nil
            controller.presentationContextProvider = nil
            continuation.resume(with: result)
            finished(id)
        }
    }
#endif
