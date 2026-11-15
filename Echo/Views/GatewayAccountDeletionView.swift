#if DEBUG
    import EchoesCloudKit
    import SwiftUI

    /// A feature view over one native host; no service construction or auth policy inside body.
    struct GatewayAccountDeletionView: View {
        let host: GatewayDeletionHost
        var isPreview = false
        @Environment(\.scenePhase) private var scenePhase
        var body: some View {
            Form {
                if isPreview {
                    Section {
                        Text("Podgląd UI — dane syntetyczne").font(.caption.bold())
                            .accessibilityIdentifier("gateway.deletion.previewBanner")
                    }.listRowBackground(Color.yellow.opacity(0.2))
                }
                Section {
                    Text(
                        "Usuwanie dotyczy konta Echoes. Prywatne dane dokończysz na urządzeniu z właściwym kontem iCloud."
                    )
                    .font(.callout)

                }
                .disabled(host.isBusy)
                if host.isBusy {
                    Section {
                        ProgressView(
                            host.phase == .authorizing ? "Potwierdzanie tożsamości…" : "Sprawdzanie etapu…")
                    }
                }
                if let error = host.errorMessage {
                    Section("Nie udało się zakończyć etapu") {
                        Text(error).accessibilityIdentifier("gateway.deletion.error")
                        Button("Sprawdź ponownie") { Task { await host.activate() } }
                            .disabled(host.isBusy)
                    }
                }
                if host.requests.isEmpty, !host.isBusy, host.errorMessage == nil {
                    Section { Text("Brak zapisanych żądań na tym urządzeniu.").foregroundStyle(.secondary) }
                }
                ForEach(Array(host.requests.enumerated()), id: \.element.journalID) { index, request in
                    Section("Zapisane usuwanie \(index + 1)") {
                        GatewayDeletionProgressView(progress: request)
                        if request.canRetryInitialRequest {
                            Button("Potwierdź żądanie przez Apple", role: .destructive) {
                                host.ask(.retryInitial(journalID: request.journalID))
                            }.accessibilityIdentifier("gateway.deletion.retryInitial")
                        }
                        if request.needsFreshProof {
                            Button("Odzyskaj bilet przez Apple") {
                                host.ask(.recover(journalID: request.journalID))
                            }
                            .accessibilityIdentifier("gateway.deletion.recoverSaved")
                        } else {
                            Button("Sprawdź status") {
                                Task { await host.poll(journalID: request.journalID) }
                            }
                            .accessibilityIdentifier("gateway.deletion.poll")
                            if !request.completed, request.status != nil {
                                Button("Kontynuuj usuwanie", role: .destructive) {
                                    Task { await host.continueDeletion(journalID: request.journalID) }
                                }.accessibilityIdentifier("gateway.deletion.continue")
                                Button("Rozpocznij ponowny skan prywatnych danych") {
                                    Task { await host.restartPrivateScan(journalID: request.journalID) }
                                }.font(.footnote).accessibilityIdentifier("gateway.deletion.restartScan")
                            }
                        }
                    }.disabled(host.isBusy)
                }
                Section("Żądanie") {
                    Button("Rozpocznij usuwanie konta", role: .destructive) { host.ask(.deleteAccount) }
                        .accessibilityIdentifier("gateway.deletion.new")
                    Button("Odzyskaj wcześniejsze usuwanie") { host.ask(.recover(journalID: nil)) }
                        .accessibilityIdentifier("gateway.deletion.recover")
                }.disabled(host.isBusy)
            }
            .navigationTitle(isPreview ? "Podgląd usuwania" : "Usuwanie konta")
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                host.confirmation?.title ?? "",
                isPresented: Binding(
                    get: { host.confirmation != nil }, set: { if !$0 { host.cancelConfirmation() } }),
                presenting: host.confirmation
            ) { pending in
                Button("Anuluj", role: .cancel) { host.cancelConfirmation() }
                    .accessibilityIdentifier("gateway.deletion.cancel")
                Button("Potwierdź przez Apple", role: confirmationRole(pending.action)) {
                    host.confirmFromUserAction(pending)
                }
                .accessibilityIdentifier("gateway.deletion.confirm")
            } message: { pending in
                Text(pending.message)
            }
            .task { if scenePhase == .active { await host.activate() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await host.activate() }
                } else if phase == .background {
                    host.suspend()
                }
            }
            .onDisappear { host.stop() }
        }
        private func confirmationRole(_ action: GatewayDeletionHost.Action) -> ButtonRole? {
            if case .recover = action { return nil }
            return .destructive
        }
    }

    private struct GatewayDeletionProgressView: View {
        let progress: GatewayDeletionProgress
        var body: some View {
            Label(
                progress.completed
                    ? "Usuwanie zakończone na tym urządzeniu" : "Usuwanie nie jest jeszcze zakończone",
                systemImage: progress.completed ? "checkmark.circle" : "clock"
            )
            .accessibilityIdentifier(
                progress.completed ? "gateway.deletion.completed" : "gateway.deletion.pending")
            if progress.needsFreshProof {
                Text("Nie potwierdzono odzyskania biletu. Potrzebne jest nowe potwierdzenie Apple.")
                    .accessibilityIdentifier("gateway.deletion.needsProof")
            }
            if let status = progress.status {
                LabeledContent("Dane społecznościowe", value: publicStatus(status.publicData))
                LabeledContent(
                    "Prywatna zawartość", value: progress.privateContentDeleted ? "Wyczyszczona" : "Oczekuje")
                LabeledContent(
                    "Dane tego urządzenia", value: progress.localDataDeleted ? "Wyczyszczone" : "Oczekują")
                if status.privateData == .deviceAcknowledged, !progress.localDataDeleted {
                    Text(
                        "Inne urządzenie potwierdziło czyszczenie. Ten telefon nadal wymaga własnego sprawdzenia."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if status.appleAuthorization == .manualRequired {
                    Text(
                        "Nie potwierdzono pełnego odwołania dostępu Apple. Możesz odłączyć Echoes w ustawieniach konta Apple."
                    )
                    .font(.footnote).accessibilityIdentifier("gateway.deletion.appleManual")
                }
                if status.attentionRequired {
                    Text("Zadanie wymaga pomocy obsługi. Usuwanie nie jest zakończone.")
                        .accessibilityIdentifier("gateway.deletion.attention")
                }
            } else {
                Text(
                    "Serwer nie potwierdził jeszcze przyjęcia żądania. Zachowano bilet do sprawdzenia lub ponownego potwierdzenia."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        private func publicStatus(_ value: GatewayDeletionStatus.PublicData) -> String {
            switch value {
            case .pending: "Oczekują"
            case .draining: "Końcowe sprawdzanie"
            case .deleted: "Usunięte"
            }
        }
    }
#endif
