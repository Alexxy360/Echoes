import EchoesCloudKit
import SwiftUI

struct AvatarReportReviewDecisionChoice {
    let presentation: GatewayAvatarReportReviewPresentation
    let verdict: GatewayAvatarReportReviewVerdict
    var title: String { verdict == .hidePhoto ? "Ukryć zdjęcie?" : "Odrzucić zgłoszenie?" }
    var button: String {
        verdict == .hidePhoto ? "Potwierdź ukrycie zdjęcia" : "Potwierdź odrzucenie zgłoszenia"
    }
    var message: String {
        verdict == .hidePhoto
            ? "Zgłoszone zdjęcie przestanie być widoczne w aplikacji."
            : "Zgłoszenie zostanie zamknięte. Zdjęcie pozostanie dostępne zgodnie z zasadami aplikacji."
    }
}

/// Inline confirmation preserves lifetime; accessibility text keeps actions in the scroll content.
struct AvatarReportReviewConfirmationView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let host: GatewayAvatarReportReviewHost
    let choice: AvatarReportReviewDecisionChoice
    let confirm: @MainActor (AvatarReportReviewDecisionChoice) -> Void
    let cancel: @MainActor () -> Void
    @State private var reachedEnd = false
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(choice.title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(choice.message)
                    if host.material(for: choice.presentation) != nil {
                        AvatarReportReviewMaterialView(
                            host: host, presentation: choice.presentation,
                            prefix: "avatar.report.review.confirmation",
                            viewport: geometry.frame(in: .global), reachedEnd: { reachedEnd = true }
                        ).id(choice.presentation)
                    } else {
                        Text("Zgłoszenie wygasło lub ekran został zamknięty.")
                    }
                    if dynamicTypeSize.isAccessibilitySize { actions }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .accessibilityIdentifier("avatar.report.review.confirmationContent")
        }
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize { actions.padding().background(.regularMaterial) }
        }
    }
    private var actions: some View {
        VStack(spacing: 12) {
            Button(role: choice.verdict == .hidePhoto ? .destructive : nil) {
                guard canConfirm else { return }
                confirm(choice)
            } label: {
                Text(choice.button).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).disabled(!canConfirm)
            .accessibilityIdentifier("avatar.report.review.confirm")
            Button(role: .cancel, action: cancel) { Text("Anuluj").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).accessibilityIdentifier("avatar.report.review.confirmCancel")
        }.controlSize(.large).buttonBorderShape(.roundedRectangle).frame(maxWidth: .infinity)
    }
    private var canConfirm: Bool {
        reachedEnd && host.presentation == choice.presentation && host.canDecide
            && (choice.verdict == .dismiss || host.canHidePhoto)
    }
}

/// Metadata only; the captured attempt is checked again by the host before any IO.
struct AvatarReportReviewRetirementConfirmationView: View {
    let host: GatewayAvatarReportReviewHost
    let intent: GatewayAvatarReportReviewSavedIntent
    let confirm: @MainActor (GatewayAvatarReportReviewSavedIntent) -> Void
    let cancel: @MainActor () -> Void
    var body: some View {
        Form {
            Section("Zamknąć tę próbę?") {
                Text(
                    "Serwer zablokuje późniejsze wykonanie tej próby decyzji. Jeśli decyzja została już zapisana, pokażemy jej wynik."
                )
                Text(
                    "Zamknięcie próby nie cofa wcześniej zapisanych zmian. Po potwierdzeniu wyniku będzie można ponownie otworzyć zgłoszenie, jeśli pozostaje dostępne."
                )
            }
            Section {
                Button("Potwierdź zamknięcie próby") {
                    guard host.canRetirePending, host.pendingOperation?.intent == intent else { return }
                    confirm(intent)
                }.disabled(!host.canRetirePending || host.pendingOperation?.intent != intent)
                    .accessibilityIdentifier("avatar.report.review.retireConfirm")
                Button("Wróć", role: .cancel, action: cancel)
                    .accessibilityIdentifier("avatar.report.review.retireCancel")
            }
        }.accessibilityIdentifier("avatar.report.review.retireConfirmation")
    }
}
