import EchoesCloudKit
import SwiftUI

/// Resolves current pixels on every render; no image is retained in view state.
struct AvatarReportPhotoView: View {
    @Environment(\.scenePhase) private var scenePhase
    let host: GatewayAvatarReportHost
    let presentation: GatewayAvatarReportPresentation
    let viewport: CGRect
    @State private var frame = CGRect.zero
    private struct Display: Equatable {
        let handle: GatewayAvatarReportPresentation
        let visible: Bool
        let ready: Bool
    }
    private var visible: Bool {
        let intersection = frame.intersection(viewport)
        return frame.width > 0 && frame.height > 0 && !intersection.isNull
            && intersection.width >= frame.width * 0.9 && intersection.height >= frame.height * 0.9
    }
    var body: some View {
        Group {
            if let image = host.image(for: presentation) {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220).clipShape(.rect(cornerRadius: 16))
                    .privacySensitive().accessibilityLabel("Zgłaszane zdjęcie")
                    .accessibilityIdentifier("avatar.report.photo")
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        frame = $0
                    }
            }
        }
        .task(id: Display(handle: presentation, visible: visible, ready: host.isConnected && !host.isBusy)) {
            await Task.yield()
            guard !Task.isCancelled, visible, scenePhase == .active,
                host.image(for: presentation) != nil
            else { return }
            try? host.acknowledgeDisplay(presentation)
        }
        .onDisappear { frame = .zero }
    }
}
