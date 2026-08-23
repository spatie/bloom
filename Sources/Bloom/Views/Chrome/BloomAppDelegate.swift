import AppKit
import SwiftUI
import UserNotifications
import BloomCore

extension Notification.Name {
    /// Carries a `bloom://` URL from the Apple Event handler to whichever window is open.
    static let bloomHandleURL = Notification.Name("bloomHandleURL")
}

/// Bridges macOS lifecycle callbacks into the observation-driven app without introducing a second state owner.
@MainActor
final class BloomAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Handed over by `BloomApp` once the scene exists. Explicit rather than a global, because the
    /// delegate is only borrowing the state to tear it down, and nothing here should be able to
    /// reach into the app's state by any other route.
    private weak var appModel: AppModel?

    /// Set once the quit sequence starts, so a second Cmd+Q cannot begin a second teardown while
    /// the first one is still waiting on the escalations.
    private var isTerminating = false

    /// Kept alive here because `NSApp.servicesProvider` is an unowned reference.
    private let servicesProvider = BloomServicesProvider()

    /// Set by `SoftwareUpdater` once it has asked its own question about the running agents, so
    /// the quit confirmation below does not ask the same question a second time and leave
    /// Sparkle's installer waiting on an answer the user thought they had given.
    var isInstallingUpdate = false

    func attach(_ model: AppModel) {
        appModel = model
        // The switch probe drives a selection and reads back what the window settled on, so it
        // needs the state too, and this is the same one moment everything else is handed it. It
        // keeps a weak reference and only ever looks when `--switch-probe` asked it to.
        SwitchProbe.attach(model)
        servicesProvider.attach(model)
        // And a Shortcut needs it for the same reason the Services menu does: an intent runs in
        // this process and has to execute the same code a click in the create sheet does, rather
        // than a copy of it written for callers with no window.
        RunningApp.attach(model)
        // The suppression rule needs to know which workspace the window is showing, and this is
        // the first moment there is a window to ask.
        NotificationService.shared.attach(model)
        // The updater needs the same state, for one question: how many agents are mid turn. This
        // is also the first moment there is any, and it is deliberately after launching rather
        // than during it, so Sparkle's first scheduled check cannot land inside the launch.
        SoftwareUpdater.shared.start(app: model)
    }

    /// Claiming the URL Apple Event has to happen before launching finishes. If SwiftUI's own
    /// `onOpenURL` path handles a `bloom://` link instead, a WindowGroup opens a SECOND window
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
        // Guarded because merely asking for the centre aborts a process that is not a registered
        // bundle, which `swift run` and `.build/debug/Bloom` are not. See
        // `NotificationService.isAvailable` for the crash this line was.
        if NotificationService.isAvailable {
            UNUserNotificationCenter.current().delegate = self
            NotificationService.shared.registerCategories()
        }
        // The provider is retained by this delegate, which lives for the process. AppKit only
        // holds it weakly, and a provider that has been deallocated is a Services entry that
        // silently does nothing.
        NSApp.servicesProvider = servicesProvider
        // Tells macOS the app is here and what it offers, so the entry shows up in other apps'
        // Services menus without waiting for the periodic rescan.
        NSUpdateDynamicServices()

        // Last, and after the main window exists, so the welcome window opens in front of Bloom
        // rather than in front of nothing. Every capture and probe flag in `Snapshot` drives this
        // process from the outside and would be photographing a window it did not ask for, so a
        // run that is taking a picture of something else is left alone. See `WelcomeLaunch`.
        if !Snapshot.isDrivingTheWindow { WelcomeLaunch.presentIfNeeded() }
    }

    /// Required on macOS 14 and later. Without it AppKit logs "Secure coding is not enabled for
    /// restorable state" on every launch and quietly declines to restore the window. Bloom's
    /// restorable state is window geometry and split positions, none of which needs a legacy
    /// unarchiver.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }

        MainWindow.raise()
        NotificationCenter.default.post(name: .bloomHandleURL, object: url)
    }

    /// False, because Bloom runs agents. Closing the only window must never be a silent way to end
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
        if !isInstallingUpdate,
           let running = appModel?.runningAgentCount, running > 0,
           !confirmQuit(running: running) {
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

    /// The dock icon's menu. Only the workspaces with an agent actually running, because the dock
    /// is where somebody looks while Bloom is behind three other windows, and the question they
    /// have there is "is anything still going, and can I get to it". A full workspace list would
    /// be the sidebar, badly, in a place with no room for it.
    ///
    /// Nil when nothing is running, so macOS shows its own standard menu rather than an empty
    /// section above it.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let appModel else { return nil }
        let running = appModel.workspaces.filter(appModel.isRunning)
        guard !running.isEmpty else { return nil }

        let menu = NSMenu()
        for workspace in running {
            let item = NSMenuItem(
                title: workspace.name,
                action: #selector(openWorkspaceFromDock(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.represent(workspace.id)
            // The same glyph the sidebar uses for a running agent, so the two lists read as one
            // fact told twice rather than as two different states.
            item.image = NSImage(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "Agent running"
            )
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openWorkspaceFromDock(_ sender: NSMenuItem) {
        guard let id = sender.represented(WorkspaceID.self) else { return }
        MainWindow.raise()
        OpenWorkspaceNotification.post(id)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindow.raise()
        } else {
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }

    /// Without this, macOS silently swallows every banner while Bloom is the frontmost app, and
    /// "frontmost, but looking at a different workspace" is precisely the case the suppression rule
    /// deliberately lets through. Whether to interrupt is Bloom's decision and it has already been
    /// made by the time a request gets this far, so everything that arrives here is shown.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// A click, an Open, or a reply typed into the banner itself.
    ///
    /// The reply is the one branch that does not raise the window: the whole point of typing into
    /// a banner is to answer an agent without leaving the app you are in, and stealing focus to
    /// show the answer being sent undoes that. Everything else brings Bloom forward.
    ///
    /// The response is read here, before the hop, because it is delivered off the main actor and
    /// is not `Sendable`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let workspaceID = NotificationService.workspaceID(from: response)
        let reply = (response as? UNTextInputNotificationResponse)?.userText

        Task { @MainActor in
            if let reply, let workspaceID, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await NotificationService.shared.reply(reply, toWorkspace: workspaceID)
                completionHandler()
                return
            }

            MainWindow.raise()
            if let workspaceID {
                OpenWorkspaceNotification.post(workspaceID)
            }
            completionHandler()
        }
    }
}
