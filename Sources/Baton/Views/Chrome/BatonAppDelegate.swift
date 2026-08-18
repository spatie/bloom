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
    /// Handed over by `BatonApp` once the scene exists. Explicit rather than a global, because the
    /// delegate is only borrowing the state to tear it down, and nothing here should be able to
    /// reach into the app's state by any other route.
    private weak var appModel: AppModel?

    /// Set once the quit sequence starts, so a second Cmd+Q cannot begin a second teardown while
    /// the first one is still waiting on the escalations.
    private var isTerminating = false

    func attach(_ model: AppModel) {
        appModel = model
        // The suppression rule needs to know which workspace the window is showing, and this is
        // the first moment there is a window to ask.
        NotificationService.shared.attach(model)
    }

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

    /// False, because Baton runs agents. Closing the only window must never be a silent way to end
    /// six turns that are halfway through editing their worktrees. The window comes back through
    /// `applicationShouldHandleReopen`, and quitting stays an explicit act.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting is where the child processes have to go. macOS reparents them to launchd instead of
    /// killing them, so an agent would keep writing to the worktree and a dev server would keep its
    /// port for the rest of the day. The reply is deferred rather than blocking: the run loop stays
    /// alive while the SIGTERM to SIGKILL escalation plays out.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }

        // Asked before anything is torn down, because quitting kills the agents rather than
        // pausing them: a turn interrupted here is work the agent has already paid for and
        // cannot resume. Only asked when there is something to lose, so a quiet quit stays one
        // keystroke.
        if let running = appModel?.runningAgentCount, running > 0, !confirmQuit(running: running) {
            return .terminateCancel
        }

        isTerminating = true

        Task { @MainActor in
            await appModel?.shutdownEverything()
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        // A last resort. Nothing should take this long, but a quit that never completes is worse
        // than one that leaves a straggler behind.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    /// Names the workspaces rather than only counting them, so the answer to "which one was that?"
    /// is on screen at the moment it is needed. Long lists are capped: past a handful the count is
    /// the useful fact and the names are noise.
    @MainActor
    private func confirmQuit(running: Int) -> Bool {
        let names = appModel?.runningAgentWorkspaceNames ?? []

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = running == 1
            ? "An agent is still running"
            : "\(running) agents are still running"

        var detail = running == 1
            ? "Quitting stops it. The turn it is in the middle of will not be finished, and it cannot be resumed."
            : "Quitting stops them. The turns they are in the middle of will not be finished, and they cannot be resumed."
        let shown = names.prefix(5)
        if !shown.isEmpty {
            detail += "\n\n" + shown.map { "\u{2022} \($0)" }.joined(separator: "\n")
            if names.count > shown.count {
                detail += "\n\u{2022} and \(names.count - shown.count) more"
            }
        }
        alert.informativeText = detail

        alert.addButton(withTitle: "Quit anyway")
        alert.addButton(withTitle: "Keep working")
        // So Return keeps working rather than quitting: the destructive answer should cost a
        // deliberate click, not the key your hand is already on.
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""

        return alert.runModal() == .alertFirstButtonReturn
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    /// Without this, macOS silently swallows every banner while Baton is the frontmost app, and
    /// "frontmost, but looking at a different workspace" is precisely the case the suppression rule
    /// deliberately lets through. Whether to interrupt is Baton's decision and it has already been
    /// made by the time a request gets this far, so everything that arrives here is shown.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let workspaceID = NotificationService.workspaceID(from: response)
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
