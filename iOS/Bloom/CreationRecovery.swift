import Foundation
import BloomClient

@MainActor
enum CreationRecovery {
    static let store = PendingCreationStore(file: URL.applicationSupportDirectory.appendingPathComponent("pending-creations.json"))
}
