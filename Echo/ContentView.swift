import EchoesCore
import MapKit
import SwiftUI

extension Color {
    static let meddleNavy = Color(red: 10 / 255, green: 20 / 255, blue: 40 / 255)
    static let meddleTeal = Color(red: 50 / 255, green: 140 / 255, blue: 160 / 255)
    static let meddleCoral = Color(red: 220 / 255, green: 100 / 255, blue: 80 / 255)
}

private enum AppSheet: Identifiable {
    case chat, settings
    case profile(String)
    var id: String {
        switch self {
        case .chat: "chat"
        case .settings: "settings"
        case .profile(let id): "profile-" + id
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let services: AppServices
    var usesNavigationStack = true
    var presentationNotice: String? = nil
    var openNativeAccount: (() -> Void)? = nil
    @State private var camera: MapCameraPosition = .automatic
    @State private var sheet: AppSheet?
    @State private var hasCentered = false
    @State private var requestedNativeAccount = false

    var body: some View {
        Group {
            if usesNavigationStack {
                NavigationStack { mapContent }
            } else {
                mapContent
            }
        }.tint(.meddleCoral).preferredColorScheme(.dark)
    }

    private var mapContent: some View {
        Map(position: $camera) {
            if services.hasAcceptedPrivacy && services.canUseNativeSensors { UserAnnotation() }
            ForEach(services.session.users) { user in
                Annotation(
                    user.name,
                    coordinate: .init(
                        latitude: user.coordinate.latitude, longitude: user.coordinate.longitude)
                ) {
                    Button {
                        sheet = .profile(user.id)
                    } label: {
                        MapProfileMarker(user: user)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(user.name). \(user.lastSong.isEmpty ? "Nie udostępnia muzyki" : user.lastSong)"
                    )
                    .accessibilityHint("Otwiera profil i opcje blokowania")
                }
            }
        }
        .mapStyle(
            .standard(
                elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false)
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let presentationNotice {
                    Text(presentationNotice).font(.caption.bold())
                        .frame(maxWidth: .infinity).padding(6).background(.yellow.opacity(0.2))
                        .accessibilityIdentifier("community.preview.banner")
                }
                if services.isGatewayDevelopment {
                    Text("CloudKit Development — test kontrolowany").font(.caption)
                        .frame(maxWidth: .infinity).padding(6).background(.regularMaterial)
                        .accessibilityIdentifier("community.development.banner")
                }
                MapStatusView(services: services)
            }
        }
        .safeAreaInset(edge: .bottom) {
            MapControls(session: services.session, openChat: { sheet = .chat })
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Label("ECHOES", systemImage: "waveform").labelStyle(.titleAndIcon).font(
                    .headline.monospaced()
                ).foregroundStyle(
                    Color.meddleTeal)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Moja pozycja", systemImage: "location.fill", action: centerMap).labelStyle(
                    .iconOnly
                ).disabled(!services.hasAcceptedPrivacy)
                Button("Ustawienia", systemImage: "gearshape") { sheet = .settings }.labelStyle(.iconOnly)
                    .disabled(!services.hasAcceptedPrivacy)
            }
        }
        .overlay {
            if !services.hasAcceptedPrivacy {
                WelcomeView(services: services)
            } else if services.session.phase == .connecting {
                ProgressView("Łączenie z okolicą…").padding(24).background(
                    .regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            } else if services.session.phase == .failed {
                ContentUnavailableView {
                    Label("Brak połączenia", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Sprawdź połączenie i spróbuj ponownie.")
                } actions: {
                    Button("Spróbuj ponownie") { Task { await services.enter(name: services.savedName) } }
                        .buttonStyle(.borderedProminent)
                }.background(Color.meddleNavy)
            }
        }
        .sheet(
            item: $sheet,
            onDismiss: {
                if requestedNativeAccount {
                    requestedNativeAccount = false
                    openNativeAccount?()
                }
            }
        ) { destination in
            VStack(spacing: 0) {
                Group {
                    switch destination {
                    case .chat: ChatView(session: services.session)
                    case .settings:
                        SettingsView(
                            services: services,
                            openNativeAccount: openNativeAccount == nil
                                ? nil
                                : {
                                    requestedNativeAccount = true
                                })
                    case .profile(let id): UserProfileView(userID: id, session: services.session)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let presentationNotice {
                    Text("Dane syntetyczne").font(.caption).frame(maxWidth: .infinity)
                        .padding(6).background(.yellow.opacity(0.2))
                        .accessibilityLabel(presentationNotice)
                        .accessibilityIdentifier("community.preview.sheetBanner")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Nie udało się wykonać operacji",
            isPresented: Binding(
                get: { services.session.errorMessage != nil && sheet == nil },
                set: { if !$0 { services.session.errorMessage = nil } })
        ) {
            Button("OK") { services.session.errorMessage = nil }
        } message: {
            Text(services.session.errorMessage ?? "")
        }
        .task(id: services.hasAcceptedPrivacy && scenePhase == .active) {
            await runForegroundSession()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await services.deactivate() } }
        }
        .onChange(of: services.session.usableCoordinate) { _, coordinate in
            if coordinate != nil && !hasCentered {
                centerMap()
                hasCentered = true
            }
        }
    }

    private func runForegroundSession() async {
        guard services.hasAcceptedPrivacy, scenePhase == .active else { return }
        await services.activate()
        await services.run()
    }

    private func centerMap() {
        guard services.hasAcceptedPrivacy else { return }
        guard let coordinate = services.session.usableCoordinate else {
            services.requestLocationPermission()
            return
        }
        let position = MapCameraPosition.region(
            .init(
                center: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
                latitudinalMeters: 6_500, longitudinalMeters: 6_500))
        if reduceMotion { camera = position } else { withAnimation { camera = position } }
    }
}

#Preview { ContentView(services: .preview()) }
