import SwiftUI
import MapKit
import CoreLocation
import FirebaseFirestore
import MediaPlayer

@Observable
class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let db = Firestore.firestore()
    private let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? "UnknownUser"
    
    var userLocation: CLLocation?
    var otherUsers: [NearbyUser] = []
    
    var userName: String = UserDefaults.standard.string(forKey: "userName") ?? "" {
        didSet {
            UserDefaults.standard.set(userName, forKey: "userName")
            updateFirebase()
        }
    }
    private var lastUploadTime: Date = Date.distantPast
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        
        
        MPMediaLibrary.requestAuthorization { status in
            switch status {
            case .authorized:
                print("✅ [MUSIC] Dostęp do Apple Music przyznany!")
            case .denied, .restricted:
                print("❌ [MUSIC] Brak dostępu! Użytkownik musi włączyć to w Ustawieniach.")
            case .notDetermined:
                print("⚠️ [MUSIC] Decyzja niepodjęta.")
            @unknown default:
                break
            }
        }
    }
    internal func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        userLocation = location
        if Date().timeIntervalSince(lastUploadTime) > 10 {
                    updateFirebase()
                    lastUploadTime = Date()
                }
            }
    
    func requestLocation() {
        manager.requestAlwaysAuthorization()
        manager.startUpdatingLocation()
    }
 
    private func updateFirebase() {
        guard let location = userLocation else { return }
        
        let (songTitle, songID) = getActiveTrackInfo()
        
        if songID.isEmpty || songID == "0" {
            print("⚠️ [FIREBASE] Wysyłam piosenkę BEZ ID (tylko tytuł): \(songTitle)")
        } else {
            print("🎵 [FIREBASE] Wysyłam piosenkę Z ID: \(songID) (\(songTitle))")
        }
        
        let userData: [String: Any] = [
            "name": userName.isEmpty ? "Nieznajomy" : userName,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "lastSong": songTitle,
            "appleMusicId": songID,
            "timestamp": FieldValue.serverTimestamp()
        ]
        
        db.collection("users").document(deviceID).setData(userData) { error in
            if let error = error {
                print("❌ [FIREBASE ERROR] Błąd zapisu: \(error.localizedDescription)")
            } else {
                print("✅ [FIREBASE] Dane zapisane pomyślnie!")
            }
        }
    }
    
    private func getActiveTrackInfo() -> (String, String) {
        let musicPlayer = MPMusicPlayerController.systemMusicPlayer
        
        if musicPlayer.playbackState != .playing {
            return ("Cisza...", "")
        }
        
        if let item = musicPlayer.nowPlayingItem {
            let title = item.title ?? ""
            let artist = item.artist ?? ""
            
            if title == "Apple Music 1" || title.isEmpty {
                return ("Cisza...", "")
            }
            
            let fullTitle = artist.isEmpty ? title : "\(title) - \(artist)"
            let storeID = item.playbackStoreID
            
            print("🎧 [PLAYER] Aktualnie gra: \(fullTitle), ID: \(storeID)")
            
            return (fullTitle, storeID)
        }
        
        return ("Cisza...", "")
    }
    
    func fetchNearbyUsers() {
        db.collection("users").addSnapshotListener { [weak self] querySnapshot, error in
            guard let self = self, let documents = querySnapshot?.documents else { return }
            
            self.otherUsers = documents.compactMap { doc -> NearbyUser? in
                let data = doc.data()
                if doc.documentID == self.deviceID { return nil }
                
                if let serverTimestamp = data["timestamp"] as? Timestamp {
                    let updateDate = serverTimestamp.dateValue()
                    let timeAgo = Date().timeIntervalSince(updateDate)
                    
                    if timeAgo > 600 {
                        print("👻 [GHOST] Użytkownik \(data["name"] ?? "") jest offline (czas: \(Int(timeAgo))s). Ukrywam go.")
                        return nil
                    }
                }
                
                return NearbyUser(
                    id: doc.documentID,
                    name: data["name"] as? String ?? "Duch",
                    coordinate: CLLocationCoordinate2D(
                        latitude: data["latitude"] as? Double ?? 0,
                        longitude: data["longitude"] as? Double ?? 0
                    ),
                    lastSong: data["lastSong"] as? String ?? "",
                    appleMusicId: data["appleMusicId"] as? String ?? ""
                )
            }
        }
    }
}
