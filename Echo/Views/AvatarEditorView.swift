import EchoesCloudKit
import PhotosUI
import SwiftUI

struct AvatarEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let session: GatewayAvatarEditorSession
    var avatars: GatewayCommunityAvatarBinding? = nil
    var previewSelection: (@Sendable () async throws -> PreparedAvatar)? = nil
    @State private var photo: PhotosPickerItem?
    @State private var confirmation: AvatarEditorConfirmation?
    var body: some View {
        NavigationStack {
            Form {
                #if DEBUG
                    if previewSelection != nil {
                        Section {
                            Text("Podgląd UI • zdjęcie syntetyczne • bez backendu")
                                .font(.caption).accessibilityIdentifier("avatar.editor.previewNotice")
                        }
                    }
                #endif
                if session.isCurrent {
                    AvatarEditorStatusSection(session: session)
                    if let reference = session.publishedReference {
                        Section("Opublikowane zdjęcie") {
                            CommunityAvatarView(
                                avatars: avatars, reference: reference, surface: .ownerEditor,
                                name: "", size: 120)
                            Text("Podgląd sprawdza aktualny dostęp. Nie wymaga włączenia lokalizacji.")
                                .font(.caption)
                        }
                    }
                    AvatarEditorSelectionSection(
                        session: session, photo: $photo, previewSelection: previewSelection)
                    AvatarEditorActionsSection(session: session) { confirmation = $0 }
                } else {
                    Section {
                        Text("Sesja zdjęcia została zamknięta. Otwórz ją ponownie w ustawieniach.")
                            .accessibilityIdentifier("avatar.editor.closed")
                    }
                }
            }
            .accessibilityIdentifier("avatar.editor.form")
            .navigationTitle("Twoje zdjęcie")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Gotowe", action: close) } }
            .navigationDestination(item: $confirmation) { intent in
                AvatarEditorConfirmationView(session: session, confirmation: intent)
            }
        }
        .task { await session.perform(.refresh) }
        .task(id: photo) { await prepareSelection() }
        .onDisappear { session.close() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { close() } }
        .accessibilityIdentifier("avatar.editor")
    }
    private func close() {
        photo = nil
        session.close()
        dismiss()
    }
    private func prepareSelection() async {
        guard let selected = photo else { return }
        await session.prepare {
            guard let value = try await selected.loadTransferable(type: AvatarPhotoTransfer.self) else {
                throw AvatarPreparationFailure.unsupportedImage
            }
            return value.prepared
        }
        if !Task.isCancelled { photo = nil }
    }
}

struct AvatarEditorStatusSection: View {
    let session: GatewayAvatarEditorSession
    private var status: String {
        guard let value = session.snapshot else { return "Sprawdź aktualny stan zdjęcia." }
        switch value.status {
        case .none: return "Brak opublikowanego zdjęcia."
        case .uploading: return "Wysyłka wymaga sprawdzenia."
        case .clearing: return "Wycofywanie wymaga sprawdzenia."
        case .pendingReview: return "Zdjęcie czeka na sprawdzenie przez obsługę."
        case .approved: return "Zdjęcie zatwierdzone. Możesz je opublikować."
        case .rejected: return "Zdjęcie nie zostało zatwierdzone. Możesz je wycofać."
        case .published: return "Zdjęcie jest opublikowane."
        }
    }
    var body: some View {
        Section("Stan zdjęcia") {
            Text(status).accessibilityIdentifier("avatar.editor.status")
            if session.isBusy {
                ProgressView(
                    session.isPreparingPhoto ? "Przygotowywanie zdjęcia…" : "Sprawdzanie operacji zdjęcia…"
                )
                .accessibilityIdentifier("avatar.editor.busy")
            }
            if let error = session.errorMessage {
                Text(error).foregroundStyle(Color.meddleCoral).accessibilityIdentifier("avatar.editor.error")
            }
            if session.needsRefresh && session.pendingOperation != nil {
                Text("Wynik ostatniej próby wymaga sprawdzenia. Zachowaliśmy tę samą operację.").font(
                    .caption)
            }
            if let pending = session.pendingOperation, case .upload = pending.intent, !pending.hasSource {
                Text("Lokalna kopia zdjęcia wygasła. Nadal możesz sprawdzić wynik lub wycofać zdjęcie.").font(
                    .caption)
            }
        }
    }
}
