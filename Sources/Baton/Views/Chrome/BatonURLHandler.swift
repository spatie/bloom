import SwiftUI

/// Lets a root view opt into deep links while keeping URL parsing out of feature views.
struct BatonURLHandler: ViewModifier {
    let app: AppModel

    func body(content: Content) -> some View {
        content
            // The Apple Event handler in BatonAppDelegate is the real entry point. onOpenURL is
            // kept as a fallback for the case where macOS launches the app with the URL before
            // the handler is installed.
            .onReceive(NotificationCenter.default.publisher(for: .batonHandleURL)) { note in
                if let url = note.object as? URL { BatonDeepLink.open(url, in: app) }
            }
            .onOpenURL { url in
                BatonDeepLink.open(url, in: app)
            }
    }
}

extension View {
    func handlesBatonURLs(using app: AppModel) -> some View {
        modifier(BatonURLHandler(app: app))
    }
}
