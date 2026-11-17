import EchoesCloudKit
import SwiftUI

/// Keeps only a scoped consumer lease. Pixels are resolved through the current host on each render.
struct CommunityAvatarView: View {
    @Environment(\.scenePhase) private var scenePhase
    let avatars: GatewayCommunityAvatarBinding?
    let reference: AvatarReference?
    let surface: GatewayCommunityAvatarSurface
    let name: String
    let size: CGFloat
    var color: Color = .meddleCoral
    @State private var registration: Registration?

    private struct Request: Equatable {
        let binding: ObjectIdentifier?
        let reference: AvatarReference?
        let surface: GatewayCommunityAvatarSurface
        let foreground: Bool
        let available: Bool
    }
    private struct Registration {
        let binding: GatewayCommunityAvatarBinding
        let lease: GatewayCommunityAvatarLease
        let request: Request
    }
    private var request: Request {
        .init(
            binding: avatars.map(ObjectIdentifier.init), reference: reference, surface: surface,
            foreground: scenePhase == .active,
            available: surface == .ownerEditor
                ? avatars?.isOwnerAvailable == true : avatars?.isAvailable == true)
    }
    private var current: Registration? {
        guard let registration, registration.request == request, scenePhase == .active else { return nil }
        return registration
    }
    private var surfaceName: String {
        switch surface {
        case .map: "map"
        case .profile: "profile"
        case .ownerEditor: "ownerEditor"
        case .message: "message"
        }
    }

    var body: some View {
        let value = current
        let image = value.flatMap { $0.binding.image(for: $0.lease) }
        ZStack {
            Circle().fill(color)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Text(String(name.prefix(1)).uppercased()).font(
                    .system(size: min(32, size * 0.45), weight: .semibold)
                )
                .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zdjęcie profilowe")
        .accessibilityValue(image == nil ? "Inicjał" : "Wczytane")
        .accessibilityIdentifier("community.avatar." + surfaceName)
        .overlay(alignment: .bottomTrailing) {
            if surface == .profile || surface == .ownerEditor, let value, image == nil {
                if value.binding.isLoading(value.lease) {
                    ProgressView().padding(10).background(.regularMaterial, in: Circle())
                        .accessibilityIdentifier("community.avatar.loading")
                } else {
                    Button(action: retry) {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered).background(.regularMaterial, in: Circle())
                    .accessibilityLabel("Wczytaj zdjęcie ponownie")
                    .accessibilityIdentifier("community.avatar.retry")
                }
            }
        }
        .task(id: request) { register() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { release() } }
        .onDisappear(perform: release)
    }
    private func register() {
        release()
        guard !Task.isCancelled, scenePhase == .active, let avatars, request.available, let reference
        else { return }
        do {
            let lease = try avatars.acquire(reference: reference, surface: surface)
            registration = .init(binding: avatars, lease: lease, request: request)
        } catch { registration = nil }
    }
    private func release() {
        if let value = registration { value.binding.release(value.lease) }
        registration = nil
    }
    private func retry() {
        guard let value = current else { return }
        value.binding.retry(value.lease)
    }
}

#Preview("Initial fallback") {
    CommunityAvatarView(avatars: nil, reference: nil, surface: .profile, name: "Maja", size: 112)
}
