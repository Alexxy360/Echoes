#if DEBUG
    import SwiftUI

    struct CloudKitIdentityCheckView: View {
        @State private var check = CloudKitIdentityCheck()
        var body: some View {
            NavigationStack {
                Form {
                    Section("CloudKit Development") {
                        Text("Kontrola konta testowego")
                        Text(
                            "Porównuje konto iCloud z tożsamością serwera. Nie odczytuje profilu ani rekordów aplikacji, nie zapisuje danych w CloudKit."
                        )
                        .font(.caption)
                    }
                    Section {
                        Button("Sprawdź konto", action: run).disabled(check.running)
                        if check.running { ProgressView("Sprawdzanie iCloud…") }
                        if let report = check.report {
                            LabeledContent(
                                "Konto iCloud", value: report.accountAvailable ? "Dostępne" : "Niedostępne")
                            if let matches = report.accountMatchesServiceIdentity {
                                LabeledContent(
                                    "Porównanie", value: matches ? "Konto operatora" : "Inne konto")
                            }
                            if let error = report.error { Text(error).foregroundStyle(.red) }
                        }
                        if check.reportFileError {
                            Text("Nie udało się zapisać raportu lokalnego.").foregroundStyle(.red)
                        }
                    }
                }
                .navigationTitle("Konto testowe")
                .task {
                    if ProcessInfo.processInfo.environment["ECHOES_CLOUDKIT_IDENTITY_AUTORUN"] == "1" {
                        await check.run()
                    }
                }
            }
        }
        private func run() { Task { await check.run() } }
    }
#endif
