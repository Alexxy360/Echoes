import EchoesCloudKit
import SwiftUI

/// Feature-local view inside its parent's NavigationStack. No pixels or credentials in State.
struct AvatarReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let host: GatewayAvatarReviewHost
    var isCurrent: @MainActor @Sendable () -> Bool = { true }
    var preview = false
    @State private var appearance: UUID?
    @State private var attemptedInitialOpen = false
    @State private var selected: GatewayAvatarReviewItem?
    @State private var confirmation: DecisionConfirmation?
    @State private var error: String?

    var body: some View {
        Form {
            if preview {
                Section { Text("Podgląd testowy • dane syntetyczne").font(.caption) }
                    .accessibilityIdentifier("avatar.review.previewNotice")
            }
            Section {
                Text("Zatwierdzenie pozwala autorowi osobno opublikować zdjęcie.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if host.isBusy { ProgressView("Sprawdzanie…").accessibilityIdentifier("avatar.review.busy") }
                if let error {
                    Text(error).foregroundStyle(Color.meddleCoral).accessibilityIdentifier(
                        "avatar.review.error")
                }
            }
            if host.isConnected {
                if host.isRoleDenied {
                    Section {
                        Label("Brak dostępu do oceny zdjęć", systemImage: "lock")
                            .accessibilityIdentifier("avatar.review.denied")
                    }
                }
                if let entry = host.pendingOperation {
                    pending(entry)
                } else {
                    if let presentation = host.presentation {
                        AvatarReviewImageSection(host: host, presentation: presentation)
                        Section("Decyzja") {
                            Button("Zatwierdź zdjęcie") {
                                confirmation = .init(presentation: presentation, verdict: .approved)
                            }
                            .disabled(!host.canDecide).accessibilityIdentifier("avatar.review.approve")
                            Button("Odrzuć zdjęcie", role: .destructive) {
                                confirmation = .init(presentation: presentation, verdict: .rejected)
                            }
                            .disabled(!host.canDecide).accessibilityIdentifier("avatar.review.reject")
                        }
                    } else if selected != nil && !host.isBusy {
                        Section {
                            Text("Podgląd wygasł lub został zamknięty.").accessibilityIdentifier(
                                "avatar.review.expired")
                            Button("Otwórz podgląd ponownie") {
                                if let selected { Task { await run { try await host.inspect(selected) } } }
                            }.accessibilityIdentifier("avatar.review.reloadImage")
                        }
                    }
                    Section("Zdjęcia do oceny") {
                        if host.queue.isEmpty && !host.isBusy && !host.isRoleDenied {
                            Text("Brak zdjęć do oceny.").accessibilityIdentifier("avatar.review.empty")
                        }
                        ForEach(Array(host.queue.enumerated()), id: \.element.accountID) { index, item in
                            Button {
                                selected = item
                                Task { await run { try await host.inspect(item) } }
                            } label: {
                                Label("Otwórz zdjęcie \(index + 1)", systemImage: "photo")
                            }
                            .disabled(host.isBusy).accessibilityIdentifier("avatar.review.item.\(index)")
                        }
                        Button("Odśwież kolejkę") {
                            selected = nil
                            Task { await run { try await host.refreshQueue() } }
                        }.disabled(host.isBusy).accessibilityIdentifier("avatar.review.refresh")
                    }
                }
            } else if !host.isBusy {
                Section {
                    Text("Panel został zamknięty. Otwórz go ponownie, aby sprawdzić aktualne konto.")
                        .accessibilityIdentifier("avatar.review.closed")
                    Button("Otwórz panel ponownie") { Task { await open() } }
                        .accessibilityIdentifier("avatar.review.reconnect")
                }
            }
        }
        .navigationTitle("Ocena zdjęć")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Gotowe", action: close) } }
        .alert(
            confirmation?.title ?? "Decyzja",
            isPresented: Binding(
                get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            presenting: confirmation
        ) { decision in
            Button(decision.button, role: decision.verdict == .rejected ? .destructive : nil) {
                confirmation = nil
                Task {
                    await run { try await host.decide(decision.verdict, presentation: decision.presentation) }
                }
            }.accessibilityIdentifier("avatar.review.confirmDecision")
            Button("Anuluj", role: .cancel) { confirmation = nil }
        } message: { decision in
            Text(
                decision.verdict == .approved
                    ? "Czy aktualnie widoczne zdjęcie nadaje się do publikacji? Autor zdecyduje osobno o jego pokazaniu."
                    : "To zdjęcie nie będzie dostępne do publikacji. Autor będzie mógł wybrać inne.")
        }
        .task {
            appearance = UUID()
            await open(initial: true)
        }
        .onChange(of: host.presentation) { _, current in
            if let confirmation, confirmation.presentation != current { self.confirmation = nil }
        }
        .onChange(of: host.isConnected) { _, connected in
            if !connected {
                selected = nil
                confirmation = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            confirmation = nil
            selected = nil
            error = nil
            host.setForeground(phase == .active)
            if phase == .active { Task { await open(initial: true) } }
        }
        .onDisappear {
            appearance = nil
            confirmation = nil
            host.setForeground(false)
        }
        .accessibilityIdentifier("avatar.review")
    }
    @ViewBuilder private func pending(_ entry: GatewayAvatarReviewJournalEntry) -> some View {
        Section("Zapisana decyzja") {
            if let outcome = host.outcome {
                Text(outcomeText(outcome, verdict: entry.intent.verdict)).accessibilityIdentifier(
                    "avatar.review.outcome")
                if let resolution = host.resolution {
                    Button("Rozumiem") {
                        Task {
                            await run {
                                try await host.acknowledgeResult(resolution)
                                selected = nil
                            }
                        }
                    }
                    .disabled(host.isBusy).accessibilityIdentifier("avatar.review.acknowledge")
                }
            } else {
                Text("Zachowana decyzja czeka na sprawdzenie wyniku.").accessibilityIdentifier(
                    "avatar.review.unknown")
                Button("Sprawdź wynik") { Task { await run { try await host.recover() } } }
                    .disabled(host.isBusy).accessibilityIdentifier("avatar.review.recover")
            }
        }
    }
    private func outcomeText(_ outcome: GatewayAvatarReviewOutcome, verdict: GatewayAvatarReviewVerdict)
        -> String
    {
        switch outcome {
        case .confirmed:
            return verdict == .approved
                ? "Zatwierdzenie zdjęcia zostało zapisane." : "Odrzucenie zdjęcia zostało zapisane."
        case .notApplied:
            return
                "Decyzja nie została zastosowana w bieżącym stanie zdjęcia. Kolejna ocena wymaga świeżego podglądu."
        case .superseded: return "Stan zdjęcia się zmienił. Nie możemy potwierdzić poprzedniej decyzji."
        }
    }
    private func open(initial: Bool = false) async {
        guard scenePhase == .active, appearance != nil else { return }
        guard !initial || !attemptedInitialOpen else { return }
        attemptedInitialOpen = true
        selected = nil
        confirmation = nil
        host.setForeground(true)
        await run {
            try await host.connect { isCurrent() }
            if host.pendingOperation == nil { try await host.refreshQueue() }
        }
    }
    private func run(_ action: @MainActor () async throws -> Void) async {
        guard let current = appearance, scenePhase == .active, isCurrent() else { return }
        error = nil
        do { try await action() } catch {
            guard appearance == current, scenePhase == .active, isCurrent(), !Task.isCancelled,
                !(error is CancellationError), error as? GatewayFailure != .cancelled,
                error as? GatewayAvatarReviewHostFailure != .superseded
            else { return }
            self.error = error.localizedDescription
        }
    }
    private func close() {
        appearance = nil
        host.setForeground(false)
        dismiss()
    }
    private struct DecisionConfirmation {
        let presentation: GatewayAvatarReviewPresentation
        let verdict: GatewayAvatarReviewVerdict
        var title: String { verdict == .approved ? "Zatwierdzić zdjęcie?" : "Odrzucić zdjęcie?" }
        var button: String { verdict == .approved ? "Potwierdź zatwierdzenie" : "Potwierdź odrzucenie" }
    }
}

private struct AvatarReviewImageSection: View {
    let host: GatewayAvatarReviewHost
    let presentation: GatewayAvatarReviewPresentation
    var body: some View {
        Section("Aktualny podgląd") {
            if let image = host.image(for: presentation) {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .frame(maxWidth: .infinity).frame(height: 220)
                    .privacySensitive()
                    .accessibilityLabel("Aktualny podgląd zdjęcia do oceny")
                    .accessibilityIdentifier("avatar.review.image")
                    .accessibilityHidden(false)
                    .task(id: presentation) {
                        await Task.yield()
                        guard !Task.isCancelled, host.image(for: presentation) != nil else { return }
                        try? host.acknowledgeDisplay(presentation)
                    }
                Text("Podgląd ma ograniczony czas ważności. Jeśli wygaśnie, otwórz go ponownie.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
