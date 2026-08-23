import AppKit
import SwiftUI
import BloomCore

/// The window Bloom opens the first time it is run, and the one the Help menu opens on demand.
///
/// The premise it is built on: the person who has just downloaded Bloom almost certainly already
/// runs Claude Code, because that is why they went looking for an app that runs Claude Code in
/// worktrees. So the common case is that nothing is wrong, and a window that opened onto a
/// checklist would be interrogating somebody who passed. It is a welcome that happens to check,
/// not a check with a welcome painted on it: the plinth, the mark and the wordmark are the About
/// window's, which are the site's, and the four rows underneath settle into ticks in about a
/// second and say so.
///
/// For the person who IS missing something it has to be the other thing, and the same window is
/// both. What changes is only the rows: a row that needs attention opens into the sentence saying
/// why Bloom wants the tool and the exact command that installs it, with a copy button, and the
/// two commands that ask questions back get a real terminal inside this window rather than a
/// sentence telling somebody to go and open Terminal. That is `GitHubSignInSheet`'s pattern, and
/// it was right there for the same reason.
///
/// One instance, kept here, and `isReleasedWhenClosed` off, for the reason `AboutWindow` documents.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?
    private static var inspection: SetupInspection?

    /// Opens it, or brings the one already open forward and looks again.
    ///
    /// Looking again on a second visit is the point of the menu item: somebody who came back to
    /// this window came back because they changed something.
    static func show() {
        let existing = window ?? make()
        window = existing
        existing.makeKeyAndOrderFront(nil)
        NSApp.activate()
        inspection?.start()
    }

    static func close() {
        window?.close()
    }

    private static func make() -> NSWindow {
        let model = SetupInspection(rehearsal: SetupRehearsal.report)
        inspection = model

        let host = NSHostingView(rootView: WelcomeView(inspection: model, onFinish: { close() }))
        // The window grows and shrinks as rows open and close, so the hosting view drives its
        // size rather than a number written down here.
        host.sizingOptions = [.preferredContentSize]
        let size = host.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            // No `.resizable`: this is a column of fixed width whose height follows its content,
            // and a drag handle on it would only ever produce a worse version of it.
            // `.fullSizeContentView` is what lets the plinth run up behind the title bar, the
            // alternative being a strip of flat window background above the gradient.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Bloom"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = host
        window.setContentSize(size)
        window.center()
        return window
    }
}

// MARK: - Whether it opens on its own

/// The launch decision, and the one flag behind it.
///
/// The rule itself is `OnboardingGate` in the core, with tests. This is the half that cannot be
/// tested because it is `UserDefaults` and a window: read the flag, and on a machine that has been
/// here before, probe quietly and open nothing unless the machine has actually stopped working.
@MainActor
enum WelcomeLaunch {
    /// Opens the window if this launch is one that should see it.
    ///
    /// A first launch opens it immediately, before any probe has finished, because the settling is
    /// the thing worth seeing and a window that waited for its own checks would open onto the
    /// answer. Every later launch waits for the verdict and stays shut unless it is `.blocked`.
    static func presentIfNeeded() {
        let completed = UserDefaults.standard.bool(forKey: OnboardingGate.completedKey)
        if OnboardingGate.trigger(hasCompletedBefore: completed, verdict: nil) == .firstRun {
            WelcomeWindow.show()
            return
        }

        Task {
            // Nothing is drawn for this, so it can take as long as four CLIs take. If the machine
            // is fine, which it nearly always is, the user never learns this happened.
            let report = await SetupProbe().report()
            guard OnboardingGate.trigger(hasCompletedBefore: true, verdict: report.verdict) == .blocked
            else { return }
            WelcomeWindow.show()
        }
    }

    /// Remembered only when somebody presses the primary button, not when the window is closed.
    /// Closing a window is how you get it out of the way; it is not how you say you are done with
    /// it, and a machine that is missing an agent should still be met by this window tomorrow.
    static func recordCompletion() {
        UserDefaults.standard.set(true, forKey: OnboardingGate.completedKey)
    }
}

// MARK: - Rehearsal

/// A report handed to the window instead of one gathered from this Mac. Debug builds only.
///
/// The missing-tool states cannot be looked at on a machine that has every tool, and the only
/// other ways to see them are to uninstall something or to point the agent overrides at a path
/// that does not exist, which covers two of the four rows and none of the GitHub ones. So the
/// detection INPUT can be supplied on the command line:
///
///     Bloom --setup-rehearsal signed-out-github
///
/// Debug only, and deliberately, for the reason `Snapshot.forcesBusyPulse` is: this makes the
/// window say something about the machine that is not true, and a shipped copy has no business
/// being able to say that.
enum SetupRehearsal {
    static var report: SetupReport? {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--setup-rehearsal"), index + 1 < arguments.count
        else { return nil }
        return named(arguments[index + 1])
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static func named(_ name: String) -> SetupReport? {
        switch name {
        case "all-clear":
            return make()
        case "signed-out-github":
            return make(gitHub: .needsSignIn(detail: nil))
        case "no-github":
            return make(gitHub: .missing)
        case "no-codex":
            return make(codex: .missing)
        case "signed-out-claude":
            return make(claude: .needsSignIn(detail: "2.1.234"), codex: .missing)
        case "no-agent":
            return make(claude: .missing, codex: .missing, gitHub: .missing)
        case "no-git":
            return make(git: .missing)
        default:
            return nil
        }
    }

    private static func make(
        git: SetupOutcome = .ready(detail: "2.51.0"),
        claude: SetupOutcome = .ready(detail: "freek@spatie.be"),
        codex: SetupOutcome = .ready(detail: "freek@spatie.be"),
        gitHub: SetupOutcome = .ready(detail: "Signed in")
    ) -> SetupReport {
        SetupReport(checks: [
            SetupCheck(tool: .git, outcome: git),
            SetupCheck(tool: .claudeCode, outcome: claude),
            SetupCheck(tool: .codex, outcome: codex),
            SetupCheck(tool: .gitHub, outcome: gitHub),
        ])
    }
    #endif
}
