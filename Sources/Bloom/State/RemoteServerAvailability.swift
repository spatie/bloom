import AppKit
import Observation
import BloomCore

/// Whether remote servers are shown, as one observable answer every surface reads.
///
/// An object rather than `@AppStorage` in each view because two of the readers are not views. The
/// File menu is a `Commands` body, where `@AppStorage` is inert (see `TextZoomAvailability`), and
/// `AppModel` has to refuse a remote selection from its own setter. Four copies of the same
/// preference would also be four moments to disagree while the switch is being flipped, and the
/// failure that matters here is a server's workspace left on screen after the sidebar has hidden it.
///
/// `UserDefaults.didChangeNotification` is posted for every write to the standard domain, so the
/// read is a single dictionary lookup and nothing is published unless the answer moved.
@MainActor
@Observable
final class RemoteServerAvailability {
    static let shared = RemoteServerAvailability()

    private(set) var isEnabled: Bool

    private init() {
        SystemDefaults.registerOnce()
        isEnabled = RemoteServerFeature.isEnabled(in: .standard)
        // Registered by the singleton's own initialiser and wanted for as long as the app runs, so
        // the token would only ever be stored and never used.
        // swiftlint:disable:next discarded_notification_center_observer
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in RemoteServerAvailability.shared.refresh() }
        }
    }

    private func refresh() {
        let enabled = RemoteServerFeature.isEnabled(in: .standard)
        if isEnabled != enabled { isEnabled = enabled }
    }
}
