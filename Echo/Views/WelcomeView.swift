import EchoesCore
import SwiftUI

struct WelcomeView: View {
    let services: AppServices
    @State private var name = ""
    @State private var isEntering = false
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
                TextField("Twój pseudonim", text: $name).textContentType(.nickname).textFieldStyle(
                    .roundedBorder
                )
                .accessibilityIdentifier("onboarding.name")
                Button(action: enter) {
                    if isEntering {
                        ProgressView("Łączenie…").frame(maxWidth: .infinity)
                    } else {
                        Text("Akceptuję zasady i wchodzę").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent).disabled(
                    (try? InputValidation.name(name)) == nil || isEntering
                )
                .accessibilityIdentifier("onboarding.enter")
                Text(
                    "Pseudonim nie jest publiczny, dopóki nie opublikujesz profilu lub wiadomości. Konto działa anonimowo — bez hasła."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(Color.meddleNavy).onAppear { name = services.savedName }
    }
    private func enter() {
        isEntering = true
        Task {
            await services.enter(name: name)
            isEntering = false
        }
    }
}
