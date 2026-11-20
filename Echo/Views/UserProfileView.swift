import EchoesCloudKit
import EchoesCore
import SwiftUI

struct UserProfileView: View {
    @Environment(\.dismiss) private var dismiss
    let userID: String
    let session: CommunitySession
    var avatars: GatewayCommunityAvatarBinding? = nil
    var reportServices: AppServices? = nil
    @State private var report: GatewayAvatarReportSession?
    @State private var reportError: String?
    private var reportAction: ((GatewayAvatarReportPhoto) -> Void)? {
        guard let services = reportServices, services.canReportAvatar, session.userID != userID else {
            return nil
        }
        return { photo in
            do {
                report = try services.openAvatarReport(photo: photo)
                reportError = nil
            } catch { reportError = error.localizedDescription }
        }
    }
    private var user: NearbyProfile? { session.users.first { $0.id == userID } }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let user {
                    VStack(spacing: 20) {
                        if let avatars {
                            CommunityAvatarView(
                                avatars: avatars, reference: user.avatarReference, surface: .profile,
                                name: user.name, size: 112, onReport: reportAction)
                        } else {
                            Image(systemName: "person.crop.circle.fill").font(.largeTitle).foregroundStyle(
                                Color.meddleCoral)
                        }
                        if let reportError { Text(reportError).font(.caption).foregroundStyle(.secondary) }
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
                        .disabled(session.blockingUserIDs.contains(userID))
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
        .presentationDetents(avatars == nil ? [.medium, .large] : [.large])
        .sheet(item: $report) { value in AvatarReportView(session: value).presentationDetents([.large]) }
        .onDisappear { report?.close() }
        .onChange(of: userID) { _, _ in
            report?.close()
            report = nil
            reportError = nil
        }
    }
}
