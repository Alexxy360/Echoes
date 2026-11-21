#if DEBUG
    import AuthenticationServices
    import EchoesCloudKit
    import SwiftUI
    import UIKit

    /// Controlled Development host. The environment selects this screen, never the recipient of tokens.
    struct GatewayAuthCheckView: View {
        @Environment(\.scenePhase) private var scenePhase
        @State private var runtime: GatewayDevelopmentRuntime?
        @State private var path: [Destination] = []
        @State private var anchor = GatewayPresentationWindow()
        @State private var configurationFailed = false
        @State private var confirmation: SessionConfirmation?
        @State private var presentationError: String?

        private var isAuthenticationTrial: Bool {
            Bundle.main.object(forInfoDictionaryKey: "EchoesGatewayAuthenticationTrial") as? Bool == true
        }

        var body: some View {
            NavigationStack(path: $path) {
                Group {
                    if configurationFailed {
                        GatewayAuthUnavailableView()
                    } else if let runtime {
                        let host = runtime.authentication
                        Form {
                            Section("Logowanie Apple") {
                                Text(
                                    isAuthenticationTrial
                                        ? "Kontrolowana próba logowania i sesji. Potwierdź logowanie w arkuszu Apple."
                                        : "Kontrolowany test Development. Mapa i czat używają nowego adaptera; zwykła wersja aplikacji nie jest jeszcze przełączona."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                if host.phase == .ready {
                                    Label("Zalogowano", systemImage: "checkmark.circle")
                                        .accessibilityIdentifier("gateway.auth.ready")
                                    if isAuthenticationTrial, let accountID = host.accountID {
                                        LabeledContent("Identyfikator testu", value: accountID)
                                            .accessibilityIdentifier("gateway.auth.trialAccount")
                                    }
                                    Button("Wyloguj to urządzenie") { Task { await host.signOut() } }
                                    Button("Wyloguj wszystkie urządzenia", role: .destructive) {
                                        if let accountID = host.accountID {
                                            confirmation = .logoutAll(accountID)
                                        }
                                    }
                                } else {
                                    GatewayAppleSignInControl(
                                        anchor: anchor,
                                        enabled: host.phase == .signedOut || host.phase == .unavailable
                                    ) {
                                        Task { await host.signIn() }
                                    }
                                    .frame(height: 50).accessibilityIdentifier("gateway.auth.signIn")
                                    if host.isBusy {
                                        ProgressView("Sprawdzanie konta…")
                                    }
                                    Button("Sprawdź ponownie") { Task { await host.activate() } }
                                        .disabled(host.isBusy)
                                    if host.canResetSessions {
                                        Button("Wyloguj poprzednie sesje", role: .destructive) {
                                            confirmation = .reset
                                        }
                                        .disabled(host.isBusy).accessibilityIdentifier(
                                            "gateway.auth.resetSessions")
                                    }
                                }
                            }
                            if !isAuthenticationTrial {
                                Section("Okolica — Development") {
                                    Button("Otwórz mapę i czat") {
                                        Task {
                                            do {
                                                let id = try await runtime.openCommunity(isCurrent: {
                                                    scenePhase == .active && path.isEmpty
                                                })
                                                guard scenePhase == .active, path.isEmpty else {
                                                    runtime.discardCommunity(id)
                                                    return
                                                }
                                                path = [.community(id)]
                                            } catch {
                                                presentationError = error.localizedDescription
                                            }
                                        }
                                    }.disabled(host.phase != .ready || runtime.openingCommunity)
                                        .accessibilityIdentifier(
                                            "gateway.auth.community")
                                }
                                Section("Konto") {
                                    NavigationLink("Zgłoszenia", value: Destination.reports)
                                        .disabled(host.phase != .ready || runtime.openingCommunity)
                                        .accessibilityIdentifier("gateway.auth.reports")
                                    NavigationLink("Zgłoszenia zdjęć", value: Destination.photoReports)
                                        .disabled(host.phase != .ready || runtime.openingCommunity)
                                        .accessibilityIdentifier("gateway.auth.photoReports")
                                    NavigationLink("Ocena zdjęć", value: Destination.moderation)
                                        .disabled(host.phase != .ready || runtime.openingCommunity)
                                        .accessibilityIdentifier("gateway.auth.moderation")
                                    NavigationLink("Usuwanie konta", value: Destination.deletion)
                                        .disabled(host.isBusy).accessibilityIdentifier(
                                            "gateway.auth.deletion")
                                }
                            }
                            if let error = presentationError ?? host.errorMessage {
                                Section { Text(error).accessibilityIdentifier("gateway.auth.error") }
                            }
                            if host.logoutUnconfirmed {
                                Section {
                                    Text("Wylogowano lokalnie. Serwer nie potwierdził unieważnienia sesji.")
                                }
                            }
                            if host.resetCompleted {
                                Section {
                                    Text("Poprzednie sesje wylogowane. Zaloguj się ponownie.")
                                        .accessibilityIdentifier("gateway.auth.resetCompleted")
                                }
                            }
                        }
                        .confirmationDialog(
                            confirmation?.title ?? "",
                            isPresented: Binding(
                                get: { confirmation != nil },
                                set: { if !$0 { confirmation = nil } }), titleVisibility: .visible,
                            presenting: confirmation
                        ) { action in
                            Button(action.button, role: .destructive) {
                                Task {
                                    switch action {
                                    case .logoutAll(let expectedAccountID):
                                        guard host.accountID == expectedAccountID, host.phase == .ready else {
                                            return
                                        }
                                        await host.signOut(allDevices: true)
                                    case .reset: await host.resetSessions()
                                    }
                                }
                            }
                        } message: { action in
                            Text(action.message)
                        }
                        .onChange(of: host.canResetSessions) { _, canReset in
                            if !canReset, confirmation == .reset { confirmation = nil }
                        }
                    } else {
                        ProgressView("Przygotowanie…")
                    }
                }
                .navigationTitle("Logowanie — Development")
                .navigationDestination(for: Destination.self) { destination in
                    if let runtime, !isAuthenticationTrial {
                        switch destination {
                        case .reports:
                            ReportReviewView(
                                host: runtime.reportReviews, isCurrent: { path.last == .reports },
                                beforeOpening: { runtime.prepareReportReview() })
                        case .photoReports:
                            AvatarReportReviewView(
                                host: runtime.avatarReportReviews, isCurrent: { path.last == .photoReports },
                                beforeOpening: { runtime.prepareReportReview() })
                        case .moderation:
                            AvatarReviewView(
                                host: runtime.avatarReviews, isCurrent: { path.last == .moderation },
                                beforeOpening: { runtime.prepareReportReview() })
                        case .deletion: GatewayAccountDeletionView(host: runtime.deletion)
                        case .community(let id):
                            if runtime.community.isCurrent(id), runtime.communityPresentationID == id,
                                let services = runtime.communityServices
                            {
                                ContentView(
                                    services: services, usesNavigationStack: false,
                                    openNativeAccount: {
                                        guard runtime.community.isCurrent(id) else { return }
                                        path = [.deletion]
                                    }
                                ).id(id)
                            } else {
                                ContentUnavailableView("Sesja została zamknięta", systemImage: "lock")
                            }
                        }
                    }
                }
            }
            .background(GatewayWindowReader(anchor: anchor).frame(width: 0, height: 0))
            .overlay {
                if scenePhase != .active {
                    Color(.systemBackground).overlay { Text("Echoes").font(.title.bold()) }.ignoresSafeArea()
                }
            }
            .task {
                await prepare()
                while !Task.isCancelled {
                    runtime?.community.reconcileAuthorization()
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
            }
            .onChange(of: runtime?.authentication.authenticatedIdentity) { _, _ in
                confirmation = nil
                presentationError = nil
                runtime?.invalidateCommunityOpening()
                runtime?.avatarReportReviews.invalidate()
                runtime?.deletion.authenticationChanged()
            }
            .onChange(of: runtime?.authentication.accountID) { _, accountID in
                guard isAuthenticationTrial, let accountID, UUID(uuidString: accountID) != nil else {
                    return
                }
                // This non-secret test identifier binds operator cleanup to the phone's actual login.
                // Capture only this prefixed line locally; never write Apple credentials or tokens.
                FileHandle.standardOutput.write(
                    Data("ECHOES_GATEWAY_AUTH_TRIAL accountID=\(accountID)\n".utf8))
            }
            .onChange(of: runtime?.community.presentation?.id) { _, id in
                if id == nil, path.contains(where: { $0.communityID != nil }) { path = [] }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    runtime?.invalidateCommunityOpening()
                    runtime?.avatarReportReviews.setForeground(false)
                }
                if phase == .background {
                    runtime?.authentication.suspend()
                    runtime?.deletion.suspend()
                } else if phase == .active {
                    Task {
                        if path.isEmpty { await runtime?.authentication.activate() }
                    }
                }
            }
            .onChange(of: path) { previous, current in
                runtime?.invalidateCommunityOpening()
                if current.last != .photoReports { runtime?.avatarReportReviews.setForeground(false) }
                let closing = previous.compactMap(\.communityID).first
                Task {
                    if let closing, !current.contains(.community(closing)) {
                        await runtime?.closeCommunity(closing)
                    }
                    if path.isEmpty, current.isEmpty { await runtime?.authentication.activate() }
                }
            }
            .onDisappear {
                runtime?.invalidateCommunityOpening()
                runtime?.avatarReportReviews.setForeground(false)
                runtime?.authentication.stop()
                runtime?.deletion.stop()
            }
        }

        private enum SessionConfirmation: Equatable {
            case logoutAll(String)
            case reset
            var title: String {
                self == .reset ? "Wylogować poprzednie sesje Echoes?" : "Wylogować wszystkie urządzenia?"
            }
            var button: String { self == .reset ? "Potwierdź przez Apple" : "Wyloguj wszystkie" }
            var message: String {
                self == .reset
                    ? "Wyloguje wszystkie sesje tego konta w Echoes. Potwierdzisz tożsamość przez Apple, a następnie zalogujesz się ponownie."
                    : "Na wszystkich urządzeniach będzie potrzebne ponowne logowanie."
            }
        }

        private enum Destination: Hashable {
            case reports
            case photoReports
            case deletion
            case moderation
            case community(UUID)
            var communityID: UUID? {
                if case .community(let id) = self { return id }
                return nil
            }
        }
        private func prepare() async {
            guard runtime == nil, !configurationFailed else { return }
            do {
                let current = try GatewayDevelopmentRuntime(anchor: { [weak anchor] in anchor?.window })
                runtime = current
                if scenePhase == .active { await current.authentication.activate() }
            } catch {
                configurationFailed = true
                FileHandle.standardOutput.write(Data("ECHOES_GATEWAY_AUTH_CHECK state=unconfigured\n".utf8))
            }
        }
    }

    private struct GatewayAuthUnavailableView: View {
        var body: some View {
            ContentUnavailableView(
                "Logowanie nieaktywne", systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text(
                    "Ten test wymaga przygotowanej konfiguracji Development. Żadne dane logowania nie są teraz wysyłane."
                )
            )
            .accessibilityIdentifier("gateway.auth.unconfigured")
        }
    }

    private struct GatewayAppleSignInControl: UIViewRepresentable {
        let anchor: GatewayPresentationWindow
        let enabled: Bool
        let action: @MainActor @Sendable () -> Void
        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
        func makeUIView(context: Context) -> WindowTrackingAppleControl {
            let view = WindowTrackingAppleControl()
            view.button.addTarget(
                context.coordinator, action: #selector(Coordinator.handleSignInPress), for: .touchUpInside)
            return view
        }
        func updateUIView(_ view: WindowTrackingAppleControl, context: Context) {
            context.coordinator.parent = self
            view.button.isEnabled = enabled
        }
        @MainActor final class Coordinator: NSObject {
            var parent: GatewayAppleSignInControl
            init(parent: GatewayAppleSignInControl) { self.parent = parent }
            @objc func handleSignInPress() { parent.action() }
        }
    }

    private final class WindowTrackingAppleControl: UIView {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: .black)
        init() {
            super.init(frame: .zero)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: leadingAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        required init?(coder: NSCoder) { nil }
    }

    #Preview("Nieaktywna konfiguracja") { GatewayAuthUnavailableView() }
    #Preview("Przycisk Apple") {
        GatewayAppleSignInControl(anchor: GatewayPresentationWindow(), enabled: true, action: {}).frame(
            height: 50
        ).padding()
    }
#endif
