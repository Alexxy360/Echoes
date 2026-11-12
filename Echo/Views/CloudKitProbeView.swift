#if DEBUG
    import SwiftUI

    struct CloudKitProbeView: View {
        @State private var probe = CloudKitProbe()
        var body: some View {
            NavigationStack {
                Form {
                    Section("CloudKit Development") {
                        Text("Test prywatnej bazy Echoes")
                        Text(
                            "Tworzy losowy rekord testowy, odczytuje go i usuwa. Nie zmienia profilu ani danych istniejących użytkowników."
                        )
                        .font(.caption)
                    }
                    Section {
                        Button("Uruchom test prywatnej bazy", action: run).disabled(probe.running)
                        if probe.running { ProgressView("Sprawdzanie iCloud…") }
                        if let report = probe.report {
                            LabeledContent(
                                "Konto iCloud", value: report.accountAvailable ? "Dostępne" : "Niedostępne")
                            LabeledContent("Zapis", value: report.writeSucceeded ? "OK" : "Niepotwierdzony")
                            LabeledContent(
                                "Odczyt", value: report.readBackSucceeded ? "OK" : "Niepotwierdzony")
                            LabeledContent(
                                "Autor rekordu",
                                value: report.creatorVerified ? "Potwierdzony" : "Niepotwierdzony")
                            LabeledContent(
                                "Sprzątanie", value: report.cleanupSucceeded ? "OK" : "Niepotwierdzone")
                            if let error = report.error { Text(error).foregroundStyle(.red) }
                            if let error = report.cleanupError {
                                Text("Sprzątanie: " + error).foregroundStyle(.red)
                            }
                            if let code = report.cloudKitErrorCode {
                                Text("Kod CloudKit: \(code)").font(.caption)
                            }
                        }
                        if probe.reportFileError {
                            Text("Nie udało się zapisać raportu lokalnego.").foregroundStyle(.red)
                        }
                    }
                }
                .navigationTitle("Test iCloud")
                .task {
                    if ProcessInfo.processInfo.environment["ECHOES_CLOUDKIT_PROBE_AUTORUN"] == "1" {
                        await probe.run()
                    }
                }
            }
        }
        private func run() { Task { await probe.run() } }
    }
#endif
