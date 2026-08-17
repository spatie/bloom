import AppKit
import SwiftUI
import UserNotifications
import BatonCore

extension Notification.Name {
    /// Decouples notification delivery from navigation so the app delegate never owns UI state.
    static let batonOpenWorkspace = Notification.Name("batonOpenWorkspace")
}

/// Bridges macOS lifecycle callbacks into the observation-driven app without introducing a second state owner.
@MainActor
final class BatonAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
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
    static func open(_ url: URL, in app: AppModel) {
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
        content.onOpenURL { url in
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
