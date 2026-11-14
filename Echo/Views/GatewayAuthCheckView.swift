#if DEBUG
    import AuthenticationServices
    import EchoesCloudKit
    import SwiftUI
    import UIKit

    /// Controlled Development host. The environment selects this screen, never the recipient of tokens.
    struct GatewayAuthCheckView: View {
        @Environment(\.scenePhase) private var scenePhase
        @State private var host: GatewaySignInHost?
        @State private var anchor = GatewayPresentationWindow()
        @State private var configurationFailed = false
        @State private var confirmation: SessionConfirmation?

        var body: some View {
            NavigationStack {
                Group {
                    if configurationFailed {
                        GatewayAuthUnavailableView()
                    } else if let host {
                        Form {
                            Section("Logowanie Apple") {
                                Text(
                                    "Kontrolowany test logowania. Funkcje społecznościowe nie są jeszcze przełączone."
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                if host.phase == .ready {
                                    Label("Zalogowano", systemImage: "checkmark.circle")
                                        .accessibilityIdentifier("gateway.auth.ready")
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
                            if let error = host.errorMessage {
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
                        .onChange(of: host.accountID) { _, _ in confirmation = nil }
                        .onChange(of: host.canResetSessions) { _, canReset in
                            if !canReset, confirmation == .reset { confirmation = nil }
                        }
                    } else {
                        ProgressView("Przygotowanie…")
                    }
                }
                .navigationTitle("Logowanie — Development")
            }
            .overlay {
                if scenePhase != .active {
                    Color(.systemBackground).overlay { Text("Echoes").font(.title.bold()) }.ignoresSafeArea()
                }
            }
            .task { await prepare() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    host?.suspend()
                } else if phase == .active {
                    Task { await host?.activate() }
                }
            }
            .onDisappear { host?.stop() }
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

        private func prepare() async {
            guard host == nil, !configurationFailed else { return }
            do {
                let activation = try GatewayDevelopmentActivation(
                    infoDictionary: Bundle.main.infoDictionary ?? [:],
                    bundleIdentifier: Bundle.main.bundleIdentifier)
                let api = try ActivatedGatewayAuthenticationAPI(
                    api: GatewayHTTPClient(configuration: activation.configuration), activation: activation)
                let session = GatewaySessionController(
                    api: api,
                    storage: KeychainGatewaySessionStorage(configuration: activation.configuration))
                let authorizer = NativeAppleGatewayAuthorizer(anchor: { [weak anchor] in anchor?.window })
                let model = GatewaySignInHost(
                    api: api, session: session,
                    cloudKitAccount: .init(
                        source: NativeCloudKitAccountSource(configuration: activation.cloudKit)),
                    apple: NativeAppleGatewayIdentitySource(), authorizer: authorizer,
                    isEnabled: { activation.isActive() },
                    clearDomainState: {})  // This isolated screen has no domain/profile cache.
                host = model
                if scenePhase == .active { await model.activate() }
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

    @MainActor private final class GatewayPresentationWindow { weak var window: UIWindow? }

    private struct GatewayAppleSignInControl: UIViewRepresentable {
        let anchor: GatewayPresentationWindow
        let enabled: Bool
        let action: @MainActor @Sendable () -> Void
        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
        func makeUIView(context: Context) -> WindowTrackingAppleControl {
            let view = WindowTrackingAppleControl(anchor: anchor)
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
        private let anchor: GatewayPresentationWindow
        init(anchor: GatewayPresentationWindow) {
            self.anchor = anchor
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
        override func didMoveToWindow() {
            super.didMoveToWindow()
            anchor.window = window
        }
    }

    #Preview("Nieaktywna konfiguracja") { GatewayAuthUnavailableView() }
    #Preview("Przycisk Apple") {
        GatewayAppleSignInControl(anchor: GatewayPresentationWindow(), enabled: true, action: {}).frame(
            height: 50
        ).padding()
    }
#endif
