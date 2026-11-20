import EchoesCloudKit
import SwiftUI

struct AvatarReportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let session: GatewayAvatarReportSession
    var preview = false
    @State private var reason = ""
    @State private var confirmation: AvatarReportConfirmation?
    @State private var error: String?
    @State private var attemptedOpening = false
    @State private var running: UUID?
    @State private var operation: Task<Void, Never>?
    @FocusState private var reasonFocused: Bool
    private var host: GatewayAvatarReportHost { session.host }
    private var normalizedReason: String? { try? GatewayAvatarReportSubmission.normalizeReason(reason) }
    var body: some View {
        NavigationStack {
            Group {
                if scenePhase != .active {
                    Text("Echoes").font(.title.bold())
                } else if !session.isCurrent {
                    closed
                } else if let confirmation {
                    AvatarReportConfirmationView(
                        session: session, choice: confirmation,
                        confirm: confirm, back: { self.confirmation = nil })
                } else {
                    content
                }
            }
            .navigationTitle(confirmation == nil ? "Zgłoś zdjęcie" : "Potwierdzenie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Zamknij", action: close) } }
        }
        .task { await open(initial: true) }
        .onChange(of: host.presentation) { _, value in
            if case .submit(let expected, _) = confirmation, expected != value { confirmation = nil }
        }
        .onChange(of: host.isConnected) { _, value in if !value { confirmation = nil } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { retire() } else if !attemptedOpening { Task { await open(initial: true) } }
        }
        .onDisappear { retire() }
    }
    private var closed: some View {
        ContentUnavailableView {
            Label("Ekran zgłoszenia jest zamknięty", systemImage: "lock")
        } actions: {
            Button("Wróć", action: close)
        }
    }
    private var content: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                Form {
                    if preview { Section { Text("Podgląd testowy • dane syntetyczne").font(.caption) } }
                    if host.isBusy || running != nil {
                        Section { ProgressView("Sprawdzanie…").accessibilityIdentifier("avatar.report.busy") }
                    }
                    if let error {
                        Section {
                            Text(error).foregroundStyle(Color.meddleCoral).accessibilityIdentifier(
                                "avatar.report.error")
                        }
                    }
                    if host.isConnected {
                        if let pending = host.pendingOperation {
                            pendingContent(pending)
                        } else if session.hasPhoto {
                            Section("Zdjęcie do zgłoszenia") {
                                if let handle = host.presentation {
                                    Text(
                                        host.canSubmit
                                            ? "Zdjęcie zostało wyświetlone."
                                            : "Wyświetl całe aktualne zdjęcie, aby kontynuować."
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                    .id("avatar.report.materialTop").accessibilityIdentifier(
                                        "avatar.report.displayStatus")
                                    AvatarReportPhotoView(
                                        host: host, presentation: handle,
                                        viewport: geometry.frame(in: .global)
                                    ).id(handle)
                                } else if !host.isBusy {
                                    Text(
                                        "Podgląd wygasł lub zdjęcie się zmieniło. Wyświetl aktualne zdjęcie przed wysłaniem."
                                    )
                                    .accessibilityIdentifier("avatar.report.expired")
                                    Button("Wyświetl aktualne zdjęcie") {
                                        run { try await session.refreshPhoto() }
                                    }
                                    .disabled(running != nil).accessibilityIdentifier("avatar.report.refresh")
                                }
                            }
                            Section("Powód zgłoszenia") {
                                TextField("Opisz krótko, co jest nie tak", text: $reason, axis: .vertical)
                                    .lineLimit(3...8).focused($reasonFocused).privacySensitive()
                                    .disabled(host.isBusy || running != nil).accessibilityIdentifier(
                                        "avatar.report.reason")
                                if !reason.isEmpty, normalizedReason == nil {
                                    Text("Opis jest pusty, za długi lub zawiera niedozwolone znaki.").font(
                                        .caption
                                    ).foregroundStyle(.secondary)
                                }
                                Text("Powód wysyłamy do obsługi. Nie pokażemy go osobie zgłaszanej.").font(
                                    .caption
                                ).foregroundStyle(.secondary)
                            }
                            Section {
                                Button("Dalej") {
                                    guard let handle = host.presentation, let reason = normalizedReason,
                                        host.canSubmit
                                    else { return }
                                    reasonFocused = false
                                    confirmation = .submit(handle, reason: reason)
                                }.disabled(!host.canSubmit || normalizedReason == nil || running != nil)
                                    .accessibilityIdentifier("avatar.report.next")
                            }
                        } else {
                            Section {
                                Text(
                                    "Nie masz zapisanej próby zgłoszenia. Nowe zgłoszenie rozpoczniesz przy zdjęciu w profilu."
                                )
                                .accessibilityIdentifier("avatar.report.empty")
                            }
                        }
                    } else if !host.isBusy {
                        Section {
                            Text("Otwórz ponownie, aby sprawdzić zapisany wynik dla aktualnego konta.")
                            Button("Sprawdź zapisaną próbę") { run { try await session.open() } }
                                .disabled(running != nil).accessibilityIdentifier("avatar.report.reconnect")
                        }
                    }
                }.accessibilityIdentifier("avatar.report.form")
                    .task(id: host.presentation) {
                        let expected = host.presentation
                        await Task.yield()
                        guard !Task.isCancelled, expected != nil, host.presentation == expected else {
                            return
                        }
                        proxy.scrollTo("avatar.report.materialTop", anchor: .top)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if reasonFocused {
                            KeyboardDismissControl(identifier: "avatar.report.keyboard.hide") {
                                reasonFocused = false
                            }
                        }
                    }
            }
        }
    }
    @ViewBuilder private func pendingContent(_ entry: GatewayAvatarReportJournalEntry) -> some View {
        Section("Zapisana próba") {
            if entry.phase == .resolved {
                Text(
                    entry.outcome == .cancelled
                        ? "Próba została anulowana." : "Zgłoszenie zostało zapisane i trafiło do obsługi."
                )
                .accessibilityIdentifier("avatar.report.resolved")
                if let resolution = host.resolution {
                    Button("Potwierdź wynik") { run { try await session.acknowledgeResult(resolution) } }
                        .disabled(running != nil).accessibilityIdentifier("avatar.report.ack")
                }
            } else {
                Text(
                    entry.phase == .cancelling
                        ? "Anulowanie nie zostało jeszcze potwierdzone. Sprawdź wynik lub ponów anulowanie tej samej próby."
                        : "Wynik tej próby nie jest potwierdzony. Sprawdzenie nie wysyła zgłoszenia ponownie."
                )
                .accessibilityIdentifier("avatar.report.pending")
                if entry.phase == .cancelling, host.outcome == .accepted {
                    Text("Pierwotne zgłoszenie jest zapisane. Anulowanie wciąż wymaga potwierdzenia.")
                }
                Button("Sprawdź wynik") { run { try await session.recover() } }
                    .disabled(host.isBusy || running != nil).accessibilityIdentifier("avatar.report.recover")
                Button(
                    entry.phase == .cancelling ? "Ponów anulowanie" : "Anuluj zapisaną próbę",
                    role: .destructive
                ) {
                    confirmation = .cancel
                }.disabled(!host.canCancelPending || running != nil).accessibilityIdentifier(
                    "avatar.report.cancel")
            }
        }
    }
    private func confirm() {
        guard let choice = confirmation else { return }
        confirmation = nil
        reasonFocused = false
        switch choice {
        case .submit(let handle, let confirmedReason):
            reason = ""
            run { try await session.submit(reason: confirmedReason, presentation: handle) }
        case .cancel: run { try await session.cancelPending() }
        }
    }
    private func open(initial: Bool) async {
        guard scenePhase == .active, session.isCurrent, !initial || !attemptedOpening else { return }
        attemptedOpening = true
        do { try await session.open() } catch {
            if session.isCurrent, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard session.isCurrent, scenePhase == .active, running == nil else { return }
        let id = UUID()
        running = id
        error = nil
        operation = Task {
            defer {
                if running == id {
                    running = nil
                    operation = nil
                }
            }
            do { try await action() } catch {
                if session.isCurrent, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    private func retire() {
        reason = ""
        confirmation = nil
        error = nil
        operation?.cancel()
        session.close()
    }
    private func close() {
        retire()
        dismiss()
    }
}
