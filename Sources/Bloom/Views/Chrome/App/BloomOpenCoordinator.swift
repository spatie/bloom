import Foundation
import BloomCore

/// One lifecycle bridge for the two ways macOS delivers things Bloom can open.
///
/// AppKit owns the reliable cold-launch callbacks and SwiftUI remains as a fallback. Both feed
/// this object, so their duplicate deliveries share one ledger and a directory can never fall
/// through to the custom URL parser.
@MainActor
final class BloomOpenCoordinator {
    static let shared = BloomOpenCoordinator()

    private weak var app: AppModel?
    private var inbox = ApplicationOpenInbox()

    private init() {}

    func attach(_ app: AppModel) {
        self.app = app
        guard app.isLoaded else { return }
        deliver(inbox.connect())
    }

    func receive(_ url: URL) {
        deliver(inbox.receive(url))
    }

    private func deliver(_ targets: [ApplicationOpenTarget]) {
        guard let app else { return }
        for target in targets {
            MainWindow.raise()
            switch target {
            case .deepLink(let url):
                Task { @MainActor [weak self, weak app] in
                    guard let self, let app else { return }
                    await BloomDeepLink.open(url, in: app)
                    self.inbox.finish(target)
                }

            case .projectDirectory(let path):
                Task { @MainActor [weak self, weak app] in
                    guard let self, let app else { return }
                    await app.addRepository(at: path, focusing: true)
                    self.inbox.finish(target)
                }
            }
        }
    }
}
