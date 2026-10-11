import CoreLocation
import Foundation

/// Keeps the app running in the background while SSH sessions are open, the way
/// Termius and Blink do: iOS doesn't suspend an app that is receiving location
/// updates, so the connection and agent polling (and thus notifications) keep going.
/// Uses the coarsest accuracy so the GPS stays off; iOS shows the blue location pill.
@MainActor
final class BackgroundLocation: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundLocation()
    static let enabledKey = "keepAliveInBackground"

    static var isEnabled: Bool {
        // Opt-in: off by default so nobody gets a location prompt they didn't ask for.
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    private let manager = CLLocationManager()
    private var wanted = false
    private var running = false

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
    }

    func setActive(_ active: Bool) {
        wanted = active
        apply()
    }

    private func apply() {
        guard wanted else {
            if running {
                manager.stopUpdatingLocation()
                manager.allowsBackgroundLocationUpdates = false
                running = false
            }
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            guard !running else { return }
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
            running = true
        default:
            // Denied: fall back to the ~30 s background grace period.
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.apply() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
