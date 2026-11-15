import AuthenticationServices
import CloudKit
import Foundation
import Observation

#if canImport(UIKit)
    import UIKit
#endif

private final class DeletionIdentityObservers: @unchecked Sendable {
    let center: NotificationCenter
    let tokens: [any NSObjectProtocol]
    init(center: NotificationCenter, tokens: [any NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }
    deinit { for token in tokens { center.removeObserver(token) } }
}

/// Owns deletion's native identity and confirmation boundary. Its CloudKitAccountSession and Apple
/// authorizer are separate from login, so lifecycle cancellation never cancels the other host's sheet.
@MainActor @Observable public final class GatewayDeletionHost {
    public enum Phase: Equatable { case suspended, loading, ready, authorizing, working, unavailable }
    public enum Action: Equatable, Sendable {
        case deleteAccount
        case retryInitial(journalID: String)
        case recover(journalID: String?)
        case forgetCompleted(journalID: String)
        var isInitial: Bool {
            switch self {
            case .deleteAccount, .retryInitial: true
            case .recover, .forgetCompleted: false
            }
        }
    }
    public struct Confirmation: Identifiable, Equatable {
        public let id: UUID
        public let action: Action
        public var title: String {
            if case .forgetCompleted = action { return "Usunąć potwierdzenie z urządzenia?" }
            return action.isInitial ? "Rozpocząć usuwanie konta?" : "Odzyskać usuwanie konta?"
        }
        public var buttonTitle: String {
            if case .forgetCompleted = action { return "Usuń potwierdzenie" }
            return "Potwierdź przez Apple"
        }
        public var message: String {
            if case .forgetCompleted = action {
                return
                    "Usuniesz tylko zapis zakończonego usuwania z tego urządzenia. Nie cofa to usunięcia danych ani nie odłącza Apple. Jeśli odłączenie Apple nadal jest wymagane, wykonaj je wcześniej w ustawieniach konta Apple."
            }
            return action.isInitial
                ? "Usuwanie zamknie dostęp do tego konta Echoes i usunie jego dane. Potwierdzisz tożsamość przez Apple. Nie usunie to konta Apple."
                : "Odszukasz wcześniej rozpoczęte usuwanie po potwierdzeniu tożsamości przez Apple. Nie rozpocznie to usuwania nowego konta."
        }
        let generation: UUID
        let cloudRevision: UInt64
        let cloudHash: String
        let target: GatewayIdentityBinding?
        let expectedAccountID: String?
        let authentication: GatewayAuthenticatedIdentity?
        let receipt: GatewayDeletionProgress?
    }
    public private(set) var phase: Phase = .suspended
    public private(set) var confirmation: Confirmation?
    public private(set) var requests: [GatewayDeletionProgress] = []
    public private(set) var progress: GatewayDeletionProgress?
    public private(set) var errorMessage: String?
    public var isBusy: Bool { phase == .loading || phase == .authorizing || phase == .working }
    public let cloudKitAccount: CloudKitAccountSession
    @ObservationIgnored private let api: any GatewayAccountDeletionAPI
    @ObservationIgnored private let apple: any AppleGatewayIdentitySource
    @ObservationIgnored private let authorizer: any AppleGatewayAuthorizer
    @ObservationIgnored private let currentAuthentication: @MainActor () -> GatewayAuthenticatedIdentity?
    @ObservationIgnored private let resumeBindings: @MainActor (String) throws -> [GatewayIdentityBinding]
    @ObservationIgnored private let makeController:
        @MainActor (GatewayIdentityBinding) -> GatewayDeletionController
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let center: NotificationCenter
    @ObservationIgnored private var observers: DeletionIdentityObservers?
    @ObservationIgnored private var controllers: [String: GatewayDeletionController] = [:]
    private var bindings: [String: GatewayIdentityBinding] = [:]
    private var generation = UUID()
    private var foreground = false
    private var expectedCloudHash: String?
    private var storageBlocked = false

    public init(
        api: any GatewayAccountDeletionAPI, cloudKitAccount: CloudKitAccountSession,
        apple: any AppleGatewayIdentitySource, authorizer: any AppleGatewayAuthorizer,
        currentAuthentication: @escaping @MainActor () -> GatewayAuthenticatedIdentity?,
        resumeBindings: @escaping @MainActor (String) throws -> [GatewayIdentityBinding],
        makeController: @escaping @MainActor (GatewayIdentityBinding) -> GatewayDeletionController,
        isEnabled: @escaping @MainActor () -> Bool, notificationCenter: NotificationCenter = .default
    ) {
        self.api = api
        self.cloudKitAccount = cloudKitAccount
        self.apple = apple
        self.authorizer = authorizer
        self.currentAuthentication = currentAuthentication
        self.resumeBindings = resumeBindings
        self.makeController = makeController
        self.isEnabled = isEnabled
        center = notificationCenter
    }
    public func activate() async {
        foreground = true
        monitor()
        // Returning from this host's own Apple sheet is not a new operation.
        guard !isBusy else { return }
        let operation = reset(to: .loading)
        do {
            let name = try await cloudIdentity(operation)
            expectedCloudHash = try hash(name)
            try await reloadRequests(operation)
            try check(operation)
            phase = .ready
        } catch { await fail(error, operation: operation) }
    }
    public func suspend() {
        foreground = false
        _ = reset(to: .suspended)
    }
    public func stop() {
        observers = nil
        suspend()
        controllers.removeAll()
    }
    /// UI calls this for a login-context change. A matching session deliberately closes while
    /// deletion is working; accepted ticket operations remain scoped to their original account.
    public func authenticationChanged() {
        confirmation = nil
        if phase == .authorizing { identityChanged() }
    }
    public func cancelConfirmation() { confirmation = nil }
    public func ask(_ action: Action) {
        guard foreground, !isBusy, !storageBlocked, isEnabled(), cloudKitAccount.state == .ready,
            let name = cloudKitAccount.userRecordName, let hash = try? hash(name), hash == expectedCloudHash
        else { return }
        let authentication = currentAuthentication()
        let target: GatewayIdentityBinding?
        let accountID: String?
        var receipt: GatewayDeletionProgress?
        switch action {
        case .deleteAccount:
            target = authentication?.binding
            accountID = authentication?.accountID
            if let target, target.cloudKitAccountHash != hash { return }
        case .retryInitial(let id):
            guard let binding = bindings[id], let entry = requests.first(where: { $0.journalID == id }),
                entry.canRetryInitialRequest
            else { return }
            target = binding
            accountID = entry.accountID
        case .recover(let id):
            if let id {
                guard let binding = bindings[id], let entry = requests.first(where: { $0.journalID == id })
                else { return }
                target = binding
                accountID = entry.accountID
            } else {
                target = nil
                accountID = nil
            }
        case .forgetCompleted(let id):
            guard let binding = bindings[id], let entry = requests.first(where: { $0.journalID == id }),
                entry.completed
            else { return }
            target = binding
            accountID = entry.accountID
            receipt = entry
        }
        errorMessage = nil
        confirmation = .init(
            id: UUID(), action: action, generation: generation,
            cloudRevision: cloudKitAccount.identityRevision, cloudHash: hash,
            target: target, expectedAccountID: accountID, authentication: authentication, receipt: receipt)
    }
    /// One use, explicit confirmation. No automatic authorization sheet on activate/poll/resume.
    public func confirm(_ selected: Confirmation) async {
        guard let operation = beginConfirmation(selected) else { return }
        await performConfirmed(selected, operation: operation)
    }
    /// Reserve synchronously in the button action, before SwiftUI dismisses its alert binding.
    /// The asynchronous provider work is still fenced by generation/foreground checks.
    public func confirmFromUserAction(_ selected: Confirmation) {
        guard let operation = beginConfirmation(selected) else { return }
        Task { [weak self] in await self?.performConfirmed(selected, operation: operation) }
    }
    private func beginConfirmation(_ selected: Confirmation) -> UUID? {
        guard confirmation == selected else { return nil }
        guard !isBusy, selected.generation == generation,
            selected.cloudRevision == cloudKitAccount.identityRevision,
            selected.authentication == currentAuthentication()
        else {
            confirmation = nil
            return nil
        }
        confirmation = nil
        phase = selected.receipt == nil ? .authorizing : .working
        errorMessage = nil
        progress = nil
        requests = []
        return generation
    }
    private func performConfirmed(_ selected: Confirmation, operation: UUID) async {
        do {
            let original = try await cloudIdentity(operation)
            guard try hash(original) == selected.cloudHash else { throw GatewayFailure.accountMismatch }
            if case .forgetCompleted(let id) = selected.action {
                guard let binding = selected.target, let receipt = selected.receipt,
                    receipt.journalID == id, receipt.accountID == selected.expectedAccountID,
                    currentAuthentication() == selected.authentication
                else { throw GatewayFailure.superseded }
                try await controller(binding).forgetCompleted(receipt: receipt)
                try check(operation)
                try await reloadRequests(operation)
                try check(operation)
                phase = .ready
                return
            }
            let challenge = try await api.deletionChallenge(recovering: !selected.action.isInitial)
            try check(operation)
            let proof = try await authorizer.authorize(challenge: challenge)
            try check(operation)
            guard currentAuthentication() == selected.authentication else {
                throw GatewayFailure.accountMismatch
            }
            if let target = selected.target, proof.appleUserID != target.appleUserID {
                throw GatewayFailure.accountMismatch
            }
            let state = try await apple.credentialState(userID: proof.appleUserID)
            try check(operation)
            guard state == .authorized else { throw GatewayFailure.signInRequired }
            let current = try await cloudIdentity(operation)
            guard current == original else { throw GatewayFailure.accountMismatch }
            let binding = try GatewayIdentityBinding(
                appleUserID: proof.appleUserID, cloudKitRecordName: current)
            if let target = selected.target, target != binding { throw GatewayFailure.accountMismatch }
            phase = .working
            let controller = controller(binding)
            let result: GatewayDeletionProgress
            switch selected.action {
            case .deleteAccount:
                result = try await controller.request(
                    challenge: challenge, proof: proof, expectedAccountID: selected.expectedAccountID)
            case .retryInitial(let id):
                result = try await controller.request(
                    challenge: challenge, proof: proof, expectedAccountID: selected.expectedAccountID,
                    journalID: id)
            case .recover(let id):
                result = try await controller.recover(
                    challenge: challenge, proof: proof, expectedAccountID: selected.expectedAccountID,
                    journalID: id)
            case .forgetCompleted:
                throw GatewayFailure.superseded
            }
            try check(operation)
            try await reloadRequests(operation)
            try check(operation)
            progress = result
            phase = .ready
        } catch { await fail(error, operation: operation) }
    }
    public func poll(journalID: String) async { await run(journalID, action: .poll) }
    public func continueDeletion(journalID: String) async { await run(journalID, action: .advance) }
    public func restartPrivateScan(journalID: String) async { await run(journalID, action: .restart) }
    private enum Step { case poll, advance, restart }
    private func run(_ id: String, action: Step) async {
        guard foreground, !isBusy, let binding = bindings[id] else { return }
        confirmation = nil
        progress = nil
        errorMessage = nil
        phase = .working
        requests = []
        let operation = generation
        do {
            let name = try await cloudIdentity(operation)
            guard try hash(name) == binding.cloudKitAccountHash else { throw GatewayFailure.accountMismatch }
            let controller = controller(binding)
            let result: GatewayDeletionProgress
            switch action {
            case .poll: result = try await controller.poll(journalID: id)
            case .advance: result = try await controller.advance(journalID: id)
            case .restart: result = try await controller.restartPrivateScan(journalID: id)
            }
            try check(operation)
            try await reloadRequests(operation)
            try check(operation)
            progress = result
            phase = .ready
        } catch { await fail(error, operation: operation) }
    }
    private func reloadRequests(_ operation: UUID) async throws {
        try check(operation)
        guard let name = cloudKitAccount.userRecordName, cloudKitAccount.state == .ready else {
            throw GatewayFailure.accountMismatch
        }
        let nativeHash = try hash(name)
        guard expectedCloudHash == nil || nativeHash == expectedCloudHash else {
            throw GatewayFailure.accountMismatch
        }
        var result: [GatewayDeletionProgress] = []
        var mapping: [String: GatewayIdentityBinding] = [:]
        for binding in try resumeBindings(name) {
            guard binding.cloudKitAccountHash == nativeHash else { throw GatewayFailure.accountMismatch }
            let owned = try await controller(binding).ownedRequests()
            try check(operation)
            guard cloudKitAccount.state == .ready, let current = cloudKitAccount.userRecordName,
                try hash(current) == nativeHash
            else { throw GatewayFailure.accountMismatch }
            for entry in owned {
                guard mapping[entry.journalID] == nil else { throw GatewayFailure.storageUnavailable }
                result.append(entry)
                mapping[entry.journalID] = binding
            }
        }
        try check(operation)
        requests = result
        bindings = mapping
    }
    private func controller(_ binding: GatewayIdentityBinding) -> GatewayDeletionController {
        let key = binding.cloudKitAccountHash + ":" + binding.appleUserID
        if let current = controllers[key] {
            current.activate()
            return current
        }
        let current = makeController(binding)
        current.activate()
        controllers[key] = current
        return current
    }
    private func cloudIdentity(_ operation: UUID) async throws -> String {
        try check(operation)
        await cloudKitAccount.refresh()
        try check(operation)
        guard cloudKitAccount.state == .ready, let name = cloudKitAccount.userRecordName else {
            throw GatewayFailure.accountMismatch
        }
        return name
    }
    private func hash(_ name: String) throws -> String {
        try GatewayIdentityBinding(appleUserID: "deletion-native-check", cloudKitRecordName: name)
            .cloudKitAccountHash
    }
    private func check(_ operation: UUID) throws {
        guard operation == generation, foreground, !Task.isCancelled else { throw GatewayFailure.superseded }
        guard isEnabled() else { throw GatewayFailure.configuration }
    }
    @discardableResult private func reset(to phase: Phase) -> UUID {
        generation = UUID()
        confirmation = nil
        requests = []
        bindings = [:]
        progress = nil
        errorMessage = nil
        expectedCloudHash = nil
        storageBlocked = false
        authorizer.cancel()
        for controller in controllers.values { controller.suspend() }
        self.phase = phase
        return generation
    }
    private func fail(_ error: any Error, operation: UUID) async {
        guard operation == generation else { return }
        confirmation = nil
        progress = nil
        if (error as? GatewayFailure) == .accountMismatch {
            requests = []
            bindings = [:]
            expectedCloudHash = nil
            for controller in controllers.values { controller.suspend() }
        } else if (error as? GatewayFailure) != .storageUnavailable {
            try? await reloadRequests(operation)
        }
        guard operation == generation else { return }
        phase = .unavailable
        storageBlocked = (error as? GatewayFailure) == .storageUnavailable
        if error as? GatewayFailure == .transport {
            errorMessage = "Wynik etapu jest niepotwierdzony. Sprawdź status lub wznów zapisane zadanie."
        } else if case .server(.deletionInProgress, _, _) = error as? GatewayFailure {
            errorMessage = "To konto ma już rozpoczęte usuwanie. Wybierz odzyskiwanie zadania."
        } else if let safe = error as? GatewayFailure {
            errorMessage = safe.errorDescription
        } else if let safe = error as? GatewayDeletionFailure {
            errorMessage = safe.errorDescription
        } else if let safe = error as? PrivateDataFailure {
            errorMessage = safe.errorDescription
        } else if let safe = error as? GatewayLocalDataFailure {
            errorMessage = safe.errorDescription
        } else {
            errorMessage = "Nie udało się potwierdzić etapu usuwania. Sprawdź konto i spróbuj ponownie."
        }
    }
    private func identityChanged() {
        let wasForeground = foreground
        suspend()
        controllers.removeAll()
        cloudKitAccount.invalidate()
        let expected = generation
        if wasForeground {
            Task { [weak self] in
                guard let self, self.generation == expected, self.observers != nil else { return }
                await self.activate()
            }
        }
    }
    private func monitor() {
        guard observers == nil else { return }
        var tokens = [
            Notification.Name.CKAccountChanged, ASAuthorizationAppleIDProvider.credentialRevokedNotification,
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.identityChanged() }
            }
        }
        #if canImport(UIKit)
            tokens.append(
                center.addObserver(
                    forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.suspend() }
                })
        #endif
        observers = DeletionIdentityObservers(center: center, tokens: tokens)
    }
}
