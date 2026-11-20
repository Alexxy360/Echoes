import EchoesCloudKit
import SwiftUI

@MainActor private final class ReportReviewScreenLifetime { var id: UUID? }
private enum ReportReviewScreenConfirmation {
    case decision(ReportReviewDecisionChoice)
    case retirement(GatewayReportReviewRecoveryIntent)
}

/// One feature in the parent's stack. State holds handles and metadata, never report/message text.
struct ReportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let host: GatewayReportReviewHost
    var isCurrent: @MainActor @Sendable () -> Bool = { true }
    var beforeOpening: @MainActor () -> Void = {}
    var preview = false
    @State private var lifetime = ReportReviewScreenLifetime()
    @State private var attemptedInitialOpen = false
    @State private var selected: GatewayReportReviewItem?
    @State private var confirmation: ReportReviewScreenConfirmation?
    @State private var error: String?
    @State private var pageNumber = 1

    var body: some View {
        Group {
            if scenePhase != .active {
                Text("Echoes").font(.title.bold())
            } else if let confirmation {
                switch confirmation {
                case .decision(let choice):
                    ReportReviewConfirmationView(
                        host: host, choice: choice, confirm: confirm, cancel: { self.confirmation = nil })
                case .retirement(let intent):
                    ReportReviewRetirementConfirmationView(
                        host: host, intent: intent, confirm: retire, cancel: { self.confirmation = nil })
                }
            } else {
                mainContent
            }
        }
        .navigationTitle(confirmation == nil ? "Zgłoszenia" : "Potwierdzenie")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(confirmation != nil)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Gotowe", action: close) }
        }
        .task { await open(initial: true) }
        .onChange(of: host.presentation) { _, value in
            if case .decision(let choice) = confirmation, choice.presentation != value {
                self.confirmation = nil
            }
        }
        .onChange(of: host.pendingOperation?.intent) { _, value in
            if case .retirement(let intent) = confirmation, intent != value { self.confirmation = nil }
        }
        .onChange(of: host.isConnected) { _, connected in
            if !connected {
                selected = nil
                confirmation = nil
                pageNumber = 1
                host.invalidate()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            selected = nil
            confirmation = nil
            error = nil
            if phase != .active {
                lifetime.id = nil
                host.setForeground(false)
            } else if !attemptedInitialOpen {
                Task { await open(initial: true) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification))
        { _ in
            confirmation = nil
            host.expirePresentation()
        }
        .onDisappear {
            lifetime.id = nil
            confirmation = nil
            host.setForeground(false)
        }
    }
    private var mainContent: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                Form {
                    if preview {
                        Section { Text("Podgląd testowy • dane syntetyczne").font(.caption) }
                            .accessibilityIdentifier("report.review.previewNotice")
                    }
                    Section {
                        Text(
                            "Odrzucenie zgłoszenia pozostawia wiadomość. Ukrycie wiadomości odbiera jej widoczność w aplikacji."
                        )
                        .font(.subheadline).foregroundStyle(.secondary)
                        if host.isBusy {
                            ProgressView("Sprawdzanie…").accessibilityIdentifier("report.review.busy")
                        }
                        if let error {
                            Text(error).foregroundStyle(Color.meddleCoral).accessibilityIdentifier(
                                "report.review.error")
                        }
                    }
                    if host.isConnected {
                        if host.isRoleDenied {
                            Section {
                                Label("Brak dostępu do zgłoszeń", systemImage: "lock")
                                    .accessibilityIdentifier(
                                        "report.review.denied")
                            }
                        }
                        if let entry = host.pendingOperation {
                            pending(entry)
                        } else {
                            if let presentation = host.presentation {
                                Section("Aktualne zgłoszenie") {
                                    Text(
                                        host.canDecide
                                            ? "Treść zgłoszenia została wyświetlona."
                                            : "Przewiń do końca treści, aby wybrać decyzję."
                                    ).font(.caption).foregroundStyle(.secondary)
                                        .id("report.review.materialTop")
                                        .accessibilityIdentifier("report.review.displayStatus")
                                    ReportReviewMaterialView(
                                        host: host, presentation: presentation, prefix: "report.review",
                                        viewport: geometry.frame(in: .global),
                                        reachedEnd: {
                                            try? host.acknowledgeDisplay(presentation)
                                        }
                                    ).id(presentation)
                                }
                                Section("Decyzja") {
                                    Button("Odrzuć zgłoszenie") {
                                        confirmation = .decision(
                                            .init(presentation: presentation, verdict: .dismiss))
                                    }
                                    .disabled(!host.canDecide).accessibilityIdentifier(
                                        "report.review.dismiss")
                                    Button("Ukryj wiadomość", role: .destructive) {
                                        confirmation = .decision(
                                            .init(
                                                presentation: presentation, verdict: .hideMessage))
                                    }
                                    .disabled(!host.canHideMessage).accessibilityIdentifier(
                                        "report.review.hide")
                                }
                            } else if selected != nil && !host.isBusy {
                                Section {
                                    Text("Materiał wygasł lub nie został odczytany.").accessibilityIdentifier(
                                        "report.review.expired")
                                    Button("Otwórz zgłoszenie ponownie") {
                                        if let selected {
                                            Task { await run { try await host.inspect(selected) } }
                                        }
                                    }.accessibilityIdentifier("report.review.reload")
                                }
                            }
                            queue
                        }
                    } else if !host.isBusy {
                        Section {
                            Text("Panel został zamknięty. Otwórz go ponownie, aby sprawdzić aktualne konto.")
                                .accessibilityIdentifier("report.review.closed")
                            Button("Otwórz panel ponownie") { Task { await open() } }.accessibilityIdentifier(
                                "report.review.reconnect")
                        }
                    }
                }.accessibilityIdentifier("report.review.form")
                    .task(id: host.presentation) {
                        let expected = host.presentation
                        await Task.yield()
                        guard !Task.isCancelled, expected != nil, host.presentation == expected else {
                            return
                        }
                        proxy.scrollTo("report.review.materialTop", anchor: .top)
                    }
                    .task(id: host.pendingOperation?.intent.decisionID) {
                        let expected = host.pendingOperation?.intent.decisionID
                        await Task.yield()
                        guard !Task.isCancelled, expected != nil,
                            host.pendingOperation?.intent.decisionID == expected, host.outcome == nil
                        else { return }
                        proxy.scrollTo("report.review.pendingTop", anchor: .top)
                    }
                    .task(id: host.outcome) {
                        let expected = host.outcome
                        await Task.yield()
                        guard !Task.isCancelled, expected != nil, host.outcome == expected else { return }
                        proxy.scrollTo("report.review.outcome", anchor: .top)
                    }
            }
        }
    }
    private var queue: some View {
        Section("Kolejka zgłoszeń") {
            if host.page != nil {
                Text("Strona \(pageNumber)").font(.caption).accessibilityIdentifier("report.review.page")
                if host.queue.isEmpty && !host.isBusy && !host.isRoleDenied {
                    Text(
                        host.hasNextPage
                            ? "Ta strona nie zawiera otwartych zgłoszeń." : "Brak zgłoszeń na tej stronie."
                    )
                    .accessibilityIdentifier("report.review.empty")
                }
            }
            ForEach(Array(host.queue.enumerated()), id: \.element.reportID) { index, item in
                Button("Otwórz zgłoszenie \(index + 1)") {
                    selected = item
                    Task { await run { try await host.inspect(item) } }
                }.disabled(host.isBusy).accessibilityIdentifier("report.review.item.\(index)")
            }
            if host.hasNextPage, let page = host.page {
                Button("Następna strona") {
                    selected = nil
                    Task {
                        await run {
                            try await host.nextPage(page)
                            pageNumber += 1
                        }
                    }
                }.disabled(host.isBusy).accessibilityIdentifier("report.review.next")
            }
            Button("Odśwież kolejkę") {
                selected = nil
                Task {
                    await run {
                        try await host.refreshQueue()
                        pageNumber = 1
                    }
                }
            }.disabled(host.isBusy).accessibilityIdentifier("report.review.refresh")
        }
    }
    @ViewBuilder private func pending(_ entry: GatewayReportReviewJournalEntry) -> some View {
        Section("Zapisana decyzja") {
            Text(
                entry.intent.verdict == .hideMessage
                    ? "Wybrano ukrycie wiadomości." : "Wybrano odrzucenie zgłoszenia."
            )
            .id("report.review.pendingTop")
            if let outcome = host.outcome {
                Text(outcomeText(outcome, verdict: entry.intent.verdict)).id("report.review.outcome")
                    .accessibilityIdentifier(
                        "report.review.outcome")
            }
            if let resolution = host.resolution {
                Button("Rozumiem") {
                    Task {
                        await run {
                            try await host.acknowledgeResult(resolution)
                            selected = nil
                        }
                    }
                }.disabled(host.isBusy).accessibilityIdentifier("report.review.acknowledge")
            } else {
                if host.outcome == nil {
                    Text(
                        entry.phase == .retiring
                            ? "Czekamy na potwierdzenie zamknięcia próby."
                            : "Zachowana decyzja czeka na sprawdzenie wyniku."
                    )
                    .accessibilityIdentifier("report.review.unknown")
                }
                Button("Sprawdź wynik") { Task { await run { try await host.recover() } } }
                    .disabled(host.isBusy).accessibilityIdentifier("report.review.recover")
                Button(entry.phase == .retiring ? "Ponów zamknięcie próby" : "Zamknij tę próbę") {
                    confirmation = .retirement(entry.intent)
                }.disabled(!host.canRetirePending).accessibilityIdentifier("report.review.retire")
            }
        }
    }
    private func outcomeText(_ outcome: GatewayReportReviewOutcome, verdict: GatewayReportReviewVerdict)
        -> String
    {
        switch outcome {
        case .confirmed:
            return verdict == .hideMessage
                ? "Ukrycie wiadomości zostało zapisane." : "Odrzucenie zgłoszenia zostało zapisane."
        case .notApplied:
            return "Decyzja nie jest potwierdzona. Może jeszcze zostać zapisana."
        case .superseded: return "Stan zgłoszenia się zmienił. Nie możemy potwierdzić poprzedniej decyzji."
        case .retired: return "Ta próba została zamknięta. Nie cofa to wcześniej zapisanych zmian."
        }
    }
    private func open(initial: Bool = false) async {
        guard scenePhase == .active, isCurrent(), !initial || !attemptedInitialOpen else { return }
        attemptedInitialOpen = true
        selected = nil
        confirmation = nil
        pageNumber = 1
        beforeOpening()
        let id = UUID()
        lifetime.id = id
        let currentScreen = isCurrent
        host.setForeground(true)
        await run {
            try await host.connect { [weak lifetime] in lifetime?.id == id && currentScreen() }
            if host.pendingOperation == nil { try await host.refreshQueue() }
        }
    }
    private func run(_ action: @MainActor () async throws -> Void) async {
        guard let id = lifetime.id, scenePhase == .active, isCurrent() else { return }
        error = nil
        do { try await action() } catch {
            guard lifetime.id == id, scenePhase == .active, isCurrent(), !Task.isCancelled,
                !(error is CancellationError), error as? GatewayFailure != .cancelled,
                error as? GatewayReportReviewHostFailure != .superseded
            else { return }
            self.error = error.localizedDescription
        }
    }
    private func confirm(_ choice: ReportReviewDecisionChoice) {
        confirmation = nil
        Task { await run { try await host.decide(choice.verdict, presentation: choice.presentation) } }
    }
    private func retire(_ intent: GatewayReportReviewRecoveryIntent) {
        confirmation = nil
        Task { await run { try await host.retirePending(intent) } }
    }
    private func close() {
        lifetime.id = nil
        confirmation = nil
        host.setForeground(false)
        dismiss()
    }
}
