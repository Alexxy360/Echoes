import EchoesCloudKit
import SwiftUI

enum AvatarReportConfirmation {
    case submit(GatewayAvatarReportPresentation, reason: String)
    case cancel
}
struct AvatarReportConfirmationView: View {
    let session: GatewayAvatarReportSession
    let choice: AvatarReportConfirmation
    let confirm: @MainActor () -> Void
    let back: @MainActor () -> Void
    var body: some View {
        GeometryReader { geometry in
            Form {
                switch choice {
                case .submit(let handle, let reason):
                    Section("Zgłosić to zdjęcie?") {
                        AvatarReportPhotoView(
                            host: session.host, presentation: handle, viewport: geometry.frame(in: .global)
                        ).id(handle)
                        Text("Zgłoszenie trafi do obsługi. Nie blokuje konta ani nie ukrywa zdjęcia.")
                    }
                    Section("Twój powód") {
                        Text(reason).privacySensitive().accessibilityIdentifier(
                            "avatar.report.confirmation.reason")
                    }
                    Section {
                        Button("Potwierdź wysłanie zgłoszenia", action: confirm)
                            .disabled(
                                !session.isCurrent || !session.host.canSubmit
                                    || session.host.presentation != handle
                            )
                            .accessibilityIdentifier("avatar.report.confirm")
                    }
                case .cancel:
                    Section("Anulować zapisaną próbę?") {
                        Text(
                            "Zamkniemy tę próbę zgłoszenia. Nie cofnie to działań, które obsługa mogła już podjąć."
                        )
                    }
                    Section {
                        Button("Potwierdź anulowanie próby", role: .destructive, action: confirm)
                            .disabled(!session.isCurrent || !session.host.canCancelPending)
                            .accessibilityIdentifier("avatar.report.confirmCancel")
                    }
                }
                Section { Button("Wróć", action: back).accessibilityIdentifier("avatar.report.back") }
            }.accessibilityIdentifier("avatar.report.confirmationContent")
        }
    }
}
