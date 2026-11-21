#if DEBUG
    import SwiftUI

    struct AvatarReviewPreviewView: View {
        let mode: String
        @State private var fixture: AvatarReviewPreviewFixture?
        @State private var failed = false
        var body: some View {
            NavigationStack {
                Group {
                    if let fixture {
                        AvatarReviewView(host: fixture.host, preview: true)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Menu("Test", systemImage: "testtube.2") {
                                        Button("Zmień konto testowe") { try? fixture.source.changeAccount() }
                                            .accessibilityIdentifier("avatar.review.fixture.switch")
                                        Button("Zwolnij odpowiedź") {
                                            Task { await fixture.transport.release() }
                                        }
                                        .accessibilityIdentifier("avatar.review.fixture.release")
                                    }.accessibilityIdentifier("avatar.review.fixture.menu")
                                }
                            }
                            .safeAreaInset(edge: .bottom) {
                                Text(
                                    "Decyzje: \(fixture.stats.decisions) • Wylogowania: \(fixture.source.rejections)"
                                )
                                .font(.caption).frame(maxWidth: .infinity).padding(8)
                                .background(.bar).accessibilityIdentifier("avatar.review.fixture.count")
                                .accessibilityValue("Zamknięcia: \(fixture.stats.retirements)")
                            }
                    } else if failed {
                        ContentUnavailableView("Podgląd niedostępny", systemImage: "exclamationmark.triangle")
                    } else {
                        ProgressView("Przygotowanie…")
                    }
                }
            }
            .task {
                guard fixture == nil, !failed else { return }
                do {
                    let run =
                        ProcessInfo.processInfo.environment["ECHOES_AVATAR_REVIEW_UI_RUN"]
                        ?? UUID().uuidString.lowercased()
                    fixture = try await AvatarReviewPreviewFixture.make(mode: mode, runID: run)
                } catch { failed = true }
            }
        }
    }
    #Preview("Kolejka moderatora") { AvatarReviewPreviewView(mode: "normal") }
    #Preview("Niepewna decyzja") { AvatarReviewPreviewView(mode: "not-applied") }
    #Preview("Utrata potwierdzenia zamknięcia") { AvatarReviewPreviewView(mode: "retire-lost") }
    #Preview("Brak uprawnień") { AvatarReviewPreviewView(mode: "denied") }
    #Preview("Pusta kolejka") { AvatarReviewPreviewView(mode: "empty") }
#endif
