import EchoesCore
import SwiftUI

struct UserProfileView: View {
    @Environment(\.dismiss) private var dismiss
    let userID: String
    let session: CommunitySession
    private var user: NearbyProfile? { session.users.first { $0.id == userID } }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let user {
                    VStack(spacing: 20) {
                        Image(systemName: "person.crop.circle.fill").font(.largeTitle).foregroundStyle(
                            Color.meddleCoral)
                        Text(user.name).font(.title2.bold())
                        Text(user.lastSong.isEmpty ? "Nie udostępnia teraz muzyki" : user.lastSong)
                            .multilineTextAlignment(.center)
                        Text("Pozycja na mapie jest przybliżona.").font(.caption).foregroundStyle(.secondary)
                        if let url = MusicLink.url(id: user.appleMusicID, title: user.lastSong) {
                            Link("Otwórz w Apple Music", destination: url).buttonStyle(.borderedProminent)
                        }
                        Button("Zablokuj użytkownika", role: .destructive) {
                            Task {
                                await session.block(userID: userID)
                                if session.blockedIDs.contains(userID) { dismiss() }
                            }
                        }
                    }.padding(24).frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView(
                        "Profil jest już niedostępny", systemImage: "person.crop.circle.badge.clock")
                }
            }
            .safeAreaInset(edge: .top) { SessionFeedback(session: session) }
            .navigationTitle("Profil").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Zamknij") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
