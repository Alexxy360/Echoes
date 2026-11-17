#if DEBUG
    import EchoesCloudKit
    import SwiftUI

    /// Explicit UI fixture using the native adapter/domain/host, with synthetic API and identity.
    struct GatewayCommunityPreviewView: View {
        let mode: String
        @Environment(\.scenePhase) private var scenePhase
        @State private var fixture: CommunityPreviewFixture?
        @State private var failed = false
        @State private var path: [Destination] = []
        private enum Destination: Hashable { case account }
        var body: some View {
            NavigationStack(path: $path) {
                Group {
                    if let fixture, let presentation = fixture.host.presentation,
                        fixture.host.isCurrent(presentation.id), let services = fixture.services
                    {
                        ContentView(
                            services: services, usesNavigationStack: false,
                            presentationNotice: "Podgląd UI • dane syntetyczne • bez logowania i backendu",
                            openNativeAccount: {
                                guard fixture.host.isCurrent(presentation.id) else { return }
                                path = [.account]
                                Task { await fixture.close(presentation.id) }
                            }
                        ).id(presentation.id)
                    } else if let fixture {
                        ContentUnavailableView {
                            Label("Sesja testowa zamknięta", systemImage: "lock")
                        } actions: {
                            Button("Otwórz nową sesję testową") { Task { await fixture.open() } }
                        }.accessibilityIdentifier("community.preview.closed")
                    } else if failed {
                        ContentUnavailableView("Podgląd niedostępny", systemImage: "exclamationmark.triangle")
                    } else {
                        ProgressView("Przygotowanie podglądu…")
                    }
                }
                .navigationDestination(for: Destination.self) { _ in
                    if let fixture { GatewayAccountDeletionView(host: fixture.deletion, isPreview: true) }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu("Test", systemImage: "testtube.2") {
                            Button("Zmień konto testowe") { Task { await fixture?.changeAccount() } }
                            Button("Zamknij sesję testową") { fixture?.invalidate() }
                            Button("Zakończ opóźniony odczyt") { fixture?.releaseProfileRead() }
                            if fixture?.hasAvatars == true {
                                Button("Ukryj zdjęcie testowe") { Task { await fixture?.clearAvatar() } }
                                Button("Przywróć zdjęcie testowe") { Task { await fixture?.restoreAvatar() } }
                                Button("Zwolnij odczyty zdjęć") {
                                    Task { await fixture?.releaseAvatarRead() }
                                }
                                Button("Popraw plik testowy") { Task { await fixture?.repairAvatar() } }
                            }
                        }.accessibilityIdentifier("community.preview.actions")
                    }
                }
            }
            .task {
                guard fixture == nil, !failed else { return }
                do {
                    let current = try CommunityPreviewFixture(mode: mode)
                    fixture = current
                    await current.open()
                } catch { failed = true }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    fixture?.invalidate()
                    path = []
                }
            }
        }
    }

#endif
