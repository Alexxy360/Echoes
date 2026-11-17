import EchoesCloudKit
import SwiftUI

enum AvatarEditorConfirmation: String, Identifiable, Hashable {
    case clear, discard
    var id: String { rawValue }
    var title: String { self == .clear ? "Wycofać zdjęcie i zgodę?" : "Zapomnieć tę próbę na urządzeniu?" }
    var button: String { self == .clear ? "Wycofaj zdjęcie" : "Zapomnij lokalną próbę" }
    var message: String {
        self == .clear
            ? "Wycofanie ukrywa zdjęcie. Nie oznacza natychmiastowego fizycznego skasowania wcześniejszych plików."
            : "Usuniemy lokalny zapis próby, która nie została wysłana lub została zastąpiona. To nie wycofuje aktualnego zdjęcia z serwera."
    }
    var action: GatewayAvatarEditorAction { self == .clear ? .clear : .discardUnsentOrSuperseded }
}

/// The system popover clipped its message at AX XXXL. This screen keeps text scrollable and both
/// actions reachable without reducing the user's chosen text size. It stays in the editor stack.
struct AvatarEditorConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    let session: GatewayAvatarEditorSession
    let confirmation: AvatarEditorConfirmation
    @State private var confirming = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(confirmation.title).font(.headline).accessibilityAddTraits(.isHeader)
                Text(confirmation.message)
                if confirming { ProgressView("Potwierdzanie operacji…") }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button(role: .destructive, action: confirm) {
                    Text(confirmation.button).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(confirming || !session.isCurrent || session.isBusy)
                .accessibilityIdentifier("avatar.editor.confirm")
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Anuluj").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(confirming)
                .accessibilityIdentifier("avatar.editor.confirmCancel")
            }
            .buttonBorderShape(.roundedRectangle).controlSize(.large)
            .frame(maxWidth: .infinity).padding().background(.regularMaterial)
        }
        .navigationTitle("Potwierdzenie").navigationBarTitleDisplayMode(.inline)
    }
    private func confirm() {
        guard !confirming, session.isCurrent, !session.isBusy else { return }
        confirming = true
        Task {
            await session.perform(confirmation.action)
            confirming = false
            if session.isCurrent { dismiss() }
        }
    }
}
