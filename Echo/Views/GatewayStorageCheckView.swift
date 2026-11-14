#if DEBUG
    import SwiftUI

    struct GatewayStorageCheckView: View {
        @State private var report: String?
        var body: some View {
            NavigationStack {
                Form {
                    Section("Lokalna kontrola sesji") {
                        Text(
                            "Sprawdza zapis, zastąpienie i odczyt syntetycznych danych w Keychain oraz ich usunięcie."
                        )
                        Text("Bez połączenia z serwerem i bez danych konta.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Wynik") {
                        if let report {
                            Label(
                                report == "passed" ? "Kontrola zaliczona" : "Kontrola nieudana",
                                systemImage: report == "passed"
                                    ? "checkmark.circle" : "exclamationmark.circle")
                            Text(report).accessibilityIdentifier("gateway.storage.result")
                        } else {
                            ProgressView("Sprawdzanie…")
                        }
                    }
                }
                .navigationTitle("Keychain — Debug")
                .task { if report == nil { report = GatewayStorageCheck.run() } }
            }
        }
    }
#endif
