import SwiftUI
import CoreLocation

struct ChatView: View {
    @State private var chatManager = ChatManager()
    @State private var messageText = ""
    var userLocation: CLLocation?
    var userName: String
    @Binding var isChatOpen: Bool
    
    @FocusState private var isInputActive: Bool
    
    var body: some View {
        ZStack {
            Color.meddleNavy.ignoresSafeArea()
                .onTapGesture {
                    isInputActive = false
                }
            
            VStack {
                HStack {
                    Text("LOKALNY KANAŁ (3KM)")
                        .font(.system(.headline, design: .monospaced))
                        .foregroundColor(.meddleTeal)
                        .tracking(2)
                    
                    Spacer()
                    
                    Button(action: {
                        isInputActive = false
                        withAnimation { isChatOpen = false }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding()
                .background(Color.meddleNavy.opacity(0.9))
                
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(chatManager.messages) { msg in
                                HStack {
                                    if msg.isFromCurrentUser { Spacer() }
                                    
                                    VStack(alignment: msg.isFromCurrentUser ? .trailing : .leading, spacing: 4) {
                                        if !msg.isFromCurrentUser {
                                            Text(msg.senderName)
                                                .font(.caption2)
                                                .foregroundColor(.meddleTeal)
                                        }
                                        
                                        Text(msg.text)
                                            .padding(10)
                                            .background(msg.isFromCurrentUser ? Color.meddleCoral : Color.white.opacity(0.1))
                                            .foregroundColor(.white)
                                            .cornerRadius(12)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(msg.isFromCurrentUser ? Color.clear : Color.meddleTeal.opacity(0.3), lineWidth: 1)
                                            )
                                    }
                                    .frame(maxWidth: 250, alignment: msg.isFromCurrentUser ? .trailing : .leading)
                                    .id(msg.id)
                                    
                                    if !msg.isFromCurrentUser { Spacer() }
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.top, 10)
                        
                        Color.clear.frame(height: 50)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: chatManager.messages.count) {
                        if let lastId = chatManager.messages.last?.id {
                            withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                        }
                    }
                    .onTapGesture {
                        isInputActive = false
                    }
                }
                
                HStack {
                    TextField("Nadaj komunikat...", text: $messageText)
                        .focused($isInputActive)
                        .padding(10)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(20)
                        .foregroundColor(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.meddleTeal.opacity(0.5), lineWidth: 1)
                        )
                        .submitLabel(.send)
                        .onSubmit {
                            sendMessage()
                        }
                    
                    Button(action: sendMessage) {
                        Image(systemName: "paperplane.fill")
                            .font(.title2)
                            .foregroundColor(messageText.isEmpty ? .gray : .meddleCoral)
                            .rotationEffect(.degrees(45))
                    }
                    .disabled(messageText.isEmpty)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .onAppear {
            chatManager.listenForMessages(userLocation: userLocation)
        }
    }
    
    func sendMessage() {
        chatManager.sendMessage(text: messageText, userLocation: userLocation, userName: userName)
        messageText = ""
    }
}
