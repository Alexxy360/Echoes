import EchoesCore
import SwiftUI

struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var session: CommunitySession
    @FocusState private var inputFocused: Bool
    @State private var atBottom = true
    @State private var reportID: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Okolica około 3 km • wiadomości wygasają po 2 godzinach").font(.caption)
                    .foregroundStyle(.secondary).padding(.horizontal)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if session.nextCursor != nil {
                                Button("Wczytaj starsze") {
                                    Task { await session.refreshMessages(older: true) }
                                }
                                .disabled(session.isLoadingMessages)
                            }
                            if session.isLoadingMessages && !session.didLoadMessages {
                                ProgressView("Wczytywanie wiadomości…")
                            } else if session.usableCoordinate == nil {
                                ContentUnavailableView(
                                    "Czekamy na lokalizację", systemImage: "location.slash",
                                    description: Text("Kanał pojawi się po uzyskaniu aktualnej pozycji."))
                            } else if session.didLoadMessages && session.messages.isEmpty {
                                ContentUnavailableView(
                                    "W okolicy jest cicho", systemImage: "bubble.left.and.bubble.right",
                                    description: Text("Możesz wysłać pierwszą wiadomość."))
                            }
                            ForEach(session.messages) { message in
                                MessageRow(message: message, own: message.senderID == session.userID).id(
                                    message.id
                                )
                                .contextMenu {
                                    if message.senderID != session.userID {
                                        Button("Zgłoś wiadomość", systemImage: "flag") {
                                            reportID = message.id
                                        }
                                        Button(
                                            "Zablokuj nadawcę", systemImage: "person.crop.circle.badge.xmark",
                                            role: .destructive
                                        ) {
                                            Task { await session.block(userID: message.senderID) }
                                        }
                                    }
                                }
                            }
                            Color.clear.frame(height: 1).id("timeline-bottom")
                        }.padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onScrollGeometryChange(for: Bool.self) {
                        $0.contentSize.height - $0.visibleRect.maxY < 100
                    } action: { _, value in
                        atBottom = value
                    }
                    .onChange(of: session.messages.last?.id) { _, _ in
                        guard atBottom else { return }
                        if reduceMotion {
                            proxy.scrollTo("timeline-bottom", anchor: .bottom)
                        } else {
                            withAnimation { proxy.scrollTo("timeline-bottom", anchor: .bottom) }
                        }
                    }
                }
                HStack(alignment: .bottom) {
                    TextField("Napisz wiadomość…", text: $session.draft, axis: .vertical)
                        .lineLimit(1...5).focused($inputFocused).textFieldStyle(.roundedBorder)
                        .disabled(session.isSending).accessibilityIdentifier("chat.draft")
                    Button(action: send) {
                        if session.isSending {
                            ProgressView().frame(minWidth: 44, minHeight: 44)
                        } else {
                            Image(systemName: "paperplane.fill").frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    .accessibilityLabel("Wyślij wiadomość").accessibilityIdentifier("chat.send").disabled(
                        !session.canSend)
                }.padding().background(.regularMaterial)
                if session.draft.utf16.count > CommunityPolicy.maximumMessageLength {
                    Text("Wiadomość może mieć najwyżej 500 znaków.").font(.caption).foregroundStyle(
                        Color.meddleCoral)
                }
            }
            .safeAreaInset(edge: .top) { SessionFeedback(session: session) }
            .background(Color.meddleNavy).navigationTitle("Lokalny kanał").navigationBarTitleDisplayMode(
                .inline
            )
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Zamknij") { dismiss() } } }
            .task {
                session.isChatOpen = true
                await session.refreshMessages()
            }
            .onDisappear { session.isChatOpen = false }
            .confirmationDialog(
                "Zgłoś wiadomość",
                isPresented: Binding(get: { reportID != nil }, set: { if !$0 { reportID = nil } }),
                titleVisibility: .visible
            ) {
                ForEach(["Spam", "Nękanie lub groźby", "Inna niedozwolona treść"], id: \.self) { reason in
                    Button(reason) {
                        if let id = reportID { Task { await session.report(messageID: id, reason: reason) } }
                        reportID = nil
                    }
                }
            }
        }
    }
    private func send() {
        Task {
            if await session.sendDraft() {
                atBottom = true
                inputFocused = true
            }
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let own: Bool
    var body: some View {
        HStack {
            if own { Spacer(minLength: 35) }
            VStack(alignment: .leading, spacing: 5) {
                Text(own ? "Ty" : message.senderName).font(.caption.bold()).foregroundStyle(
                    Color.meddleTeal)
                Text(message.text).textSelection(.enabled)
                Text(Date(timeIntervalSince1970: message.timestamp / 1000), style: .time).font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12).background(
                own ? Color.meddleCoral.opacity(0.25) : Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 16))
            if !own { Spacer(minLength: 35) }
        }.accessibilityElement(children: .combine)
    }
}
