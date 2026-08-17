import AppKit
import SwiftUI
import UserNotifications
import BatonCore

extension Notification.Name {
    /// Decouples notification delivery from navigation so the app delegate never owns UI state.
    static let batonOpenWorkspace = Notification.Name("batonOpenWorkspace")
    /// Carries a `baton://` URL from the Apple Event handler to whichever window is open.
    static let batonHandleURL = Notification.Name("batonHandleURL")
}

/// Bridges macOS lifecycle callbacks into the observation-driven app without introducing a second state owner.
@MainActor
final class BatonAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Claiming the URL Apple Event has to happen before launching finishes. If SwiftUI's own
    /// `onOpenURL` path handles a `baton://` link instead, a WindowGroup opens a SECOND window
    /// for it, which is not what anyone wants from a deep link that is meant to add a workspace
    /// to the window already on screen.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }

        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .batonHandleURL, object: url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let workspaceID = Notifications.workspaceID(from: response)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            if let workspaceID {
                NotificationCenter.default.post(name: .batonOpenWorkspace, object: workspaceID)
            }
            completionHandler()
        }
    }
}

/// Preserves Conductor deep links so existing scripts can hand work to Baton unchanged.
@MainActor
enum BatonDeepLink {
    /// The Apple Event handler and SwiftUI's onOpenURL can both see the same link, and creating
    /// the same workspace twice is a lot more annoying than dropping a genuine duplicate that
    /// arrived within a second of the first.
    private static var lastHandled: (url: URL, at: Date)?

    static func open(_ url: URL, in app: AppModel) {
        if let last = lastHandled, last.url == url, Date().timeIntervalSince(last.at) < 2 {
            return
        }
        lastHandled = (url, Date())

        guard url.scheme?.lowercased() == "baton",
              let values = values(from: url),
              let prompt = values["prompt"]?.removingPercentEncoding,
              let path = values["path"]?.removingPercentEncoding,
              !prompt.isEmpty,
              !path.isEmpty else {
            app.alert = BatonAlert(
                title: "Could not open the Baton link",
                message: "The link must include a prompt and project path."
            )
            return
        }

        let requestedPath = canonicalPath(path)
        guard let repo = app.repos.first(where: { canonicalPath($0.path) == requestedPath }) else {
            app.alert = BatonAlert(
                title: "Project not found",
                message: "The path in this link is not one of Baton's projects: \(path)"
            )
            return
        }

        Task { await app.createWorkspace(in: repo, prompt: prompt) }
    }

    private static func values(from url: URL) -> [String: String]? {
        let absolute = url.absoluteString
        guard let separator = absolute.range(of: "://") else { return nil }
        var payload = String(absolute[separator.upperBound...])
        if payload.hasPrefix("?") { payload.removeFirst() }

        var values: [String: String] = [:]
        for pair in payload.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            values[String(pieces[0])] = String(pieces[1]).replacingOccurrences(of: "+", with: " ")
        }
        return values
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

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

/// Exposes the hosting window for title-bar customization that SwiftUI does not model directly.
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> WindowReadingView {
        let view = WindowReadingView()
        view.onWindowChange = { window = $0 }
        return view
    }

    func updateNSView(_ nsView: WindowReadingView, context: Context) {
        nsView.onWindowChange = { window = $0 }
        nsView.reportWindow()
    }

    /// Reports attachment changes because a representable is created before its window exists.
    final class WindowReadingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportWindow()
        }

        func reportWindow() {
            onWindowChange?(window)
        }
    }
}
