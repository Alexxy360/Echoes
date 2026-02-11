import Foundation
import FirebaseFirestore
import CoreLocation
import UIKit

struct ChatMessage: Identifiable {
    let id: String
    let text: String
    let senderName: String
    let senderId: String
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D
    var isFromCurrentUser: Bool {
        return senderId == (UIDevice.current.identifierForVendor?.uuidString ?? "")
    }
}

@Observable
class ChatManager {
    private let db = Firestore.firestore()
    var messages: [ChatMessage] = []
    private var listener: ListenerRegistration?
    
    func listenForMessages(userLocation: CLLocation?) {
        guard let userLocation = userLocation else { return }
        stopListening()
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        listener = db.collection("messages")
            .whereField("timestamp", isGreaterThan: twoHoursAgo)
            .order(by: "timestamp", descending: false)
            .limit(to: 100)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self, let documents = snapshot?.documents else { return }
                
                self.messages = documents.compactMap { doc -> ChatMessage? in
                    let data = doc.data()
                    let lat = data["latitude"] as? Double ?? 0
                    let lon = data["longitude"] as? Double ?? 0
                    let msgLocation = CLLocation(latitude: lat, longitude: lon)
                    let distance = userLocation.distance(from: msgLocation)
                    if distance > 3000 { return nil }
                    let timestamp = (data["timestamp"] as? Timestamp)?.dateValue() ?? Date()
                    
                    return ChatMessage(
                        id: doc.documentID,
                        text: data["text"] as? String ?? "",
                        senderName: data["senderName"] as? String ?? "Nieznajomy",
                        senderId: data["senderId"] as? String ?? "",
                        timestamp: timestamp,
                        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    )
                }
            }
    }
    
    func sendMessage(text: String, userLocation: CLLocation?, userName: String) {
        guard let location = userLocation, !text.isEmpty else { return }
        
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? "Unknown"
        let lat = Double(String(format: "%.5f", location.coordinate.latitude)) ?? location.coordinate.latitude
        let lon = Double(String(format: "%.5f", location.coordinate.longitude)) ?? location.coordinate.longitude
        let data: [String: Any] = [
            "text": text,
            "senderName": userName,
            "senderId": deviceID,
            "latitude": lat,
            "longitude": lon,
            "timestamp": FieldValue.serverTimestamp()
        ]
        
        db.collection("messages").addDocument(data: data)
    }
    
    func stopListening() {
        listener?.remove()
        listener = nil
    }
    
    deinit {
        stopListening()
    }
}
