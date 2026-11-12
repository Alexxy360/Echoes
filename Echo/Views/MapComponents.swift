import EchoesCore
import SwiftUI

struct MapProfileMarker: View {
    let user: NearbyProfile
    var body: some View {
        VStack(spacing: 4) {
            if !user.lastSong.isEmpty {
                Text(user.lastSong).font(.caption).lineLimit(1).frame(maxWidth: 140)
                    .padding(6).background(Color.meddleNavy, in: RoundedRectangle(cornerRadius: 8))
            }
            Text(String(user.name.prefix(1)).uppercased()).font(.title3.bold()).frame(
                minWidth: 44, minHeight: 44
            )
            .background(user.lastSong.isEmpty ? Color.gray : .meddleCoral, in: Circle()).foregroundStyle(
                .white)
        }
    }
}

struct MapControls: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let session: CommunitySession
    let openChat: () -> Void
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    OpenChatButton(session: session, action: openChat)
                    SharingToggle(session: session)
                }
            } else {
                HStack(spacing: 16) {
                    OpenChatButton(session: session, action: openChat)
                    SharingToggle(session: session)
                }
            }
        }
        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).padding()
        .accessibilityElement(children: .contain).accessibilityIdentifier("map.controls")
    }
}

private struct OpenChatButton: View {
    let session: CommunitySession
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Czat", systemImage: "bubble.left.and.bubble.right.fill")
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).disabled(session.phase != .ready)
        .accessibilityLabel("Czat w okolicy")
    }
}

private struct SharingToggle: View {
    let session: CommunitySession
    var body: some View {
        Toggle(
            "Profil widoczny",
            isOn: Binding(
                get: { session.isSharing }, set: { value in Task { await session.setSharing(value) } })
        )
        .fixedSize(horizontal: false, vertical: true)
        .disabled(
            session.phase != .ready || session.isChangingVisibility
                || (session.usableCoordinate == nil && !session.isSharing)
        )
        .accessibilityLabel("Widoczność na mapie")
    }
}

struct MapStatusView: View {
    @Environment(\.openURL) private var openURL
    let services: AppServices
    var body: some View {
        VStack(spacing: 6) {
            if services.session.phase == .ready && services.session.usableCoordinate == nil {
                Text(locationExplanation).font(.subheadline)
                if services.location.status == .denied || services.location.status == .inaccurate {
                    Button("Otwórz ustawienia") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } else {
                    Button("Udostępnij lokalizację podczas używania") {
                        services.location.requestPermission()
                    }
                }
            } else if services.session.isLoadingUsers && !services.session.didLoadUsers {
                ProgressView("Szukamy osób w okolicy…")
            } else if services.session.didLoadUsers && services.session.users.isEmpty {
                Text("W pobliżu nie ma teraz widocznych profili.").font(.subheadline)
            }
            if let message = services.session.statusMessage {
                Text(message).font(.caption)
                Button("Zamknij komunikat") { services.session.statusMessage = nil }.font(.caption)
            }
            if services.session.phase == .ready {
                Text(services.session.isSharing ? "Twój profil jest widoczny." : "Twój profil jest ukryty.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity).padding(10).background(.regularMaterial)
    }

    private var locationExplanation: String {
        switch services.location.status {
        case .denied: "Dostęp do lokalizacji jest wyłączony."
        case .inaccurate:
            "Pozycja jest zbyt przybliżona. Włącz Dokładną lokalizację w ustawieniach iOS."
        default: "Potrzebujemy aktualnej pozycji, aby pokazać Twoją okolicę."
        }
    }
}
