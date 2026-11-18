import EchoesCloudKit
import SwiftUI

enum AvatarEditorConfirmation: Identifiable, Hashable {
    case clear, discard
    case publish(GatewayAvatarOwnerPreviewPresentation)
    var id: Self { self }
    var title: String {
        switch self {
        case .clear: "Wycofać zdjęcie i zgodę?"
        case .discard: "Zapomnieć tę próbę na urządzeniu?"
        case .publish: "Opublikować to zdjęcie?"
        }
    }
    var button: String {
        switch self {
        case .clear: "Wycofaj zdjęcie"
        case .discard: "Zapomnij lokalną próbę"
        case .publish: "Potwierdź publikację zdjęcia"
        }
    }
    var message: String {
        switch self {
        case .clear:
            "Wycofanie ukrywa zdjęcie. Nie oznacza natychmiastowego fizycznego skasowania wcześniejszych plików."
        case .discard:
            "Usuniemy lokalny zapis próby, która nie została wysłana lub została zastąpiona. To nie wycofuje aktualnego zdjęcia z serwera."
        case .publish:
            "Opublikujemy wyświetlone zdjęcie. Będzie widoczne zgodnie z zasadami dostępu aplikacji."
        }
    }
    var isPublication: Bool { if case .publish = self { true } else { false } }
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
                if case .publish(let handle) = confirmation {
                    AvatarApprovedPreviewView(session: session, handle: handle)
                }
                if confirming { ProgressView("Potwierdzanie operacji…") }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .accessibilityIdentifier("avatar.editor.confirmationContent")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button(role: confirmation.isPublication ? nil : .destructive, action: confirm) {
                    Text(confirmation.button).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(confirmation.isPublication ? Color.accentColor : .red)
                .disabled(confirming || !session.isCurrent || session.isBusy || !canConfirm)
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
    private var canConfirm: Bool {
        if case .publish(let handle) = confirmation { return session.canConfirmPublication(handle) }
        return true
    }
    private func confirm() {
        guard !confirming, session.isCurrent, !session.isBusy, canConfirm else { return }
        confirming = true
        Task {
            switch confirmation {
            case .clear: await session.perform(.clear)
            case .discard: await session.perform(.discardUnsentOrSuperseded)
            case .publish(let handle): await session.confirmPublication(handle)
            }
            confirming = false
            if session.isCurrent { dismiss() }
        }
    }
}
