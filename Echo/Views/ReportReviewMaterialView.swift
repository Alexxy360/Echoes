import EchoesCloudKit
import SwiftUI

/// Read from the current handle on each render; the end marker acknowledges scroll presentation.
struct ReportReviewMaterialView: View {
    @Environment(\.scenePhase) private var scenePhase
    let host: GatewayReportReviewHost
    let presentation: GatewayReportReviewPresentation
    let prefix: String
    let viewport: CGRect
    let reachedEnd: @MainActor () -> Void
    @State private var endVisible = false
    private struct Proof: Equatable {
        let presentation: GatewayReportReviewPresentation
        let visible: Bool
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let material = host.material(for: presentation) {
                Text("Powód zgłoszenia").font(.headline).accessibilityAddTraits(.isHeader)
                Text(material.reason).fixedSize(horizontal: false, vertical: true).privacySensitive()
                    .accessibilityIdentifier(prefix + ".reason")
                Divider()
                if let message = material.message {
                    Text("Wiadomość").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(message.name).font(.subheadline).foregroundStyle(.secondary).privacySensitive()
                    Text(message.text).fixedSize(horizontal: false, vertical: true).privacySensitive()
                        .accessibilityIdentifier(prefix + ".message")
                } else {
                    Text("Wiadomość nie jest już dostępna. Możesz odrzucić zgłoszenie.")
                        .accessibilityIdentifier(prefix + ".missingMessage")
                }
                Text("Koniec zgłoszenia").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier(prefix + ".end")
                    .onGeometryChange(for: Bool.self) { geometry in
                        let frame = geometry.frame(in: .global)
                        guard frame.width > 0, frame.height > 0, !viewport.isEmpty else { return false }
                        let visible = frame.intersection(viewport)
                        return !visible.isNull && visible.width >= frame.width * 0.9
                            && visible.height >= frame.height * 0.9
                    } action: {
                        endVisible = $0
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: Proof(presentation: presentation, visible: endVisible)) {
            await Task.yield()
            guard endVisible, !Task.isCancelled, scenePhase == .active,
                host.material(for: presentation) != nil
            else { return }
            reachedEnd()
        }
        .onChange(of: presentation) { _, _ in endVisible = false }
        .onDisappear { endVisible = false }
    }
}
