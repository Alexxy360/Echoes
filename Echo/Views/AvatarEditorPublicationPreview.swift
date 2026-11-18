#if DEBUG
    import EchoesCloudKit
    import SwiftUI

    /// Isolated editor previews with synthetic account, profile and photo data; no network or iCloud.
    struct AvatarEditorPublicationPreview: View {
        let mode: String
        @State private var fixture: CommunityPreviewFixture?
        @State private var session: GatewayAvatarEditorSession?
        @State private var failed = false
        var body: some View {
            Group {
                if let session {
                    AvatarEditorView(
                        session: session, avatars: fixture?.services?.avatars,
                        previewSelection: fixture?.services?.avatarPreviewSelection)
                } else if failed {
                    ContentUnavailableView("Podgląd niedostępny", systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("Przygotowanie podglądu…")
                }
            }
            .task {
                guard session == nil, !failed else { return }
                do {
                    let value = try CommunityPreviewFixture(mode: mode)
                    await value.open()
                    guard let services = value.services else { throw GatewayAvatarFailure.unavailable }
                    fixture = value
                    session = try services.openAvatarEditor()
                } catch { failed = true }
            }
        }
    }
    #Preview("Zatwierdzone • bez lokalnego uploadu") {
        AvatarEditorPublicationPreview(mode: "avatar-owner-existing-approved")
    }
    #Preview("Oczekiwanie na sprawdzenie") {
        AvatarEditorPublicationPreview(mode: "avatar-owner-existing-pending")
    }
#endif
