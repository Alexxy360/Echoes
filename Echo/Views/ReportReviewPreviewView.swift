#if DEBUG
    import SwiftUI

    struct ReportReviewPreviewView: View {
        let mode: String
        @State private var fixture: ReportReviewPreviewFixture?
        @State private var failed = false
        var body: some View {
            NavigationStack {
                Group {
                    if let fixture {
                        ReportReviewView(host: fixture.host, preview: true)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Menu("Test", systemImage: "testtube.2") {
                                        Button("Zmień konto testowe") { try? fixture.source.changeAccount() }
                                        Button("Zwolnij odpowiedź") {
                                            Task { await fixture.transport.release() }
                                        }
                                    }.accessibilityIdentifier("report.review.fixture.menu")
                                }
                            }
                            .safeAreaInset(edge: .bottom) {
                                Text(
                                    "Decyzje: \(fixture.stats.decisions) • Wylogowania: \(fixture.source.rejections)"
                                )
                                .font(.caption).frame(maxWidth: .infinity).padding(8).background(.bar)
                                .accessibilityIdentifier("report.review.fixture.count")
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
                        ProcessInfo.processInfo.environment["ECHOES_REPORT_REVIEW_UI_RUN"]
                        ?? UUID().uuidString.lowercased()
                    fixture = try await ReportReviewPreviewFixture.make(mode: mode, runID: run)
                } catch { failed = true }
            }
        }
    }
    #Preview("Zgłoszenia") { ReportReviewPreviewView(mode: "normal") }
    #Preview("Niepewna decyzja") { ReportReviewPreviewView(mode: "not-applied") }
    #Preview("Utracone potwierdzenie zamknięcia") { ReportReviewPreviewView(mode: "retire-lost") }
    #Preview("Brak roli") { ReportReviewPreviewView(mode: "denied") }
    #Preview("Brak wiadomości") { ReportReviewPreviewView(mode: "missing") }
#endif
