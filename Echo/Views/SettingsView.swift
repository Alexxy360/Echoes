import EchoesCloudKit
import EchoesCore
import MediaPlayer
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let services: AppServices
    var openNativeAccount: (() -> Void)? = nil
    @State private var name = ""
    @State private var musicBusy = false
    @State private var confirmDeletion = false
    @State private var deleting = false
    @FocusState private var nameFocused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section("Twój profil") {
                    TextField("Pseudonim", text: $name).textContentType(.nickname)
                        .focused($nameFocused).autocorrectionDisabled()
                        .onSubmit { nameFocused = false }
                        .disabled(services.isUpdatingName || (services.privateProfile?.isBusy ?? false))
                        .accessibilityIdentifier("settings.name")
                    Button("Zapisz pseudonim") {
                        let draft = name
                        Task { _ = await services.saveName(draft) }
                    }.disabled(
                        (try? InputValidation.name(name)) == nil || !services.canEnterProfile
                    )
                    .accessibilityIdentifier("settings.saveName")
                    if services.privateProfile != nil {
                        Text(
                            "Pseudonim zapisujemy prywatnie w iCloud. Inni widzą go w udostępnionym profilu i wysłanych wiadomościach."
                        ).font(.caption)
                        PrivateProfileStatusView(services: services, alwaysShowRefresh: true)
                    } else if services.isGatewayDevelopment {
                        Text("W tym teście pseudonim jest lokalny do zamknięcia mapy.").font(.caption)
                    }
                    Text("Nazwa nie jest unikalna. Widoczność włączasz osobno na mapie.").font(.caption)
                    Text("Używany pseudonim: " + services.session.name).font(.caption)
                        .accessibilityIdentifier("settings.currentName")
                }
                Section("Muzyka") {
                    Toggle(
                        "Udostępniaj utwór z aplikacji Muzyka",
                        isOn: Binding(get: { services.music.isEnabled }, set: changeMusic)
                    ).disabled(musicBusy || !services.canUseNativeSensors)
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
                    if services.isGatewayDevelopment {
                        Text(
                            "GPS służy do wyszukiwania okolicy. Zapisywane pozycje są przybliżone. Wiadomości znikają z kanału po 2 godzinach. Proces fizycznego kasowania i retencji zgłoszeń jest jeszcze przygotowywany."
                        )
                        Text(
                            "Kontrolowany tryb używa CloudKit i pośrednika Cloudflare. Aplikacja nie korzysta z analityki ani reklam."
                        )
                        .accessibilityIdentifier("settings.native.privacy")
                        Button("Konto i usuwanie danych", role: .destructive) {
                            openNativeAccount?()
                            dismiss()
                        }.disabled(openNativeAccount == nil).accessibilityIdentifier(
                            "settings.native.account")
                    } else {
                        Text(
                            "GPS jest używany do wyszukiwania okolicy. Zapisywane pozycje profili i wiadomości są przybliżone. Wiadomości wygasają po 2 godzinach, a zgłoszenia są przechowywane do 30 dni. Fizyczne kasowanie działa asynchronicznie."
                        )
                        Text(
                            "Dane są przetwarzane w Firebase/Google Cloud. Aplikacja nie korzysta z analityki ani reklam."
                        )
                        Button("Usuń moje dane i konto", role: .destructive) { confirmDeletion = true }
                            .disabled(deleting)
                    }
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Gotowe") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Ukryj klawiaturę") { nameFocused = false }
                        .accessibilityIdentifier("settings.keyboard.hide")
                }
            }
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
        guard services.canUseNativeSensors else { return }
        musicBusy = true
        Task {
            guard services.canUseNativeSensors else {
                musicBusy = false
                return
            }
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
