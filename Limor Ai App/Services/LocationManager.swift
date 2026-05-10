import CoreLocation
import Foundation

@MainActor
final class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var cityName: String?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    override init() {
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 1000

        // Seed from the last known coordinate so the first /api/now call already
        // has lat/lng — saves a redundant network round-trip on app launch.
        if let cached = SharedStore.lastCoordinate {
            self.coordinate = CLLocationCoordinate2D(latitude: cached.lat, longitude: cached.lng)
        }
    }

    func requestWhenInUseAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    private func reverseGeocode(_ location: CLLocation) {
        // Hebrew locale gives back Hebrew city names ("תל אביב-יפו" instead of "Tel Aviv-Yafo").
        let preferredLocale = Locale(identifier: "he_IL")
        geocoder.reverseGeocodeLocation(location, preferredLocale: preferredLocale) { [weak self] placemarks, _ in
            guard let placemark = placemarks?.first else { return }
            let name = placemark.locality
                ?? placemark.subAdministrativeArea
                ?? placemark.administrativeArea
                ?? placemark.country
            Task { @MainActor [weak self] in
                self?.cityName = name
            }
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            self.coordinate = last.coordinate
            SharedStore.lastCoordinate = (last.coordinate.latitude, last.coordinate.longitude)
            self.reverseGeocode(last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silent fail — weather just stays nil.
    }
}
