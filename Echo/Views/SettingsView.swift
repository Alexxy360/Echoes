import EchoesCore
import MediaPlayer
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let services: AppServices
    @State private var name = ""
    @State private var musicBusy = false
    @State private var confirmDeletion = false
    @State private var deleting = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Twój profil") {
                    TextField("Pseudonim", text: $name).textContentType(.nickname)
                    Button("Zapisz pseudonim") { services.saveName(name) }.disabled(
                        (try? InputValidation.name(name)) == nil)
                    Text("Nazwa nie jest unikalna. Widoczność włączasz osobno na mapie.").font(.caption)
                }
                Section("Muzyka") {
                    Toggle(
                        "Udostępniaj utwór z aplikacji Muzyka",
                        isOn: Binding(get: { services.music.isEnabled }, set: changeMusic)
                    ).disabled(musicBusy)
                    if services.music.authorization == .denied || services.music.authorization == .restricted
                    {
                        Text(
                            "Dostęp do biblioteki muzycznej jest wyłączony. Możesz zmienić go w ustawieniach iOS."
                        ).font(.caption)
                    }
                    Text("Działa z aplikacją Muzyka. Spotify i inne odtwarzacze nie są obecnie obsługiwane.")
                        .font(.caption)
                }
                Section("Prywatność i dane") {
                    Text(
                        "Dane okolicy odświeżają się podczas korzystania z aplikacji. Po przejściu w tło zatrzymujemy publikowanie i próbujemy ukryć profil; bez połączenia ostatni profil wygaśnie do 10 minut."
                    )
                    Text(
                        "GPS jest używany do wyszukiwania okolicy. Zapisywane pozycje profili i wiadomości są przybliżone. Wiadomości wygasają po 2 godzinach, a zgłoszenia są przechowywane do 30 dni. Fizyczne kasowanie działa asynchronicznie."
                    )
                    Text(
                        "Dane są przetwarzane w Firebase/Google Cloud. Aplikacja nie korzysta z analityki ani reklam."
                    )
                    Button("Usuń moje dane i konto", role: .destructive) { confirmDeletion = true }.disabled(
                        deleting)
                }
                if !services.session.blockedIDs.isEmpty {
                    Section("Zablokowani użytkownicy") {
                        ForEach(Array(services.session.blockedIDs).sorted(), id: \.self) { id in
                            HStack {
                                Text("Użytkownik \(id.prefix(6))…").font(.caption)
                                Spacer()
                                Button("Odblokuj") {
                                    Task { await services.session.block(userID: id, blocked: false) }
                                }
                            }
                        }
                    }
                }
                Section("Pomoc i zasady") {
                    Text(
                        "Bez gróźb, nękania i spamu. Zgłoś wiadomość przez jej menu. Zgłoszenia trafiają do obsługi usługi."
                    )
                    if let url = services.session.supportURL { Link("Kontakt z obsługą", destination: url) }
                }
            }
            .safeAreaInset(edge: .top) { SessionFeedback(session: services.session) }
            .navigationTitle("Ustawienia")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Gotowe") { dismiss() } } }
            .onAppear { name = services.session.name }
            .confirmationDialog(
                "Usunąć Twoje konto, profil i wiadomości?", isPresented: $confirmDeletion,
                titleVisibility: .visible
            ) {
                Button("Usuń moje dane", role: .destructive, action: deleteData)
            } message: {
                Text(
                    "Ta operacja jest nieodwracalna. Pseudonim i szkic na urządzeniu także zostaną usunięte.")
            }
        }
    }
    private func changeMusic(_ enabled: Bool) {
        if !enabled {
            services.music.disable()
            return
        }
        musicBusy = true
        Task {
            await services.music.enable()
            musicBusy = false
        }
    }
    private func deleteData() {
        deleting = true
        Task {
            await services.deleteOwnData()
            deleting = false
            if !services.hasAcceptedPrivacy { dismiss() }
        }
    }
}
