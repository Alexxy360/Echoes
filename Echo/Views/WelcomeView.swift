import EchoesCloudKit
import EchoesCore
import SwiftUI

struct WelcomeView: View {
    let services: AppServices
    @State private var name = ""
    @State private var isEntering = false
    @FocusState private var nameFocused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("ECHOES", systemImage: "waveform").font(.largeTitle.bold().monospaced())
                    .foregroundStyle(Color.meddleTeal)
                Text("Usłysz swoją okolicę").font(.title2.bold())
                Text("Odkrywaj muzykę i rozmawiaj z osobami w promieniu około 3 km.")
                Label(
                    "Pozycja służy do wyszukiwania okolicy. Do serwera trafia podczas korzystania z funkcji lokalnych.",
                    systemImage: "location")
                Label(
                    "Twój profil pozostaje ukryty, dopóki samodzielnie nie włączysz widoczności. Publiczna pozycja jest przybliżona do około 500 m.",
                    systemImage: "eye.slash")
                Label(
                    "Widoczność wygasa po 10 minutach bez odnowienia, a wiadomości po 2 godzinach. Fizyczne usuwanie może nastąpić później.",
                    systemImage: "clock")
                Text(
                    "Szanuj innych: bez gróźb, nękania i spamu. Treści można zgłaszać, a użytkowników blokować. Udostępnianie muzyki jest osobnym wyborem w ustawieniach."
                )
                .font(.subheadline).foregroundStyle(.secondary)
                PrivateProfileStatusView(services: services)
                TextField("Twój pseudonim", text: $name).textContentType(.nickname).textFieldStyle(
                    .roundedBorder
                )
                .accessibilityIdentifier("onboarding.name")
                .focused($nameFocused).autocorrectionDisabled()
                .onSubmit { nameFocused = false }
                Button(action: enter) {
                    if isEntering {
                        ProgressView("Łączenie…").frame(maxWidth: .infinity)
                    } else {
                        Text("Akceptuję zasady i wchodzę").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent).disabled(
                    (try? InputValidation.name(name)) == nil || isEntering || !services.canEnterProfile
                )
                .accessibilityIdentifier("onboarding.enter")
                Text(
                    services.isGatewayDevelopment
                        ? (services.privateProfile != nil
                            ? "Test CloudKit Development i Cloudflare. Konto Echoes jest powiązane z Apple i iCloud. Pseudonim zapisujemy prywatnie w iCloud. Będzie widoczny dla innych po udostępnieniu profilu lub wysłaniu wiadomości."
                            : "Test CloudKit Development i Cloudflare. Pseudonim jest lokalny do zamknięcia mapy.")
                        : "Pseudonim nie jest publiczny, dopóki nie opublikujesz profilu lub wiadomości. Konto działa anonimowo — bez hasła."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(Color.meddleNavy).onAppear { name = services.savedName }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Ukryj klawiaturę") { nameFocused = false }
                    .accessibilityIdentifier("onboarding.keyboard.hide")
            }
        }
        .onChange(of: services.savedName) { _, saved in
            if name.isEmpty, !isEntering { name = saved }
        }
    }
    private func enter() {
        isEntering = true
        Task {
            await services.enter(name: name)
            isEntering = false
        }
    }
}
