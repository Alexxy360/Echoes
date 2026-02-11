import SwiftUI
import MapKit


extension Color {
    static let meddleNavy = Color(red: 10/255, green: 20/255, blue: 40/255)
    static let meddleTeal = Color(red: 50/255, green: 140/255, blue: 160/255)
    static let meddleCoral = Color(red: 220/255, green: 100/255, blue: 80/255)
}

struct ContentView: View {
    @State private var locationManager = LocationManager()
    @State private var tempName: String = ""
    @State private var selectedUser: NearbyUser? = nil
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    
    
    @State private var showChat: Bool = false
    @State private var isAppLoading: Bool = true
    @State private var loadingProgress: CGFloat = 0.0
    @State private var isProcessingCard: Bool = false

    var body: some View {
        ZStack {
            
            Color.meddleNavy.ignoresSafeArea()

            if !isAppLoading {
                ZStack {
                    
                    Map(position: $cameraPosition) {
                        UserAnnotation()
                        
                        ForEach(locationManager.otherUsers) { user in
                            Annotation(user.name, coordinate: user.coordinate) {
                                VStack(spacing: 4) {
                                    
                                    if user.lastSong != "Cisza..." {
                                        Text(user.lastSong)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .frame(maxWidth: 100)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.meddleNavy.opacity(0.8))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(Color.meddleTeal, lineWidth: 1)
                                            )
                                    }

                                    ZStack {
                                        Circle()
                                            .fill(user.lastSong != "Cisza..." ? Color.meddleCoral : Color.gray)
                                            .frame(width: 44, height: 44)
                                            .shadow(color: user.lastSong != "Cisza..." ? .meddleCoral.opacity(0.6) : .clear, radius: 10)
                                        
                                        Text(String(user.name.prefix(1)).uppercased())
                                            .font(.system(size: 20, weight: .heavy))
                                            .foregroundColor(.white)
                                        
                                        if user.lastSong != "Cisza..." {
                                            Image(systemName: "music.note")
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 14, height: 14)
                                                .padding(5)
                                                .background(Color.meddleNavy)
                                                .foregroundColor(.meddleTeal)
                                                .clipShape(Circle())
                                                .offset(x: 16, y: -16)
                                        }
                                    }
                                }
                                .onTapGesture {
                                    isProcessingCard = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                            selectedUser = user
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                            isProcessingCard = false
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
                    .ignoresSafeArea()
                    
                    
                    VStack {
                        LinearGradient(colors: [.meddleNavy.opacity(0.9), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 150)
                        Spacer()
                        LinearGradient(colors: [.clear, .meddleNavy], startPoint: .top, endPoint: .bottom)
                            .frame(height: 250)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                    
                    VStack {
                        HStack {
                            Image(systemName: "waveform")
                                .font(.title2)
                                .foregroundColor(.meddleCoral)
                            
                            Text("ECHOES")
                                .font(.system(size: 24, weight: .black, design: .monospaced))
                                .tracking(5)
                                .foregroundColor(.meddleTeal)
                                .shadow(color: .meddleTeal.opacity(0.5), radius: 5)
                            
                            Spacer()
                            
                            Button(action: {
                                withAnimation { cameraPosition = .userLocation(fallback: .automatic) }
                            }) {
                                Image(systemName: "location.fill")
                                    .font(.title3)
                                    .padding(10)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 60)
                        .padding(.bottom, 20)
                        .background(.ultraThinMaterial)
                        .shadow(radius: 10)
                        
                        Spacer()
                    }
                    .ignoresSafeArea()
                    
                    
                    
                    if !locationManager.userName.isEmpty {
                        VStack {
                            Spacer()
                            HStack {
                                Button(action: { withAnimation { showChat = true } }) {
                                    Image(systemName: "bubble.left.and.bubble.right.fill")
                                        .font(.title2)
                                        .foregroundColor(.white)
                                        .padding()
                                        .background(Color.meddleCoral)
                                        .clipShape(Circle())
                                        .shadow(color: .meddleCoral.opacity(0.5), radius: 10)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.meddleTeal.opacity(0.5), lineWidth: 1)
                                        )
                                }
                                .padding(.leading, 20)
                                .padding(.bottom, 50)
                                
                                Spacer()
                            }
                        }
                    }

                    
                    if let user = selectedUser {
                        VStack {
                            Spacer()
                            VStack(spacing: 20) {
                                Capsule()
                                    .fill(Color.meddleTeal.opacity(0.5))
                                    .frame(width: 40, height: 4)
                                    .padding(.top, 15)
                                
                                HStack(spacing: 15) {
                                    Circle()
                                        .fill(Color.meddleCoral)
                                        .frame(width: 55, height: 55)
                                        .overlay(
                                            Text(String(user.name.prefix(1)).uppercased())
                                                .font(.title2)
                                                .bold()
                                                .foregroundColor(.white)
                                        )
                                        .shadow(color: .meddleCoral.opacity(0.5), radius: 8)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(user.name)
                                            .font(.headline)
                                            .foregroundColor(.white)
                                        Text(user.lastSong)
                                            .font(.subheadline)
                                            .foregroundColor(.meddleTeal)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button(action: {
                                        withAnimation(.spring) { selectedUser = nil }
                                    }) {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.white.opacity(0.7))
                                            .padding(8)
                                            .background(Color.white.opacity(0.1))
                                            .clipShape(Circle())
                                    }
                                }
                                .padding(.horizontal)
                                
                                Link(destination: {
                                    if !user.appleMusicId.isEmpty && user.appleMusicId != "0" {
                                        return URL(string: "music://music.apple.com/song/\(user.appleMusicId)")!
                                    } else {
                                        let searchTerm = user.lastSong.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                                        return URL(string: "https://music.apple.com/search?term=\(searchTerm)")!
                                    }
                                }()) {
                                    HStack {
                                        Image(systemName: "play.fill")
                                        Text(user.appleMusicId.isEmpty || user.appleMusicId == "0" ? "Znajdź w Apple Music" : "Słuchaj Teraz")
                                    }
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(
                                        LinearGradient(colors: [.meddleCoral, Color(red: 0.7, green: 0.2, blue: 0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    )
                                    .foregroundColor(.white)
                                    .cornerRadius(15)
                                    .shadow(color: .meddleCoral.opacity(0.4), radius: 8, x: 0, y: 4)
                                }
                                .padding(.horizontal)
                                .padding(.bottom, 30)
                            }
                            .background(Color.meddleNavy)
                            .cornerRadius(30)
                            .overlay(
                                RoundedRectangle(cornerRadius: 30)
                                    .stroke(LinearGradient(colors: [.meddleTeal.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: -10)
                            .drawingGroup()
                            .id(user.id)
                        }
                        .transition(.move(edge: .bottom))
                        .zIndex(3)
                        .ignoresSafeArea(edges: .bottom)
                    }
                    
                    
                    if isProcessingCard {
                        Color.black.opacity(0.4).ignoresSafeArea().zIndex(4)
                        VStack { ProgressView().controlSize(.large).tint(.meddleCoral) }
                            .frame(width: 80, height: 80)
                            .background(.ultraThinMaterial)
                            .cornerRadius(20)
                            .zIndex(5)
                    }

                    
                    if locationManager.userName.isEmpty {
                        Color.meddleNavy.opacity(0.95).ignoresSafeArea()
                            .overlay(
                                VStack(spacing: 25) {
                                    Text("ECHOES")
                                        .font(.system(size: 30, weight: .black, design: .monospaced))
                                        .foregroundColor(.meddleTeal)
                                        .tracking(5)
                                    
                                    Text("Jak Cię widzą, tak Cię słyszą")
                                        .font(.subheadline)
                                        .foregroundColor(.gray)
                                    
                                    TextField("Wpisz swoje imię...", text: $tempName)
                                        .padding()
                                        .background(Color.black.opacity(0.3))
                                        .cornerRadius(12)
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.center)
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.meddleTeal.opacity(0.5), lineWidth: 1))
                                    
                                    Button(action: {
                                        if !tempName.isEmpty { locationManager.userName = tempName }
                                    }) {
                                        Text("WEJDŹ W GŁĘBIĘ")
                                            .bold()
                                            .padding()
                                            .frame(maxWidth: .infinity)
                                            .background(Color.meddleCoral)
                                            .foregroundColor(.white)
                                            .cornerRadius(12)
                                    }
                                }
                                .padding(30)
                                .background(Color.meddleNavy)
                                .cornerRadius(20)
                                .shadow(color: .meddleTeal.opacity(0.2), radius: 20)
                                .padding()
                            )
                            .zIndex(6)
                    }
                }
                .transition(.opacity)
                
                
                if showChat {
                    ChatView(
                        userLocation: locationManager.userLocation,
                        userName: locationManager.userName,
                        isChatOpen: $showChat
                    )
                    .transition(.move(edge: .bottom))
                    .zIndex(20)
                }
            }
            
            
            if isAppLoading {
                ZStack {
                    Color.meddleNavy.ignoresSafeArea()
                    RadialGradient(gradient: Gradient(colors: [.meddleTeal.opacity(0.2), .meddleNavy]), center: .center, startRadius: 5, endRadius: 300).ignoresSafeArea()
                    
                    VStack {
                        Spacer()
                        Text("ECHOES")
                            .font(.system(size: 50, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                            .tracking(8)
                            .shadow(color: .meddleCoral.opacity(0.8), radius: 15)
                        Spacer()
                        VStack(spacing: 15) {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().frame(height: 4).foregroundColor(Color.white.opacity(0.1))
                                    Capsule().frame(width: geometry.size.width * loadingProgress, height: 4)
                                        .foregroundColor(.meddleCoral)
                                        .shadow(color: .meddleCoral, radius: 8)
                                }
                            }
                            .frame(width: 150, height: 4)
                            Text("Synchronizacja fal...")
                                .font(.caption2)
                                .foregroundColor(.meddleTeal)
                        }
                        .padding(.bottom, 60)
                    }
                }
                .zIndex(10)
                .transition(.opacity.animation(.easeOut(duration: 1.0)))
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            locationManager.requestLocation()
            locationManager.fetchNearbyUsers()
            withAnimation(.easeInOut(duration: 3.0)) { loadingProgress = 1.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                withAnimation { isAppLoading = false }
            }
        }
    }
}

#Preview {
    ContentView()
}
