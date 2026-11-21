import EchoesCloudKit
import SwiftUI

@MainActor private final class AvatarReportReviewScreenLifetime { var id: UUID? }
private enum AvatarReportReviewScreenConfirmation {
    case decision(AvatarReportReviewDecisionChoice)
    case retirement(GatewayAvatarReportReviewSavedIntent)
}

/// One feature in the parent's stack. State holds handles and metadata, never reason, pixels or receipt.
struct AvatarReportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let host: GatewayAvatarReportReviewHost
    var isCurrent: @MainActor @Sendable () -> Bool = { true }
    var beforeOpening: @MainActor () -> Void = {}
    var preview = false
    @State private var lifetime = AvatarReportReviewScreenLifetime()
    @State private var attemptedInitialOpen = false
    @State private var selected: GatewayAvatarReportReviewItem?
    @State private var confirmation: AvatarReportReviewScreenConfirmation?
    @State private var error: String?
    @State private var pageNumber = 1

    var body: some View {
        Group {
            if scenePhase != .active {
                Text("Echoes").font(.title.bold())
            } else if let confirmation {
                switch confirmation {
                case .decision(let choice):
                    AvatarReportReviewConfirmationView(
                        host: host, choice: choice, confirm: confirm, cancel: { self.confirmation = nil })
                case .retirement(let intent):
                    AvatarReportReviewRetirementConfirmationView(
                        host: host, intent: intent, confirm: retire, cancel: { self.confirmation = nil })
                }
            } else {
                mainContent
            }
        }
        .navigationTitle(confirmation == nil ? "Zgłoszenia zdjęć" : "Potwierdzenie")
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
                            .accessibilityIdentifier("avatar.report.review.previewNotice")
                    }
                    Section {
                        Text(
                            "Sprawdź zgłoszenie przed podjęciem decyzji."
                        )
                        .font(.subheadline).foregroundStyle(.secondary)
                        if host.isBusy {
                            ProgressView("Sprawdzanie…").accessibilityIdentifier("avatar.report.review.busy")
                        }
                        if let error {
                            Text(error).foregroundStyle(Color.meddleCoral).accessibilityIdentifier(
                                "avatar.report.review.error")
                        }
                    }
                    if host.isConnected {
                        if host.isRoleDenied {
                            Section {
                                Label("Brak dostępu do zgłoszeń", systemImage: "lock")
                                    .accessibilityIdentifier(
                                        "avatar.report.review.denied")
                            }
                        }
                        if let entry = host.pendingOperation {
                            pending(entry)
                        } else {
                            if let presentation = host.presentation {
                                Section("Aktualne zgłoszenie") {
                                    Text(
                                        host.canDecide
                                            ? "Możesz wybrać decyzję."
                                            : host.material(for: presentation)?.image == nil
                                                ? "Przeczytaj powód zgłoszenia do końca."
                                                : "Obejrzyj zdjęcie i przewiń do końca opisu, aby wybrać decyzję."
                                    ).font(.caption).foregroundStyle(.secondary)
                                        .id("avatar.report.review.materialTop")
                                        .accessibilityIdentifier("avatar.report.review.displayStatus")
                                    AvatarReportReviewMaterialView(
                                        host: host, presentation: presentation,
                                        prefix: "avatar.report.review",
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
                                        "avatar.report.review.dismiss")
                                    Button("Ukryj zdjęcie", role: .destructive) {
                                        confirmation = .decision(
                                            .init(
                                                presentation: presentation, verdict: .hidePhoto))
                                    }
                                    .disabled(!host.canHidePhoto).accessibilityIdentifier(
                                        "avatar.report.review.hide")
                                }
                            } else if selected != nil && !host.isBusy {
                                Section {
                                    Text("Materiał wygasł lub nie został odczytany.").accessibilityIdentifier(
                                        "avatar.report.review.expired")
                                    Button("Otwórz zgłoszenie ponownie") {
                                        if let selected {
                                            Task { await run { try await host.inspect(selected) } }
                                        }
                                    }.accessibilityIdentifier("avatar.report.review.reload")
                                }
                            }
                            queue
                        }
                    } else if !host.isBusy {
                        Section {
                            Text("Panel został zamknięty. Otwórz go ponownie, aby sprawdzić aktualne konto.")
                                .accessibilityIdentifier("avatar.report.review.closed")
                            Button("Otwórz panel ponownie") { Task { await open() } }.accessibilityIdentifier(
                                "avatar.report.review.reconnect")
                        }
                    }
                }.accessibilityIdentifier("avatar.report.review.form")
                    .task(id: host.presentation) {
                        let expected = host.presentation
                        await Task.yield()
                        guard !Task.isCancelled, expected != nil, host.presentation == expected else {
                            return
                        }
                        proxy.scrollTo("avatar.report.review.materialTop", anchor: .top)
                    }
                    .task(id: host.pendingOperation?.intent.recovery.decisionID) {
                        let expected = host.pendingOperation?.intent.recovery.decisionID
                        await Task.yield()
                        guard !Task.isCancelled, expected != nil,
                            host.pendingOperation?.intent.recovery.decisionID == expected, host.outcome == nil
                        else { return }
                        proxy.scrollTo("avatar.report.review.pendingTop", anchor: .top)
                    }
                    .task(id: host.outcome) {
                        let expected = host.outcome
                        await Task.yield()
                        guard !Task.isCancelled, expected != nil, host.outcome == expected else { return }
                        proxy.scrollTo("avatar.report.review.outcome", anchor: .top)
                    }
            }
        }
    }
    private var queue: some View {
        Section("Kolejka zgłoszeń") {
            if host.page != nil {
                Text("Strona \(pageNumber)").font(.caption).accessibilityIdentifier(
                    "avatar.report.review.page")
                if host.queue.isEmpty && !host.isBusy && !host.isRoleDenied {
                    Text(
                        host.hasNextPage
                            ? "Ta strona nie zawiera otwartych zgłoszeń." : "Brak zgłoszeń na tej stronie."
                    )
                    .accessibilityIdentifier("avatar.report.review.empty")
                }
            }
            ForEach(Array(host.queue.enumerated()), id: \.element.reportID) { index, item in
                Button("Otwórz zgłoszenie \(index + 1)") {
                    selected = item
                    Task { await run { try await host.inspect(item) } }
                }.disabled(host.isBusy).accessibilityIdentifier("avatar.report.review.item.\(index)")
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
                }.disabled(host.isBusy).accessibilityIdentifier("avatar.report.review.next")
            }
            Button("Odśwież kolejkę") {
                selected = nil
                Task {
                    await run {
                        try await host.refreshQueue()
                        pageNumber = 1
                    }
                }
            }.disabled(host.isBusy).accessibilityIdentifier("avatar.report.review.refresh")
        }
    }
    @ViewBuilder private func pending(_ entry: GatewayAvatarReportReviewJournalEntry) -> some View {
        Section("Zapisana decyzja") {
            Text(
                entry.intent.recovery.verdict == .hidePhoto
                    ? "Wybrano ukrycie zdjęcia." : "Wybrano odrzucenie zgłoszenia."
            )
            .id("avatar.report.review.pendingTop")
            if let outcome = host.outcome {
                Text(outcomeText(outcome, verdict: entry.intent.recovery.verdict)).id(
                    "avatar.report.review.outcome"
                )
                .accessibilityIdentifier(
                    "avatar.report.review.outcome")
            }
            if let resolution = host.resolution {
                Button("Rozumiem") {
                    Task {
                        await run {
                            try await host.acknowledgeResult(resolution)
                            selected = nil
                        }
                    }
                }.disabled(host.isBusy).accessibilityIdentifier("avatar.report.review.acknowledge")
            } else {
                if host.outcome == nil {
                    Text(
                        entry.phase == .retiring
                            ? "Czekamy na potwierdzenie zamknięcia próby."
                            : "Zachowana decyzja czeka na sprawdzenie wyniku."
                    )
                    .accessibilityIdentifier("avatar.report.review.unknown")
                }
                Button("Sprawdź wynik") { Task { await run { try await host.recover() } } }
                    .disabled(host.isBusy).accessibilityIdentifier("avatar.report.review.recover")
                Button(entry.phase == .retiring ? "Ponów zamknięcie próby" : "Zamknij tę próbę") {
                    confirmation = .retirement(entry.intent)
                }.disabled(!host.canRetirePending).accessibilityIdentifier("avatar.report.review.retire")
            }
        }
    }
    private func outcomeText(
        _ outcome: GatewayAvatarReportReviewOutcome, verdict: GatewayAvatarReportReviewVerdict
    )
        -> String
    {
        switch outcome {
        case .confirmed:
            return verdict == .hidePhoto
                ? "Ukrycie zdjęcia zostało zapisane." : "Odrzucenie zgłoszenia zostało zapisane."
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
                error as? GatewayAvatarReportReviewHostFailure != .superseded
            else { return }
            if host.pendingOperation == nil, let failure = error as? GatewayAvatarReportReviewFailure,
                failure == .invalidResponse || failure == .unavailable
            {
                self.error = "Nie udało się odczytać zgłoszeń. Spróbuj ponownie."
            } else {
                self.error = error.localizedDescription
            }
        }
    }
    private func confirm(_ choice: AvatarReportReviewDecisionChoice) {
        confirmation = nil
        Task { await run { try await host.decide(choice.verdict, presentation: choice.presentation) } }
    }
    private func retire(_ intent: GatewayAvatarReportReviewSavedIntent) {
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
