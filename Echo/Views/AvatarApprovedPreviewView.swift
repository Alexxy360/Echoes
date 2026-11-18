import EchoesCloudKit
import SwiftUI

/// Resolve the current opaque handle on every render. No pixels are retained in view state.
struct AvatarApprovedPreviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    let session: GatewayAvatarEditorSession
    let handle: GatewayAvatarOwnerPreviewPresentation
    @State private var visible = false
    private struct Display: Hashable {
        let handle: GatewayAvatarOwnerPreviewPresentation
        let visible: Bool
    }
    var body: some View {
        Group {
            if let image = session.publicationImage(for: handle) {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .frame(maxWidth: 180, maxHeight: 180).clipShape(.rect(cornerRadius: 16))
                    .accessibilityElement(children: .ignore).accessibilityHidden(false)
                    .accessibilityLabel("Podgląd zatwierdzonego zdjęcia")
                    .accessibilityIdentifier("avatar.editor.approvedImage")
                    .onScrollVisibilityChange(threshold: 0.9) { visible = $0 }
            } else if !session.isBusy {
                Text("Podgląd wygasł lub zdjęcie się zmieniło. Wróć i pobierz go ponownie.")
                    .accessibilityIdentifier("avatar.editor.approvedPreviewUnavailable")
            }
        }
        .task(id: Display(handle: handle, visible: visible)) {
            await Task.yield()
            guard visible, !Task.isCancelled, scenePhase == .active,
                session.publicationImage(for: handle) != nil
            else { return }
            try? session.acknowledgePublicationDisplay(handle)
        }
        .onDisappear { visible = false }
    }
}

struct AvatarApprovedPreviewSection: View {
    let session: GatewayAvatarEditorSession
    var body: some View {
        if session.canLoadPublicationPreview || session.publicationPresentation != nil {
            Section("Przed publikacją") {
                if let handle = session.publicationPresentation {
                    AvatarApprovedPreviewView(session: session, handle: handle)
                    Text("Sprawdź zdjęcie. Publikację potwierdzisz osobno.").font(.caption)
                }
                Button("Pobierz podgląd zatwierdzonego zdjęcia") {
                    Task { await session.loadPublicationPreview() }
                }
                .disabled(!session.canLoadPublicationPreview)
                .accessibilityIdentifier("avatar.editor.loadApprovedPreview")
            }
        }
    }
}
