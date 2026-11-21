import EchoesCloudKit
import SwiftUI

/// Only handles and visibility metadata live in State. The current reason/image is resolved per render.
struct AvatarReportReviewMaterialView: View {
    @Environment(\.scenePhase) private var scenePhase
    let host: GatewayAvatarReportReviewHost
    let presentation: GatewayAvatarReportReviewPresentation
    let prefix: String
    let viewport: CGRect
    let reachedEnd: @MainActor () -> Void
    @State private var imageWasVisible = false
    @State private var endVisible = false
    private struct Proof: Equatable {
        let presentation: GatewayAvatarReportReviewPresentation
        let imageSeen: Bool, endVisible: Bool, requiresImage: Bool
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let material = host.material(for: presentation) {
                if let image = material.image {
                    Text("Zgłoszone zdjęcie").font(.headline).accessibilityAddTraits(.isHeader)
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .frame(maxWidth: 288, maxHeight: max(1, min(260, viewport.height * 0.55)))
                        .privacySensitive()
                        .accessibilityLabel("Zgłoszone zdjęcie profilowe")
                        .accessibilityIdentifier(prefix + ".image")
                        .accessibilityHidden(false)
                        .onGeometryChange(for: Bool.self) { geometry in
                            visible(geometry.frame(in: .global))
                        } action: {
                            if $0 { imageWasVisible = true }
                        }
                } else {
                    Text("Zdjęcie nie jest już dostępne. Możesz odrzucić zgłoszenie.")
                        .accessibilityIdentifier(prefix + ".missingPhoto")
                }
                Divider()
                Text("Powód zgłoszenia").font(.headline).accessibilityAddTraits(.isHeader)
                Text(material.reason).fixedSize(horizontal: false, vertical: true).privacySensitive()
                    .accessibilityIdentifier(prefix + ".reason")
                Text("Koniec zgłoszenia").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier(prefix + ".end")
                    .onGeometryChange(for: Bool.self) { geometry in
                        visible(geometry.frame(in: .global))
                    } action: {
                        endVisible = $0
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(
            id: Proof(
                presentation: presentation, imageSeen: imageWasVisible,
                endVisible: endVisible, requiresImage: host.material(for: presentation)?.image != nil)
        ) {
            await Task.yield()
            guard endVisible, !Task.isCancelled, scenePhase == .active,
                host.presentation == presentation, let material = host.material(for: presentation),
                material.image == nil || imageWasVisible
            else { return }
            reachedEnd()
        }
        .onChange(of: presentation) { _, _ in reset() }
        .onChange(of: scenePhase) { _, value in if value != .active { reset() } }
        .onDisappear { reset() }
    }
    private func visible(_ frame: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0, !viewport.isEmpty else { return false }
        let shown = frame.intersection(viewport)
        return !shown.isNull && shown.width >= frame.width * 0.9 && shown.height >= frame.height * 0.9
    }
    private func reset() {
        imageWasVisible = false
        endVisible = false
    }
}
