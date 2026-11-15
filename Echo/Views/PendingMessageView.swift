import EchoesCore
import SwiftUI

/// Recovery is explicit. Forgetting a local attempt never retracts a server message.
struct PendingMessageView: View {
    let session: CommunitySession
    let pending: PendingCommunityMessage
    @State private var confirmation: PendingCommunityMessage?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Niepotwierdzona wiadomość", systemImage: "exclamationmark.bubble")
                .font(.headline)
            Text(
                "Ta wiadomość mogła już dotrzeć. Ponowienie sprawdzi tę samą próbę, zachowując Twój nowy szkic."
            )
            .font(.caption)
            Text(pending.text).textSelection(.enabled).accessibilityIdentifier("chat.pending.text")
            Button("Ponów tę samą wiadomość") {
                Task {
                    guard session.pendingMessage == pending else { return }
                    session.errorMessage = nil
                    _ = await session.retryPendingMessage()
                }
            }.disabled(session.isSending).accessibilityIdentifier("chat.pending.retry")
            Button("Usuń lokalną próbę", role: .destructive) { confirmation = pending }
                .disabled(session.isSending).accessibilityIdentifier("chat.pending.forget")
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain).accessibilityIdentifier("chat.pending")
        .alert(
            "Usunąć tylko lokalną próbę?",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            presenting: confirmation
        ) { expected in
            Button("Usuń lokalną próbę", role: .destructive) {
                do { try session.forgetPendingMessage(expected) } catch {
                    session.errorMessage = error.localizedDescription
                }
                confirmation = nil
            }.accessibilityIdentifier("chat.pending.confirm")
            Button("Anuluj", role: .cancel) { confirmation = nil }
                .accessibilityIdentifier("chat.pending.cancel")
        } message: { _ in
            Text(
                "To nie usuwa wiadomości z serwera. Mogła już dotrzeć do innych osób. Nowy szkic pozostanie na urządzeniu."
            )
        }
    }
}
