#if DEBUG
    import SwiftUI

    struct PrivateProfileSDKProbeView: View {
        @State private var probe = PrivateProfileSDKProbe()
        var body: some View {
            NavigationStack {
                Form {
                    Section("Diagnostyka SDK Development") {
                        Text(
                            "Wyłącznie dwie nowe losowe strefy z danymi testowymi. Nie jest to test logowania gateway ani dwóch kont iCloud."
                        )
                    }
                    if probe.configurationFailed {
                        ContentUnavailableView(
                            "Test nieaktywny", systemImage: "lock",
                            description: Text(
                                "Brak ważnej konfiguracji diagnostycznej. SDK nie zostało uruchomione.")
                        )
                        .accessibilityIdentifier("profile.sdk.unconfigured")
                    } else {
                        Button("Uruchom jedną próbę SDK") { Task { await probe.run() } }
                            .disabled(!probe.canRun).accessibilityIdentifier("profile.sdk.run")
                        if probe.running { ProgressView("Sprawdzanie prywatnego SDK…") }
                    }
                    if let report = probe.report {
                        Section("Wynik") {
                            LabeledContent(
                                "Odtworzenie", value: report.createdAndRestored ? "OK" : "Niepotwierdzone")
                            LabeledContent(
                                "Konflikt serwera",
                                value: report.staleWriteRejectedByServer ? "OK" : "Niepotwierdzony")
                            LabeledContent(
                                "Guard usuwania",
                                value: report.deletionGuardEnforced ? "OK" : "Niepotwierdzony")
                            LabeledContent(
                                "Sprzątanie", value: report.cleanupVerified ? "OK" : "Niepotwierdzone")
                            if let error = report.error { Text(error).foregroundStyle(.red) }
                            if let error = report.cleanupError { Text(error).foregroundStyle(.red) }
                            Text("Run: " + report.runID).font(.caption)
                        }
                    }
                    if probe.reportWriteFailed {
                        Text("Nie udało się zapisać raportu.").foregroundStyle(.red)
                    }
                }.navigationTitle("Test prywatnego SDK")
            }
            .task {
                if ProcessInfo.processInfo.environment["ECHOES_PRIVATE_PROFILE_SDK_AUTORUN"] == "1" {
                    await probe.run()
                }
            }
        }
    }
#endif
