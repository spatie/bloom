import Foundation
import BloomCore

/// The Flare probe must exit before SwiftUI constructs AppModel or opens a database.
/// Normal launches still enter through SwiftUI's App.main implementation.
@main
enum BloomLauncher {
    @MainActor
    static func main() async {
        #if DEBUG
        if FlareProbe.isRequested { await FlareProbe.runAndExit() }
        #endif
        BloomApp.main()
    }
}
