import CoreLocation
import EchoesCore
import Observation

@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    enum Status: Equatable { case idle, waiting, ready, denied, inaccurate, failed }
    private let manager = CLLocationManager()
    private(set) var status: Status = .idle
    private(set) var location: CLLocation?
    private var isActive = false
    private var lastRequest = Date.distantPast

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = true
        // Foreground only; permission requests are initiated by a visible user action.
    }

    var coordinate: Coordinate? {
        guard let location,
            InputValidation.usableLocation(
                coordinate: .init(
                    latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                accuracy: location.horizontalAccuracy, measuredAt: location.timestamp, now: Date())
        else { return nil }
        return .init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: resume()
        case .denied, .restricted: status = .denied
        @unknown default: status = .failed
        }
    }

    func resume() {
        isActive = true
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            status = coordinate == nil ? .waiting : .ready
            manager.startUpdatingLocation()
            manager.requestLocation()
        case .denied, .restricted:
            location = nil
            status = .denied
        default: status = .idle
        }
    }

    func pause() {
        isActive = false
        manager.stopUpdatingLocation()
    }

    func refreshIfNeeded() {
        guard isActive,
            [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus),
            Date().timeIntervalSince(lastRequest) >= 15
        else { return }
        if location == nil || Date().timeIntervalSince(location!.timestamp) >= 30 {
            lastRequest = Date()
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            self.manager.stopUpdatingLocation()
            location = nil
            status = .denied
        case .authorizedWhenInUse, .authorizedAlways:
            if isActive { resume() }
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isActive else { return }
        guard let latest = locations.last,
            InputValidation.usableLocation(
                coordinate: .init(
                    latitude: latest.coordinate.latitude, longitude: latest.coordinate.longitude),
                accuracy: latest.horizontalAccuracy, measuredAt: latest.timestamp, now: Date())
        else {
            if coordinate == nil { status = .inaccurate }
            return
        }
        location = latest
        status = .ready
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let error = error as? CLError, error.code == .locationUnknown {
            if coordinate == nil { status = .waiting }
        } else {
            status = .failed
        }
    }
}
