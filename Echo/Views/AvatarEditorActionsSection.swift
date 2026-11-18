import EchoesCloudKit
import SwiftUI

struct AvatarEditorActionsSection: View {
    let session: GatewayAvatarEditorSession
    let requestConfirmation: (AvatarEditorConfirmation) -> Void
    var body: some View {
        Section("Operacje zdjęcia") {
            Button("Odśwież stan", action: refresh).disabled(!session.canRefresh)
                .accessibilityIdentifier("avatar.editor.refresh")
            if session.pendingOperation != nil {
                Button("Sprawdź wynik zapisanej próby", action: recover).disabled(!session.canRecover)
                    .accessibilityIdentifier("avatar.editor.recover")
                if session.canRetryUpload {
                    Button("Ponów wysyłanie tej samej kopii", action: retry)
                        .accessibilityIdentifier("avatar.editor.retry")
                }
            }
            if session.canPublish, let handle = session.publicationPresentation {
                Button("Opublikuj zatwierdzone zdjęcie") { requestConfirmation(.publish(handle)) }
                    .accessibilityIdentifier("avatar.editor.publish")
            }
            Button("Wycofaj zdjęcie", role: .destructive) { requestConfirmation(.clear) }
                .disabled(!session.canClear).accessibilityIdentifier("avatar.editor.clear")
            if session.canDiscardPending {
                Button("Zapomnij lokalną próbę", role: .destructive) { requestConfirmation(.discard) }
                    .accessibilityIdentifier("avatar.editor.discard")
            }
        }
    }
    private func refresh() { Task { await session.perform(.refresh) } }
    private func recover() { Task { await session.perform(.recover) } }
    private func retry() { Task { await session.perform(.retryUpload) } }
}
