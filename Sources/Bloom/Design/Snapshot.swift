import SwiftUI
import AppKit
import BloomCore

/// Renders the app's own views to PNG files and exits.
///
/// This exists because screen recording is not always permitted, and a UI cannot be judged from
/// its source. `ImageRenderer` draws a SwiftUI view straight to a bitmap in process, with no
/// window and no screen capture, so the interface can be looked at from a terminal.
///
/// Two limits worth knowing. An `NSViewRepresentable` (the sidebar material, the terminal) does
/// not draw here, so those areas come out empty. And nothing asynchronous runs, so every scene
/// has to be handed state that is already loaded.
///
///     Bloom --snapshot /tmp/shots
@MainActor
enum Snapshot {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--snapshot")
    }

    private static var directory: String {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else {
            return NSTemporaryDirectory() + "bloom-shots"
        }
        return arguments[index + 1]
    }

    /// Refuses to capture anything against a database nobody named.
    ///
    /// Refused rather than trusted: every capture flag runs a full `bootstrap`, whose recovery
    /// writes (resetting running sessions, abandoning pending asks) belong nowhere near a real
    /// database, and none of the three is DEBUG-gated, so the installed binary run by hand with
    /// no environment used to aim them at the user's own store, possibly while the real app was
    /// mid-turn.
    ///
    /// Here rather than in `runAndExit`, where it was. `--snapshot` renders offscreen and was
    /// guarded; `--snapshot-window` and `--snapshot-gallery` boot the whole app and were not, so
    /// the two flags that do the MORE dangerous thing were the two that did it unguarded.
    static func refuseWithoutDatabase(flag: String) {
        guard ProcessInfo.processInfo.environment["BLOOM_DB_PATH"] == nil else { return }
        FileHandle.standardError.write(Data(
            "\(flag) captures against a database named by BLOOM_DB_PATH, and refuses to run without one.\n".utf8
        ))
        exit(1)
    }

    /// Refuses to capture from a binary that is older than the sources beside it.
    ///
    /// The companion to the refusal above, and it was bought the same way: by a capture that was
    /// believed. "Just a terminal" was merged, the picture taken to check it showed a footer with
    /// no such button, and the button had been in the source the whole time. `.build/debug/Bloom`
    /// was twenty minutes behind the commit. A PNG carries nothing that says which build made it,
    /// so a stale one is indistinguishable from a bug, and this one was read as a bug for hours.
    ///
    /// Agents share one `.build` here, so a binary behind the tree is the ordinary state. The
    /// verdict and the sentence are `CaptureFreshness`, in the core, where the suite holds them.
    ///
    /// Debug builds only, and only when the package that produced this binary is still beside it,
    /// which is `.build/<configuration>/Bloom` in a checkout and nothing at all in a shipped copy.
    static func refuseIfStale(flag: String) {
        #if DEBUG
        let verdict = CaptureFreshness.of(
            builtAt: lastBuildCompleted,
            newestSourceChangeAt: newestSourceChange
        )
        guard let refusal = verdict.refusal(flag: flag) else { return }
        FileHandle.standardError.write(Data((refusal + "\n").utf8))
        exit(1)
        #endif
    }

    /// When a build last finished, which is not the same question as when the executable was
    /// last written.
    ///
    /// Swift Package Manager decides what to rebuild by hashing content, so a file whose mtime
    /// moved but whose text did not leaves the executable untouched. Comparing sources against the
    /// executable alone therefore calls such a tree stale for ever, and no amount of `swift build`
    /// clears it, which is a refusal nobody could obey. The build record is stamped by every
    /// successful build, no-ops included, so it answers "has a build been run since that edit",
    /// which is the question actually being asked. The executable is still taken into account, for
    /// a tree whose record has been cleared out from under it.
    private static var lastBuildCompleted: Date? {
        let record = packageRoot.map { $0.appending(path: ".build/build.db") }
        return [modifiedAt(Bundle.main.executableURL), modifiedAt(record)].compactMap { $0 }.max()
    }

    /// The checkout this binary was built in, or nil when it was not built in one.
    ///
    /// Derived from the executable rather than from `#filePath`, which is the path of the machine
    /// that compiled the file and says nothing about where it is being run.
    private static var packageRoot: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        // .build/<configuration>/Bloom, so three levels up is the package.
        let root = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path)
        else { return nil }
        return root
    }

    /// When any Swift file under `Sources` was last written, or nil where there are none to read.
    ///
    /// `Sources` alone, not the tests: a test that changed does not change what the app draws, and
    /// a capture refused because somebody edited a suite would be a refusal nobody would keep.
    private static var newestSourceChange: Date? {
        guard let root = packageRoot else { return nil }
        let sources = root.appending(path: "Sources")
        guard let walk = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        var newest: Date?
        for case let url as URL in walk where url.pathExtension == "swift" {
            guard let changed = modifiedAt(url) else { continue }
            if newest.map({ changed > $0 }) ?? true { newest = changed }
        }
        return newest
    }

    private static func modifiedAt(_ url: URL?) -> Date? {
        try? url?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Blocks the main thread on purpose. This runs before any scene exists, and the process is
    /// going to exit at the end of it either way.
    static func runAndExit() -> Never {
        refuseWithoutDatabase(flag: "--snapshot")
        refuseIfStale(flag: "--snapshot")
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await render()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        exit(0)
    }

    // MARK: - Driving a window that is going to be filmed
    //
    // None of the four flags below photograph anything. They put the running app into the state
    // worth photographing, for a capture that is happening from outside this process, and they
    // landed under the window capture's MARK one at a time until it named none of them.

    /// Opens a `bloom://` URL in THIS process, a few seconds after launch.
    ///
    /// `open bloom://...` from a shell goes through LaunchServices, which picks whichever copy of
    /// the app it feels like and does not carry `BLOOM_DB_PATH`, so a test that drives a deep link
    /// that way can silently exercise a different instance against a different database. This
    /// posts the URL straight into the running process instead, so a repro is deterministic.
    ///
    ///     Bloom --open-url "bloom://prompt=...&path=..."
    static func scheduleURLIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--open-url"), index + 1 < arguments.count else {
            return
        }
        // Through `OpenURLArgument` rather than `URL(string:)` directly, which returned nil for
        // any prompt holding a space or a colon and dropped the link without a word. And when even
        // the repair cannot read it, say so: a harness that swallows its argument reads as the
        // deep link machinery being broken rather than the argument being malformed.
        guard let url = OpenURLArgument.url(from: arguments[index + 1]) else {
            FileHandle.standardError.write(
                Data("==> --open-url: not a URL, even repaired: \(arguments[index + 1])\n".utf8)
            )
            return
        }

        Task { @MainActor in
            // After `bootstrap`, or the repo list it needs is not loaded yet.
            try? await Task.sleep(for: .seconds(3))
            NotificationCenter.default.post(name: .bloomHandleURL, object: url)
        }
    }

    // There was a `forcesBusyPulse` here, which let `--running` lift the busy marks' frontmost
    // gate: anything that films this window is another process, so the window is not the front one
    // while it is being filmed, and the marks used to stop on the frame the recorder started.
    // There is no frontmost gate left to lift. See `BusyPulseDriver`.

    /// Unfolds the setup row's log in the transcript, the same way its link does.
    ///
    ///     Bloom --select w1 --expand-setup-log 8
    ///
    /// The same kind of affordance `--create-sheet` is, and it exists for the same reason. What
    /// that link does is motion: it jumps to the newest line of the log and then follows the
    /// script down. Judging that means filming the unfold as it happens, and the only other way
    /// to press the link is to drive the pointer across the user's own screen.
    ///
    /// Debug builds only. Nothing here lies about the app the way `--running` does, but a shipped
    /// copy has no business being able to open a row nobody clicked either.
    static func scheduleSetupLogExpansionIfRequested() {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--expand-setup-log"),
              index + 1 < arguments.count,
              let delay = Double(arguments[index + 1]) else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            NotificationCenter.default.post(name: .bloomExpandSetupLog, object: nil)
        }
        #endif
    }

    /// Creates the workspace the create sheet's terminal mode makes, so it can be photographed.
    ///
    ///     Bloom --terminal-workspace plumage
    ///
    /// Neither the mode nor Create can be reached by a capture run, and the workspace it produces
    /// is the whole
    /// of what there is to look at: which name the sidebar row wears when no model is ever going
    /// to be asked for one, which tab the column opens on when there is no session at all, and
    /// which directory the shell is standing in. Building a row by hand to photograph instead
    /// would be photographing the harness.
    ///
    /// Debug builds only, like `--running` and `--notice`, for the same reason: a shipped copy has
    /// no business cutting a worktree nobody asked for.
    static func scheduleTerminalWorkspaceIfRequested() {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--terminal-workspace") else { return }
        let project = index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--")
            ? arguments[index + 1]
            : nil

        Task { @MainActor in
            // After `bootstrap`, the beat `--open-url` waits for and for the same reason: the
            // project list this names is not loaded before it.
            try? await Task.sleep(for: .seconds(3))
            NotificationCenter.default.post(
                name: .bloomStartTerminalWorkspace, object: project
            )
        }
        #endif
    }

    /// Raises the corner notice, so it can be filmed.
    ///
    ///     Bloom --notice 4 "Bloom named this workspace X. Its branch is still `y`, because ..."
    ///
    /// The banner is a countdown with a draining bar in it, which is three things a still frame
    /// cannot show: that it goes on its own, how long it has left, and that the pointer stops it.
    /// Waiting for a real automatic rename to refuse a real branch is not a way to look at any of
    /// them. The message is passed in whole rather than composed here, so the run is filming the
    /// same sentence the core produces rather than a hand written approximation of it.
    ///
    /// Debug builds only, for the reason `--running` is: a shipped copy has no business claiming
    /// Bloom did something it did not do.
    static func scheduleNoticeIfRequested() {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--notice"),
              index + 1 < arguments.count,
              let delay = Double(arguments[index + 1]) else { return }
        let message = index + 2 < arguments.count && !arguments[index + 2].hasPrefix("--")
            ? arguments[index + 2]
            : "Bloom named this workspace Describe fade-in animation feel. Its branch is still "
                + "`freekmurze/iyo-sea`, because `freekmurze/fade-animation-feel` is already taken "
                + "by another branch."

        // `--notice-hold <after>,<for>` puts the countdown on hold and takes it off again, which
        // is what the pointer resting on the banner does. Filming the real thing would mean moving
        // the owner's cursor across the owner's screen while he is working, so this drives the
        // banner's own hold and release instead, through the same state the pointer sets.
        let hold = arguments.firstIndex(of: "--notice-hold")
            .flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            .map { $0.split(separator: ",").compactMap { Double($0) } }
            .flatMap { $0.count == 2 ? ($0[0], $0[1]) : nil }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            applyRequestedAppearance()
            NotificationCenter.default.post(name: .bloomShowNotice, object: message)

            guard let hold else { return }
            try? await Task.sleep(for: .seconds(hold.0))
            NotificationCenter.default.post(name: .bloomHoldNotice, object: true)
            try? await Task.sleep(for: .seconds(hold.1))
            NotificationCenter.default.post(name: .bloomHoldNotice, object: false)
        }
        #endif
    }

    /// Opens a workspace and tells the window that agents are working in some of them, then gets
    /// out of the way and lets the app go on running.
    ///
    ///     Bloom --select w1 --running w1,w2,w3
    ///     Bloom --select w1 --running w1,w2,w3/w1/
    ///
    /// Everything else in this file takes one picture and exits, which is enough for a layout and
    /// is nothing at all for the two busy signals: a single still cannot show motion, so those
    /// have to be watched on a window that stays up while frames are taken from outside it. This
    /// is what puts such a window into the state worth watching.
    ///
    /// `--running` is a debug build only affordance, and deliberately: it makes the window claim
    /// something about the user's agents that is not true, and a shipped copy has no business
    /// being able to say that. `--select` is honoured here as well as by the window capture, so
    /// the two flags can be given together to a run that is not capturing anything itself.
    ///
    static func scheduleRunningStateIfRequested() {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--running"), index + 1 < arguments.count
        else { return }

        // Stages, separated by `/`, six seconds apart. One stage is the ordinary case; several
        // are how a transition is filmed, and the last agent finishing is the transition that
        // matters most: `--running w1,w2,w3/w1/` runs three, then one, then none.
        let stages = arguments[index + 1]
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { Set($0.split(separator: ",").map { WorkspaceID(String($0)) }) }
        let selected = arguments.firstIndex(of: "--select").map { $0 + 1 }
            .flatMap { $0 < arguments.count ? arguments[$0] : nil }

        Task { @MainActor in
            // After `bootstrap`, the same beat `--open-url` waits for and for the same reason.
            try? await Task.sleep(for: .seconds(3))
            applyRequestedAppearance()
            if !isWindowCaptureRequested, let selected {
                OpenWorkspaceNotification.post(WorkspaceID(selected))
                try? await Task.sleep(for: .seconds(2))
            }
            // `--collapse-sidebar` folds the first column away, which is the case the row signal
            // cannot cover and the rule has to. It goes through the same notification the menu
            // item posts, so nothing about the window is being reached into.
            if arguments.contains("--collapse-sidebar") {
                NotificationCenter.default.post(name: .bloomToggleSidebar, object: nil)
                try? await Task.sleep(for: .seconds(1))
            }
            for (index, ids) in stages.enumerated() {
                if index > 0 { try? await Task.sleep(for: .seconds(6)) }
                NotificationCenter.default.post(name: .bloomCaptureRunning, object: ids)
            }
        }
        #endif
    }

    /// Sidebar width in points from `--sidebar-width`, or nil when the flag is absent.
    ///
    /// `--window-size` reproduces a cramped WINDOW, but the sidebar keeps its own width across
    /// that, so the two cases that matter for a sidebar row, the 200 point minimum a user can
    /// drag it to and the 420 point maximum, could not be captured at all. The value is clamped
    /// by the split view to the bounds `RootView` declares, so asking for something outside them
    /// captures the nearest width a user can actually reach.
    private static var requestedSidebarWidth: CGFloat? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--sidebar-width"), index + 1 < arguments.count,
              let width = Double(arguments[index + 1])
        else { return nil }

        return width
    }

    /// The outermost split view under `view`, which is the one whose first divider stands
    /// between the sidebar and everything else. Pre-order, so the sidebar's own ancestor is
    /// found before the detail column's inner split is ever looked at.
    private static func firstSplitView(under view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for subview in view.subviews {
            if let found = firstSplitView(under: subview) { return found }
        }
        return nil
    }

    /// `WIDTHxHEIGHT` in points, or nil when the flag is absent or malformed.
    ///
    /// The flag reading and the parse are both `ProbeHarness`'s, which is where the six probes
    /// read the same flag: this file inlined a fifth copy of a three line rule that now has a test
    /// in `ProbeStatsTests` rather than five readers who each believe it.
    private static var requestedWindowSize: CGSize? {
        ProbeHarness.value(for: "--window-size").flatMap(ProbeStats.windowSize)
    }

    /// True when this process was started to photograph or measure something rather than to be
    /// used.
    ///
    /// The welcome window is the reason this exists. It opens on first launch, and a capture run
    /// starts against an empty defaults domain by design, so every screenshot of the sidebar
    /// would have arrived with a welcome window sitting on top of it. Asked once, here, rather
    /// than by each flag remembering to say so.
    /// `--menu-probe` is named by its flag rather than through `MenuProbe.isRequested`, because
    /// that type is compiled into debug builds only and this property is not.
    ///
    /// **Every probe, not two of them.** This listed `FrameProbe` and `SwitchProbe` only, so a
    /// scroll, resize, tab or idle run on a machine that has not finished onboarding was met by
    /// the welcome window, which is ordered front and is therefore the window a probe attaches to.
    /// A run then reported "no transcript NSScrollView found" and looked like a broken transcript.
    static var isDrivingTheWindow: Bool {
        isRequested || isWindowCaptureRequested || isGalleryCaptureRequested
            || FrameProbe.isRequested || SwitchProbe.isRequested || ScrollProbe.isRequested
            || ResizeProbe.isRequested || TabProbe.isRequested
            || CommandLine.arguments.contains("--menu-probe")
    }

    static var isWindowCaptureRequested: Bool {
        CommandLine.arguments.contains("--snapshot-window")
    }

    private static var windowCapturePath: String {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-window"), index + 1 < arguments.count else {
            return NSTemporaryDirectory() + "bloom-window.png"
        }
        return arguments[index + 1]
    }

    /// Which Settings pane `--settings` opens on, from `--settings-tab models`.
    ///
    /// Nil in every launch that did not ask, which is every launch that is not a capture run, and
    /// nil again for a name no tab answers to. `SettingsView` reads it once when it builds.
    static var requestedSettingsTab: SettingsTab? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--settings-tab"), index + 1 < arguments.count else {
            return nil
        }
        return SettingsTab(rawValue: arguments[index + 1])
    }

    /// Which appearance to capture in, from `--appearance light|dark`.
    ///
    /// Nothing else forces one. The app follows the system unless the Settings window has been
    /// opened, so without this a capture run can only ever show whichever appearance the machine
    /// happens to be in, and half of every colour change goes unverified.
    private static var requestedAppearance: NSAppearance? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--appearance"), index + 1 < arguments.count
        else { return nil }

        return switch arguments[index + 1] {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    /// Forces the appearance `--appearance` named, if it named one.
    ///
    /// Shared by the window capture and by `scheduleRunningStateIfRequested`, because a run that
    /// is watched from outside has exactly the same problem as one that photographs itself: on a
    /// machine set to light, half of every colour decision goes unverified.
    static func applyRequestedAppearance() {
        guard let appearance = requestedAppearance else { return }
        NSApp.appearance = appearance
    }

    /// Captures the real window, rather than re-rendering views.
    ///
    /// `ImageRenderer` cannot draw a `List`, a `SettingsLink` or an `NSViewRepresentable`: it
    /// paints SwiftUI's yellow "unsupported" placeholder instead, which is useless for judging a
    /// sidebar built on `List`. Asking the window's own view hierarchy to draw itself into a
    /// bitmap goes through the real AppKit rendering path, so materials, toolbars and lists all
    /// come out as the user sees them, and it needs no screen recording permission.
    ///
    ///     Bloom --snapshot-window /tmp/shots/window.png [--window-size 900x700]
    ///           [--sidebar-width 200] [--appearance dark]
    ///
    /// Waits for the window to exist and settle, captures it, then exits.
    static func scheduleWindowCapture() {
        refuseWithoutDatabase(flag: "--snapshot-window")
        refuseIfStale(flag: "--snapshot-window")
        Task { @MainActor in
            let path = windowCapturePath
            applyRequestedAppearance()
            // Long enough for the first layout pass and any `.task` that populates the sidebar.
            try? await Task.sleep(for: .seconds(3))

            // Optionally open a workspace first, so the screen that matters (transcript, composer,
            // inspector) can be captured rather than only the home screen.
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--select"), index + 1 < arguments.count {
                OpenWorkspaceNotification.post(WorkspaceID(arguments[index + 1]))
                try? await Task.sleep(for: .seconds(3))
            }

            // `--archive` is gone with the screen it opened. What it photographed is two things
            // now: the archived workspaces are Home under its Archived chip, and what they cost
            // is `--settings --settings-tab storage`.

            // `--create-sheet` opens the New Workspace sheet and captures the sheet rather than
            // the window behind it. Without it that sheet could only be looked at by asking a
            // human for a screenshot, which is why it went years without one. Pass it LAST, for
            // the reason spelled out for `--settings` just below.
            let wantsCreateSheet = arguments.contains("--create-sheet")
            if wantsCreateSheet {
                NotificationCenter.default.post(name: .bloomNewWorkspace, object: nil)
                try? await Task.sleep(for: .seconds(2))
            }

            // `--project-setup <folder>` hands a folder to the same code path the file panel
            // does, so the offer to turn it into a repository can be looked at. It has to be
            // driven from here because the only other way in is an `NSOpenPanel`, and a modal
            // file panel cannot be answered by a capture run.
            var wantsProjectSetup = false
            if let index = arguments.firstIndex(of: "--project-setup"), index + 1 < arguments.count {
                wantsProjectSetup = true
                NotificationCenter.default.post(
                    name: .bloomOfferProjectSetup, object: arguments[index + 1]
                )
                try? await Task.sleep(for: .seconds(3))
            }

            // `--settings` captures the Settings window instead of the main one. Without it the
            // only way to look at a preferences pane was to ask a human for a screenshot, which
            // meant every change to that window went in unverified.
            //
            // Pass it LAST, after `--window-size`. `NSUserDefaults` claims every `-flag value`
            // pair on the command line for its argument domain, so a flag that takes no value
            // swallows the flag after it and the app starts with a preference nobody set. With
            // `--settings --window-size 900x1150` no window is ever created at all.
            let wantsSettings = arguments.contains("--settings")

            // `--repo-settings [project]` does the same for the PROJECT settings window, which is
            // a window group of its own and is otherwise reachable only through a menu item or the
            // gear on a project's row. Same caveat about flag order as above.
            let repoSettingsIndex = arguments.firstIndex(of: "--repo-settings")
            let wantsRepoSettings = repoSettingsIndex != nil
            let repoSettingsProject = repoSettingsIndex
                .map { $0 + 1 }
                .flatMap { $0 < arguments.count && !arguments[$0].hasPrefix("--") ? arguments[$0] : nil }

            // `--about` captures the About window, for the reason `--settings` captures the
            // settings one: it is reachable only through a menu item, so without this the only
            // way to look at it is to ask a human for a screenshot, and every change to it goes in
            // unverified. It is a designed window rather than AppKit's panel now, which makes both
            // appearances worth a picture. Same caveat about flag order as above.
            let wantsAbout = arguments.contains("--about")

            // And `--welcome` for the first run window, which is otherwise reachable only by
            // wiping a defaults domain or by a menu item. Same caveat about flag order as above.
            // `--setup-rehearsal <name>` decides what that window will have found; see
            // `SetupRehearsal`.
            let wantsWelcome = arguments.contains("--welcome")

            // Polled rather than slept through, and the settings action is re-sent each time round.
            // How long the first window takes depends on how much the store has to read, and a
            // fixed wait that is long enough on a small database is a coin toss on a real one.
            var candidate: NSWindow?
            for _ in 0..<40 {
                candidate = capturableWindows().first
                if candidate != nil { break }
                try? await Task.sleep(for: .milliseconds(250))
            }

            // "Whichever window is not the main one", identified by holding on to the main window
            // rather than by title. SwiftUI titles the settings window after whichever pane is
            // showing, and it titles the MAIN window after the selected workspace, so a title
            // comparison against "Bloom" matched neither and every settings capture silently
            // returned a picture of the main window instead.
            if wantsSettings || wantsRepoSettings || wantsAbout || wantsWelcome {
                let main = candidate
                candidate = nil
                for _ in 0..<40 {
                    candidate = capturableWindows().first { $0 !== main }
                    if candidate != nil { break }
                    if wantsRepoSettings {
                        NotificationCenter.default.post(
                            name: .bloomOpenRepoSettings, object: repoSettingsProject
                        )
                    } else if wantsAbout {
                        openAppMenuItem(titled: "About")
                    } else if wantsWelcome {
                        WelcomeWindow.show()
                    } else {
                        openSettingsWindow()
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }

            // The Help menu sheets and their thank-you cards, raised by
            // `FeedbackPresenter.presentIfRequested` rather than from here, but captured the
            // same way `--create-sheet` is: the sheet, not the window behind it.
            let wantsFeedbackSheet = [
                "--feedback-sheet", "--feedback-logs", "--feedback-problems", "--feedback-sent",
                "--prompt-sheet", "--prompt-problems", "--prompt-sent",
            ].contains(where: arguments.contains)

            // A sheet is its own window, hanging off the one it was presented from, and it is
            // never in `capturableWindows()`: it carries no title bar. Asked for by name here
            // rather than searched for, so nothing else on screen can be picked by mistake.
            if wantsCreateSheet || wantsProjectSetup || wantsFeedbackSheet {
                for _ in 0..<20 where candidate?.attachedSheet == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                candidate = candidate?.attachedSheet ?? candidate
            }

            // `--capture-delay <seconds>` holds the shutter open. Everything else here photographs
            // a window as soon as it exists, which is the right answer for a layout and the wrong
            // one for anything that settles: the welcome window's checks resolve over about a
            // second, so the default capture always caught it halfway. Two runs at two delays are
            // also the only way a still can say anything about motion.
            if let index = arguments.firstIndex(of: "--capture-delay"), index + 1 < arguments.count,
               let seconds = Double(arguments[index + 1]) {
                try? await Task.sleep(for: .seconds(seconds))
            }

            guard let window = candidate, let contentView = window.contentView else {
                FileHandle.standardError.write(Data("no window to capture\n".utf8))
                exit(1)
            }

            // The frame view above the content view, because the toolbar and the title bar live
            // there and not in the content view. Capturing the content view alone cropped off the
            // exact strip that a toolbar bug shows up in, which made every toolbar change
            // unverifiable without asking a human to take a screenshot.
            let content = contentView.superview ?? contentView

            // A capture at one comfortable width proves nothing about the width the user actually
            // drags a pane down to. `--window-size 900x700` reproduces the cramped case on demand,
            // which is how the inspector's clipped header was found in the first place.
            if let size = requestedWindowSize {
                window.setContentSize(size)
                window.layoutIfNeeded()
                // Two seconds, not one. A resize walks a SwiftUI `NavigationSplitView`, an AppKit
                // split controller and two hosting views, and a capture taken while that is still
                // settling showed a sidebar whose rows had slid out of their own column: a
                // transient that reads exactly like a layout bug and cost an hour to disbelieve.
                try? await Task.sleep(for: .seconds(2))
                window.layoutIfNeeded()
                window.displayIfNeeded()
            }

            // After the window resize, because a resize renegotiates the columns and would undo
            // a divider that had already been placed.
            if let sidebarWidth = requestedSidebarWidth, let split = firstSplitView(under: content) {
                split.setPosition(sidebarWidth, ofDividerAt: 0)
                // The same settling wait the resize above needs, for the same measured reason.
                try? await Task.sleep(for: .seconds(2))
                window.layoutIfNeeded()
                window.displayIfNeeded()
            }

            // The window server holds the only complete picture of this window.
            //
            // Drawing the hierarchy in process cannot be trusted here. `cacheDisplay` misses
            // anything whose content lives in a layer rather than in `draw(_:)`, and
            // `layer.render(in:)` misses whole AppKit view-controller hierarchies: with the
            // sidebar and the detail held by an `NSSplitViewController` it captured a blank
            // sidebar while instrumentation proved the layout was correct. A capture that is
            // wrong in exactly the areas that changed most is worse than no capture, so this
            // asks the window server for the composited window instead.
            //
            // `-l` names one window by number, so nothing else on the desktop is ever in the
            // file; `-o` drops the drop shadow; `-x` keeps it silent.
            if captureWindowServerImage(windowNumber: window.windowNumber, to: path) {
                print(path)
                exit(0)
            }

            // Screen recording is not granted to every run. Rather than exit with nothing, fall
            // back to the in-process draw and say plainly that the result is partial.
            FileHandle.standardError.write(Data(
                "screencapture failed; falling back to an in-process draw, which omits AppKit panes\n".utf8
            ))
            let bounds = content.bounds
            guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
                FileHandle.standardError.write(Data("could not allocate a bitmap\n".utf8))
                exit(1)
            }
            if let layer = content.layer, let context = NSGraphicsContext(bitmapImageRep: rep) {
                // Only a flipped view's layer needs the context flipped. SwiftUI's hosting view
                // is flipped, the window's frame view above it is not, so flipping
                // unconditionally captured the title bar upside down.
                context.cgContext.saveGState()
                if content.isFlipped {
                    context.cgContext.translateBy(x: 0, y: bounds.height)
                    context.cgContext.scaleBy(x: 1, y: -1)
                }
                layer.render(in: context.cgContext)
                context.cgContext.restoreGState()
                context.flushGraphics()
            } else {
                content.cacheDisplay(in: bounds, to: rep)
            }

            guard let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("could not encode the bitmap\n".utf8))
                exit(1)
            }
            try? png.write(to: URL(fileURLWithPath: path))
            print(path)
            exit(0)
        }
    }

    // MARK: - Gallery capture

    /// Photographs a design gallery in a window of its own.
    ///
    ///     Bloom --snapshot-gallery /tmp/shots [--gallery review-comments|inspector-tabs|diff-scope]
    ///
    /// `--snapshot` cannot photograph this one. `ImageRenderer` paints SwiftUI's yellow
    /// "unsupported" placeholder wherever an `NSViewRepresentable` sits, and the box a review
    /// comment is written in is one: it is the composer's own text view, which is what lets
    /// Shift+Return insert a line break the text system can undo. Rendered offscreen, the gallery
    /// that exists to show that box came out as a yellow bar with a red circle on it, and the two
    /// states worth reviewing (a comment being written across two lines, and one being rewritten)
    /// were exactly the two the picture could not show.
    ///
    /// So the gallery gets a real window and the window server is asked for it, the same way
    /// `--snapshot-window` asks for the app's own. The window is made by this process, ordered
    /// front by this process and captured by number, so nothing else on the desktop can reach the
    /// file.
    static var isGalleryCaptureRequested: Bool {
        CommandLine.arguments.contains("--snapshot-gallery")
    }

    static func scheduleGalleryCapture() {
        refuseWithoutDatabase(flag: "--snapshot-gallery")
        refuseIfStale(flag: "--snapshot-gallery")
        let arguments = CommandLine.arguments
        // Said rather than swallowed. `--snapshot` and `--snapshot-window` each fall back to a
        // path under the temporary directory; this one used to return here and let the app carry
        // on launching, so a run that captured nothing looked exactly like a run that worked.
        guard let index = arguments.firstIndex(of: "--snapshot-gallery"),
              index + 1 < arguments.count else {
            FileHandle.standardError.write(Data(
                "--snapshot-gallery needs a directory to write into.\n".utf8
            ))
            exit(1)
        }
        let output = arguments[index + 1]
        // The registry, not a switch. See `Gallery`: nine cases across four parallel switches in
        // this file is what a page used to cost to add, and what five agents conflicted over in a
        // day.
        let index2 = arguments.firstIndex(of: "--gallery").map { $0 + 1 }
        let named = index2.flatMap { $0 < arguments.count ? arguments[$0] : nil }
        let choice = Snapshot.gallery(named: named)

        Task { @MainActor in
            try? FileManager.default.createDirectory(
                atPath: output, withIntermediateDirectories: true
            )
            // Long enough for the app's own window to have finished opening, so the two are not
            // laying themselves out at the same moment.
            try? await Task.sleep(for: .seconds(3))

            // Owned here, for the whole run: a `WorkspaceModel` holds its `AppModel` unowned, so
            // the tab strip's fixtures need something with a longer life than a `body`.
            let app = AppModel()
            let size = choice.size
            for name in ["light", "dark"] {
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                window.title = choice.title
                window.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
                window.contentView = NSHostingView(
                    rootView: choice.view(app)
                        .frame(width: size.width, height: size.height)
                        .background(Palette.windowBackground)
                )
                window.center()
                if choice.needsFocus {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    window.orderFrontRegardless()
                }
                // A hosting view lays out, the text view measures its own wrapped height and
                // reports it back, and the box grows on the pass after that. Captured sooner, a
                // two-line comment was photographed in a one-line box.
                try? await Task.sleep(for: .seconds(2))

                let path = "\(output)/\(choice.name)-\(name).png"
                if captureWindowServerImage(windowNumber: window.windowNumber, to: path) {
                    print(path)
                } else {
                    FileHandle.standardError.write(Data(
                        "screencapture failed for \(path); screen recording may not be granted\n".utf8
                    ))
                }
                window.orderOut(nil)
            }
            exit(0)
        }
    }

    /// Asks the window server for one window, by number, as a PNG on disk.
    ///
    /// Returns false when the file did not appear, which is what a run without screen recording
    /// permission looks like. Nothing here can ever capture another application: `-l` takes a
    /// single window number and the file is written straight to `path`.
    private static func captureWindowServerImage(windowNumber: Int, to path: String) -> Bool {
        try? FileManager.default.removeItem(atPath: path)

        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-o", "-x", "-l\(windowNumber)", path]
        do {
            try capture.run()
        } catch {
            return false
        }
        capture.waitUntilExit()

        guard capture.terminationStatus == 0 else { return false }
        // screencapture reports success and writes nothing when the window number is stale.
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        return size > 0
    }

    /// The windows a capture may be pointed at: this app's own titled windows.
    ///
    /// Filtered rather than taken as they come. A process holds more windows than it opened: the
    /// system attaches a borderless child window to a focused text view, and `screencapture -l`
    /// on a child returns its PARENT's image, so a settings run that picked one silently produced
    /// another picture of the main window.
    @MainActor
    private static func capturableWindows() -> [NSWindow] {
        NSApp.windows.filter {
            $0.isVisible && $0.contentView != nil && $0.parent == nil
                && $0.styleMask.contains(.titled)
        }
    }

    /// Opens the `Settings` scene from outside a view.
    ///
    /// `NSApp.sendAction(Selector(("showSettingsWindow:")))` is the answer usually given for this
    /// and it does nothing here: SwiftUI installs the action on the menu item rather than on the
    /// responder chain. Driving the menu item itself is what actually opens the window.
    private static func openSettingsWindow() {
        // Matched by prefix because the item is titled "Settings…" with an ellipsis.
        openAppMenuItem(titled: "Settings")
    }

    /// Picks an item off the application menu by the start of its title.
    ///
    /// The menu item is driven rather than its action sent, for the reason above, and the About
    /// item is in the same position: `BloomCommands` replaces the `.appInfo` group, so the action
    /// behind it is a SwiftUI `Button` closure and lives nowhere the responder chain can reach.
    private static func openAppMenuItem(titled prefix: String) {
        NSApp.activate(ignoringOtherApps: true)
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        guard let index = appMenu.items.firstIndex(where: { $0.title.hasPrefix(prefix) })
        else { return }
        appMenu.performActionForItem(at: index)
    }

    private static func render() async {
        let output = directory
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

        let model = await seededModel()

        // The limits panel is drawn from a real ask rather than from made up rows. It is the one
        // scene here whose whole point is what a CLI actually answered, and a picture of invented
        // percentages would be a picture of nothing. A machine with neither CLI installed renders
        // the panel's own empty state, which is also worth a photograph.
        let board = QuotaBoard.make(from: await AgentQuotaSources.readAll())

        let scenes: [(String, AnyView, CGSize)] = [
            ("sidebar", AnyView(SidebarView().frame(width: 260, height: 620)), CGSize(width: 260, height: 620)),
            ("home", AnyView(HomeView().frame(width: 900, height: 620)), CGSize(width: 900, height: 620)),
            ("components", AnyView(ComponentGallery().frame(width: 640, height: 700)), CGSize(width: 640, height: 700)),
            ("permission", AnyView(PermissionSnapshotGallery().frame(width: 720, height: 1560)), CGSize(width: 720, height: 1560)),
            ("tool-rows", AnyView(ToolRowSnapshotGallery().frame(width: 800, height: 1_020)), CGSize(width: 800, height: 1_020)),
            // Offscreen rather than through a window: no `CheckRunRow` holds a representable, so
            // `ImageRenderer` draws the real column here.
            ("check-runs", AnyView(CheckRunSnapshotGallery()), CGSize(width: 420, height: 1000)),
            // Offscreen as well as through the window path, which the two pages above cannot be:
            // the one representable on this page draws a plain shape when it is held still,
            // precisely so this scene is a photograph of the row rather than of a placeholder.
            ("retries", AnyView(RetrySnapshotGallery().frame(width: 860, height: 1020)), CGSize(width: 860, height: 1020)),
            // The running mark, for the same reason and with the same limit: what comes out here
            // is the mark held still, because the heartbeat needs a window and there is none. That
            // is worth a photograph anyway, since it is exactly what Reduce Motion draws, and it
            // is the only picture of this mark an agent can take without asking to film the
            // owner's screen. The moving figure is `--snapshot-gallery --gallery running-glyph`.
            //
            // Named `running-glyph-still` and not `running-glyph`, because both of those write
            // into a directory the caller names and a run that points the two flags at one
            // directory would have had the second silently replace the first. That already
            // happened once on this page's neighbour: see the note above about a photograph being
            // overwritten by a yellow bar. Here neither picture is wrong, which is worse, because
            // nothing about the file would say which one it is.
            ("running-glyph-still", AnyView(RunningGlyphGallery()), Gallery.runningGlyph.size),
            // The activity rule, on the same terms and for a better reason than most: the still
            // figure is the point of that page rather than a consolation. It is what `Reduce
            // Motion` draws, and the claim being made about it is that a crest parked at the
            // trailing edge still says which way the line is running, which is a claim a
            // photograph can settle. The moving rows come out as yellow placeholders here; they
            // are what `--snapshot-gallery --gallery activity-rule` is for.
            ("activity-rule-still", AnyView(ActivityRuleGallery()), Gallery.activityRule.size),
            // No review-comments and no inspector-tabs scene, deliberately, and for one reason:
            // `ImageRenderer` paints SwiftUI's yellow placeholder over an `NSViewRepresentable`,
            // and each of those two pages exists to show one. The review comment box is the
            // composer's own text view and the inspector's strip is an `NSSegmentedControl`, so
            // offscreen both come out as a yellow bar. They are captured as real windows instead:
            // `--snapshot-gallery <dir> --gallery review-comments|inspector-tabs`.
            //
            // review-comments was in this list as well until tonight, which was worse than
            // useless: the two paths write the same `review-comments-<appearance>.png` into the
            // same directory, so whichever ran second replaced a real photograph with a yellow
            // bar, and they disagreed about the width while doing it (800 here, 820 there).

            // On the menu's own ground rather than the window's, because every colour in this
            // panel is an AppKit semantic one chosen to sit on a menu. See `QuotaPanel`.
            (
                "limits",
                AnyView(
                    QuotaPanel(board: board, freshness: QuotaFreshness.of(board))
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .windowBackgroundColor))
                ),
                CGSize(width: QuotaPanel.width + 43, height: 300)
            ),
            // And the states a real ask cannot produce on the machine this runs on: a window
            // nobody measured, a provider absent, extra usage switched on, a window past its wall.
            // Invented rather than measured, and that is the difference from the scene above: this
            // one is a photograph of the drawing rather than of an account, and it exists because
            // "photograph every state" is not a thing one account can be asked to be.
            (
                "limits-states",
                AnyView(
                    LimitsStateGallery()
                        .background(Color(nsColor: .windowBackgroundColor))
                ),
                CGSize(width: QuotaPanel.width + 43, height: 1500)
            ),
        ]

        for appearanceName in ["light", "dark"] {
            let appearance = NSAppearance(named: appearanceName == "dark" ? .darkAqua : .aqua)!
            NSApp?.appearance = appearance

            for (name, view, size) in scenes {
                // Semantic NSColors resolve against whatever appearance is current while drawing,
                // so the whole render has to happen inside this block.
                var rendered: Data?
                appearance.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(
                    content: view
                        .environment(model)
                        .environment(\.colorScheme, appearanceName == "dark" ? .dark : .light)
                        .frame(width: size.width, height: size.height)
                        .background(Palette.windowBackground)
                )
                renderer.scale = 2

                if let image = renderer.nsImage,
                   let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff) {
                    rendered = bitmap.representation(using: .png, properties: [:])
                }
                }

                guard let png = rendered else {
                    FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
                    continue
                }
                let path = "\(output)/\(name)-\(appearanceName).png"
                try? png.write(to: URL(fileURLWithPath: path))
                print(path)
            }
        }
    }

    /// A model holding enough to make the views show something. `runAndExit` has already refused
    /// to start without `BLOOM_DB_PATH`, so the `bootstrap` here can never touch the user's real
    /// workspaces.
    private static func seededModel() async -> AppModel {
        let model = AppModel()
        await model.bootstrap()
        return model
    }
}

/// Every shared control on one page, which is the fastest way to see whether the design system
/// is coherent rather than checking one screen at a time.
private struct ComponentGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Text") {
                Text("Title, semibold body").font(Typo.title)
                Text("Body, the default reading size").font(Typo.body)
                Text("Label, one step down").font(Typo.label).foregroundStyle(Palette.textSecondary)
                Text("Caption, for metadata").font(Typo.caption).foregroundStyle(Palette.textTertiary)
                Text("let code = \"monospaced\"").font(Typo.code)
            }

            group("Chips and stats") {
                HStack(spacing: 6) {
                    Chip(text: "Read", systemImage: "doc.text")
                    Chip(text: "Ticket.php", monospaced: true)
                    Chip(text: "opus", systemImage: "sparkle", tint: Palette.accent)
                    DiffStatLabel(additions: 118, deletions: 4)
                    DiffStatLabel(additions: 2_800, deletions: 608)
                }
            }

            group("Rows") {
                VStack(spacing: 2) {
                    galleryRow("Selected row", selected: true, hovered: false)
                    galleryRow("Hovered row", selected: false, hovered: true)
                    galleryRow("Plain row", selected: false, hovered: false)
                }
            }

            group("Buttons") {
                HStack(spacing: 8) {
                    Button("Primary") {}.buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Secondary") {}.buttonStyle(.bordered).controlSize(.large)
                    Button("Borderless") {}.buttonStyle(.borderless)
                }
            }

            group("State") {
                HStack(spacing: 14) {
                    HStack(spacing: 5) { ActivityDot(isActive: true); Text("Running").font(Typo.label) }
                    HStack(spacing: 5) { ActivityDot(isActive: false); Text("Idle").font(Typo.label) }
                    Text("Positive").font(Typo.label).foregroundStyle(Palette.positive)
                    Text("Negative").font(Typo.label).foregroundStyle(Palette.negative)
                    Text("Warning").font(Typo.label).foregroundStyle(Palette.warning)
                }
            }

            group("Diff tints") {
                VStack(spacing: 0) {
                    Text("+    let added = true")
                        .font(Typo.code)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                        .background(Palette.diffAddBackground)
                    Text("-    let removed = false")
                        .font(Typo.code)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                        .background(Palette.diffDeleteBackground)
                }
            }

            Spacer()
        }
        .padding(20)
        .background(Palette.surface)
    }

    private func galleryRow(_ title: String, selected: Bool, hovered: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch").font(Typo.caption)
            Text(title).font(Typo.body)
            Spacer()
            DiffStatLabel(additions: 12, deletions: 3)
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.rowHeight)
        .rowBackground(isSelected: selected, isHovered: hovered)
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Typo.micro)
                .foregroundStyle(Palette.textTertiary)
            content()
        }
    }
}

extension Notification.Name {
    /// Carries a `Set<WorkspaceID>` of the workspaces a capture run wants the window to believe
    /// are mid turn. Typed rather than a set of strings, because a notification's object is `Any?`
    /// and an id that crosses one as a string is an id nothing checks: see
    /// `OpenWorkspaceNotification`, which is that mistake as it was actually made.
    ///
    /// Posted only by `Snapshot.scheduleRunningStateIfRequested`, and only in a debug build. See
    /// `View.acceptsCaptureRunningState`.
    static let bloomCaptureRunning = Notification.Name("bloom.captureRunning")

    /// Asks the setup row to unfold its log. Posted only by
    /// `Snapshot.scheduleSetupLogExpansionIfRequested`, and only in a debug build. See
    /// `View.acceptsCaptureSetupLogExpansion`.
    static let bloomExpandSetupLog = Notification.Name("bloom.expandSetupLog")

    /// Carries the sentence a capture run wants in the corner notice. Posted only by
    /// `Snapshot.scheduleNoticeIfRequested`, and only in a debug build. See
    /// `View.acceptsCaptureNotice`.
    static let bloomShowNotice = Notification.Name("bloom.showNotice")

    /// Carries a `Bool` saying whether the corner notice's countdown is on hold. Posted only by
    /// `Snapshot.scheduleNoticeIfRequested`, and only in a debug build. See
    /// `View.acceptsCaptureNoticeHold`.
    static let bloomHoldNotice = Notification.Name("bloom.holdNotice")
}

extension View {
    /// Lets a debug build be told which agents to pretend are running.
    ///
    /// This is the only way the two busy signals can be looked at without starting real agents,
    /// and they are motion, so looking at them is the only way to judge them. It writes through
    /// `AppModel`'s own set rather than adding a flag beside it, so what a capture run sees is
    /// what a real turn produces, down to the same invalidations reaching the same readers.
    ///
    /// Compiled out of a release build entirely. `AppModel.setRunningWorkspaceIDsForCapture` does
    /// not exist there.
    func acceptsCaptureRunningState(_ app: AppModel) -> some View {
        #if DEBUG
        return onReceive(NotificationCenter.default.publisher(for: .bloomCaptureRunning)) { note in
            guard let ids = note.object as? Set<WorkspaceID> else { return }
            app.setRunningWorkspaceIDsForCapture(ids)
        }
        #else
        return self
        #endif
    }

    /// Lets a debug build unfold the setup log for a camera.
    ///
    /// It runs the row's own toggle rather than setting a flag beside it, so what is filmed is
    /// exactly what pressing "Show more of the log" produces, jump and all. Compiled out of a
    /// release build entirely, along with the subscription itself: a transcript row must not pay
    /// for a notification nothing in a shipped copy ever posts.
    func acceptsCaptureSetupLogExpansion(_ expand: @escaping @MainActor () -> Void) -> some View {
        #if DEBUG
        return onReceive(NotificationCenter.default.publisher(for: .bloomExpandSetupLog)) { _ in
            expand()
        }
        #else
        return self
        #endif
    }

    /// Lets a debug build put a notice in the corner for a camera.
    ///
    /// It goes through `AppModel.notice`, the one slot every real notice is written to, so what is
    /// filmed is the banner exactly as a real automatic rename raises it: same reading time, same
    /// drain, same replacement rule. Compiled out of a release build entirely.
    func acceptsCaptureNotice(_ app: AppModel) -> some View {
        #if DEBUG
        return onReceive(NotificationCenter.default.publisher(for: .bloomShowNotice)) { note in
            guard let message = note.object as? String else { return }
            app.notice = BloomNotice(message: message)
        }
        #else
        return self
        #endif
    }

    /// Lets a debug build put the corner notice's countdown on hold for a camera.
    ///
    /// It sets the same state the pointer sets, so the pause, the banked time and the resume are
    /// the ones a real hover produces. It exists because the alternative is warping the owner's
    /// cursor across the owner's screen while he is working in the app next door.
    func acceptsCaptureNoticeHold(_ hold: @escaping @MainActor (Bool) -> Void) -> some View {
        #if DEBUG
        return onReceive(NotificationCenter.default.publisher(for: .bloomHoldNotice)) { note in
            guard let held = note.object as? Bool else { return }
            hold(held)
        }
        #else
        return self
        #endif
    }
}

/// Every state of the limits panel, on a menu's own ground, one under the other.
///
/// The boards are built by hand because the point is the drawing rather than the account: the
/// machine this renders on has one plan, one set of windows and no extra usage, so four of the
/// six states below cannot be asked for. The `limits` scene beside this one is the real ask and
/// stays that way.
private struct LimitsStateGallery: View {
    /// A fixed instant, so every countdown in the capture is the same countdown next week.
    private static let now = Date(timeIntervalSince1970: 1_787_500_000)
    private static let week: TimeInterval = 604_800

    private static func quota(
        _ provider: AgentKind,
        _ window: QuotaWindow,
        _ used: Double?,
        after resets: TimeInterval?
    ) -> AgentQuota {
        AgentQuota(
            provider: provider,
            window: window,
            measure: used.map { .fraction($0) } ?? .unknown,
            resetsAt: resets.map { now.addingTimeInterval($0) },
            observedAt: now
        )
    }

    private static let scenes: [(String, [AgentQuota], QuotaFreshness)] = [
        ("Quiet", [
            quota(.claudeCode, .named("five_hour"), 0.12, after: 15_600),
            quota(.claudeCode, .named("seven_day"), 0.09, after: week * 0.85),
            quota(.codex, .lasting(week, key: "primary"), 0.03, after: week * 0.7),
        ], .current),
        ("The ramp, and the owner's own figures", [
            quota(.claudeCode, .named("five_hour"), 0.04, after: 3900),
            quota(.claudeCode, .named("seven_day"), 0.60, after: week * 0.535),
            quota(
                .claudeCode,
                QuotaWindow(key: "seven_day_model_fable", label: "Week (Fable)", duration: week),
                0.71,
                after: week * 0.535
            ),
            quota(.codex, .lasting(week, key: "primary"), 0, after: week * 0.9),
        ], .current),
        ("Nobody measured the session window", [
            quota(.claudeCode, .named("five_hour"), nil, after: 9600),
            quota(.claudeCode, .named("seven_day"), 0.44, after: week * 0.6),
            quota(.codex, .lasting(week, key: "primary"), 0, after: week * 0.9),
        ], .current),
        ("Codex absent, and one window spent", [
            quota(.claudeCode, .named("five_hour"), 1, after: 2900),
            quota(.claudeCode, .named("seven_day"), 0.88, after: week * 0.3),
        ], .stale(11_000)),
        ("Model scoped rows and extra usage, both present", [
            quota(.claudeCode, .named("five_hour"), 0.22, after: 7900),
            quota(.claudeCode, .named("seven_day"), 0.66, after: week * 0.6),
            quota(
                .claudeCode,
                QuotaWindow(key: "seven_day_model_opus", label: "Week (Opus)", duration: week),
                0.93,
                after: week * 0.6
            ),
            AgentQuota(
                provider: .claudeCode,
                window: QuotaWindow(key: "extra_usage", label: "Extra usage"),
                measure: .counted(used: 17.2, limit: 50, unit: "USD"),
                resetsAt: nil,
                observedAt: now
            ),
            quota(.codex, .lasting(week, key: "primary"), 0.58, after: week * 0.45),
        ], .current),
        ("Nothing reported at all", [], .current),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.scenes.enumerated()), id: \.offset) { _, scene in
                Text(scene.0)
                    .font(Font(NSFont.menuFont(ofSize: 0)).weight(.semibold))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .padding(.leading, 29)
                    .padding(.top, 20)
                    .padding(.bottom, 6)
                QuotaPanel(
                    board: QuotaBoard.make(from: scene.1, at: Self.now),
                    freshness: scene.2,
                    now: Self.now
                )
            }
        }
        .padding(.bottom, 20)
    }
}
