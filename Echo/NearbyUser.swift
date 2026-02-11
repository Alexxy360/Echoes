import CoreLocation
import Foundation

struct NearbyUser: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let lastSong: String
    let appleMusicId: String 
}
