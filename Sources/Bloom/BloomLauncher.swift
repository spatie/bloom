import Foundation

/// The Flare probe must exit before SwiftUI constructs AppModel or opens a database.
/// Normal launches still enter through SwiftUI's App.main implementation.
@main
enum BloomLauncher {
    @MainActor
    static func main() async {
        Log.launchStep("main")
        TranscriptTableView.asksEveryRowHeight()
        // Release builds too: it measures how scrolling feels, and only a release build says that.
        if ScrollLab.isRequested { ScrollLab.runAndExit() }
        #if DEBUG
        if FlareProbe.isRequested { await FlareProbe.runAndExit() }
        if WelcomeLayoutProbe.isRequested { WelcomeLayoutProbe.runAndExit() }
        if ReviewRunProbe.isRequested { ReviewRunProbe.runAndExit() }
        #endif
        BloomApp.main()
    }
}
