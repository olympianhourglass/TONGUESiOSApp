import Foundation
import CoreLocation
import Observation

@Observable
@MainActor
final class LocationManager {
    var coordinate: CLLocationCoordinate2D?
    var horizontalAccuracy: CLLocationAccuracy?
    var errorMessage: String?

    private let manager = CLLocationManager()
    // CoreLocation checks `respondsToSelector:` on the delegate from a
    // background queue. A `@MainActor`-isolated delegate's @objc thunks
    // aren't visible to that synchronous check, which makes CoreLocation
    // log "delegate must respond to locationManager:didUpdateLocations:"
    // and silently drop updates. Keeping the delegate as a plain,
    // non-isolated NSObject that forwards to us via closures avoids that.
    private let proxy = LocationDelegateProxy()

    init() {
        proxy.onUpdate = { [weak self] coord, accuracy in
            Task { @MainActor in
                self?.coordinate = coord
                self?.horizontalAccuracy = accuracy
                self?.errorMessage = nil
            }
        }
        proxy.onError = { [weak self] message in
            Task { @MainActor in self?.errorMessage = message }
        }
        proxy.onAuthChange = { [weak self] status in
            Task { @MainActor in self?.handleAuthChange(status) }
        }
        manager.delegate = proxy
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestLocation() {
        errorMessage = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            errorMessage = "Location access is disabled. Enable it for TONGUES in Settings → Privacy → Location Services."
        @unknown default:
            break
        }
    }

    private func handleAuthChange(_ status: CLAuthorizationStatus) {
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        }
    }
}

// Plain, non-actor-isolated CLLocationManager delegate. Its @objc methods
// are synchronously discoverable by CoreLocation's `respondsToSelector:`
// check; it just forwards events to the owning LocationManager. Closure
// payloads are all Sendable value types (coordinate, accuracy, status).
private final class LocationDelegateProxy: NSObject, CLLocationManagerDelegate {
    var onUpdate: (@Sendable (CLLocationCoordinate2D, CLLocationAccuracy) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    var onAuthChange: (@Sendable (CLAuthorizationStatus) -> Void)?

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        onUpdate?(location.coordinate, location.horizontalAccuracy)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onError?(error.localizedDescription)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthChange?(manager.authorizationStatus)
    }
}
