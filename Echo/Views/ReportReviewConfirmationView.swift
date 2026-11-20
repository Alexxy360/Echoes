import EchoesCloudKit
import SwiftUI

struct ReportReviewDecisionChoice {
    let presentation: GatewayReportReviewPresentation
    let verdict: GatewayReportReviewVerdict
    var title: String { verdict == .hideMessage ? "Ukryć wiadomość?" : "Odrzucić zgłoszenie?" }
    var button: String {
        verdict == .hideMessage ? "Potwierdź ukrycie wiadomości" : "Potwierdź odrzucenie zgłoszenia"
    }
    var message: String {
        verdict == .hideMessage
            ? "Wiadomość przestanie być dostępna w aplikacji. Ta decyzja nie blokuje konta autora."
            : "Zgłoszenie zostanie zamknięte. Wiadomość pozostanie dostępna zgodnie z zasadami aplikacji."
    }
}

/// Inline confirmation preserves lifetime; accessibility text keeps actions in the scroll content.
struct ReportReviewConfirmationView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let host: GatewayReportReviewHost
    let choice: ReportReviewDecisionChoice
    let confirm: @MainActor (ReportReviewDecisionChoice) -> Void
    let cancel: @MainActor () -> Void
    @State private var reachedEnd = false
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(choice.title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(choice.message)
                    if host.material(for: choice.presentation) != nil {
                        ReportReviewMaterialView(
                            host: host, presentation: choice.presentation,
                            prefix: "report.review.confirmation",
                            viewport: geometry.frame(in: .global), reachedEnd: { reachedEnd = true }
                        ).id(choice.presentation)
                    } else {
                        Text("Zgłoszenie wygasło lub ekran został zamknięty.")
                    }
                    if dynamicTypeSize.isAccessibilitySize { actions }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .accessibilityIdentifier("report.review.confirmationContent")
        }
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize { actions.padding().background(.regularMaterial) }
        }
    }
    private var actions: some View {
        VStack(spacing: 12) {
            Button(role: choice.verdict == .hideMessage ? .destructive : nil) {
                guard canConfirm else { return }
                confirm(choice)
            } label: {
                Text(choice.button).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).disabled(!canConfirm)
            .accessibilityIdentifier("report.review.confirm")
            Button(role: .cancel, action: cancel) { Text("Anuluj").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).accessibilityIdentifier("report.review.confirmCancel")
        }.controlSize(.large).buttonBorderShape(.roundedRectangle).frame(maxWidth: .infinity)
    }
    private var canConfirm: Bool {
        reachedEnd && host.presentation == choice.presentation && host.canDecide
            && (choice.verdict == .dismiss || host.canHideMessage)
    }
}

/// Metadata only; the captured attempt is checked again by the host before any IO.
struct ReportReviewRetirementConfirmationView: View {
    let host: GatewayReportReviewHost
    let intent: GatewayReportReviewRecoveryIntent
    let confirm: @MainActor (GatewayReportReviewRecoveryIntent) -> Void
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
                    .accessibilityIdentifier("report.review.retireConfirm")
                Button("Wróć", role: .cancel, action: cancel)
                    .accessibilityIdentifier("report.review.retireCancel")
            }
        }.accessibilityIdentifier("report.review.retireConfirmation")
    }
}
