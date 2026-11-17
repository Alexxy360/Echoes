import EchoesCloudKit
import PhotosUI
import SwiftUI

struct AvatarEditorSelectionSection: View {
    let session: GatewayAvatarEditorSession
    @Binding var photo: PhotosPickerItem?
    var previewSelection: (@Sendable () async throws -> PreparedAvatar)?
    var body: some View {
        Section("Wybierz zdjęcie") {
            PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                Label("Wybierz z biblioteki", systemImage: "photo.on.rectangle")
            }.disabled(!session.canChoosePhoto).accessibilityIdentifier("avatar.editor.choose")
            #if DEBUG
                if previewSelection != nil {
                    Button("Wybierz przykładowe zdjęcie", action: preparePreview)
                        .disabled(!session.canChoosePhoto).accessibilityIdentifier("avatar.editor.sample")
                }
            #endif
            Text("JPEG, PNG lub HEIC do 8 MB. Sam wybór nie wysyła zdjęcia do Echoes.").font(.caption)
            if let image = session.preview, let selection = session.selectionID {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .frame(width: 120, height: 120).clipShape(RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel("Wybrane zdjęcie, jeszcze niewysłane")
                    .accessibilityIdentifier("avatar.editor.preview")
                Text(
                    "Obsługa sprawdzi zdjęcie. Udostępnisz je dopiero przyciskiem „Opublikuj”. Zgodę możesz później wycofać."
                ).font(.caption)
                Toggle(
                    "Zgadzam się na przesłanie i sprawdzenie zdjęcia",
                    isOn: Binding(
                        get: { session.consentAccepted }, set: { session.consent($0, for: selection) })
                )
                .disabled(session.isBusy).accessibilityIdentifier("avatar.editor.consent")
                Text(
                    "Przesyłamy przygotowaną kopię przez Cloudflare do CloudKit. Usuwamy metadane źródłowe, w tym GPS i informacje o aparacie. Oryginału nie zapisujemy w magazynie aplikacji."
                ).font(.caption)
                Button("Wyślij do sprawdzenia", action: submit)
                    .disabled(!session.canSubmit).accessibilityIdentifier("avatar.editor.submit")
                Button("Anuluj wybór", action: session.discardSelection)
                    .disabled(session.isBusy).accessibilityIdentifier("avatar.editor.cancelSelection")
            }
            if session.pendingOperation != nil {
                Text("Przed wybraniem kolejnego zdjęcia sprawdź wynik bieżącej próby lub wycofaj ją.").font(
                    .caption)
            }
        }
    }
    private func submit() { Task { await session.perform(.submit) } }
    private func preparePreview() {
        guard let previewSelection else { return }
        Task { await session.prepare(load: previewSelection) }
    }
}
