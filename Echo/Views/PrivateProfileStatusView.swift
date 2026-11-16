import EchoesCloudKit
import SwiftUI

/// Private name status. Refresh never overwrites the editor's draft or publishes a profile.
struct PrivateProfileStatusView: View {
    let services: AppServices
    var alwaysShowRefresh = false
    var body: some View {
        if let profile = services.privateProfile {
            if profile.isBusy {
                ProgressView("Sprawdzanie prywatnego profilu…")
                    .accessibilityIdentifier("profile.loading")
            } else {
                if let error = profile.errorMessage {
                    Text(error).foregroundStyle(Color.meddleCoral)
                        .accessibilityIdentifier("profile.error")
                    Text(
                        "Odśwież profil i porównaj odczytaną nazwę przed kolejną próbą. Edytowany pseudonim pozostanie w polu."
                    )
                    .font(.caption)
                }
                if profile.didLoad {
                    Text(
                        profile.profile.map { "Odczytany pseudonim: " + $0.displayName }
                            ?? "Nie masz jeszcze zapisanego pseudonimu w iCloud."
                    )
                    .font(.caption).accessibilityIdentifier("profile.loaded")
                }
                if alwaysShowRefresh || !profile.didLoad {
                    Button("Odśwież prywatny profil") {
                        Task { await services.prepareProfile(force: true) }
                    }.disabled(services.isUpdatingName).accessibilityIdentifier("profile.refresh")
                }
            }
        }
    }
}
