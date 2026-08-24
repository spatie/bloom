import AppKit
import Observation
import Sparkle
import BloomCore

/// Bloom's half of Sparkle: when it may look for a new version, and what has to be true before it
/// is allowed to restart the app.
///
/// A shared object rather than something a view owns, for the same reason `MenuBarStatusItem` is
/// one: three surfaces reach it (the app menu's item, the Settings switch, and the delegate
/// callbacks Sparkle makes from its own windows) and none of them is a natural owner. It is also
/// the updater's delegate, which Sparkle holds weakly, so something has to keep it alive for the
/// life of the process.
///
/// `@Observable` because the menu item's enabled state is read from a `Commands` body, which is
/// not a view: `@AppStorage` and KVO bindings are both inert there, and the only thing that
/// re-evaluates it is an observable read. See `TextZoomAvailability`, which exists for exactly
/// the same reason.
@MainActor
@Observable
final class SoftwareUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = SoftwareUpdater()

    /// Whether this bundle may update itself at all. See `SoftwareUpdate.availability`.
    private(set) var availability: SoftwareUpdate.Availability = .localBuild

    /// Whether "Check for Updates" may fire right now. False while Sparkle is already downloading
    /// something on its own.
    private(set) var canCheckForUpdates = false

    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates`, which is where the preference actually
    /// lives. Sparkle persists it in the host bundle's defaults itself and resets its schedule
    /// when it moves, and its own documentation is explicit that an app must not keep a second
    /// user default alongside it. So this is a mirror for the Settings switch to observe, not a
    /// second source of truth: `setChecksAutomatically` writes through to Sparkle.
    private(set) var checksAutomatically = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    /// Borrowed to answer one question: how many agents are mid turn. Weak, because the model owns
    /// the app and not the other way round.
    @ObservationIgnored private weak var app: AppModel?

    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var automaticChecksObservation: NSKeyValueObservation?

    /// Held while agents finish. See `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`.
    @ObservationIgnored private var postponedInstall: (() -> Void)?

    private override init() {}

    // MARK: - Starting

    /// Starts the updater, if this bundle is one that may update itself.
    ///
    /// Called once, from the app delegate, after launching has finished. Sparkle schedules its
    /// first background check off the back of `startUpdater`, so starting it any earlier would put
    /// a network request in the middle of the launch it is supposed to stay out of.
    func start(app: AppModel) {
        self.app = app
        guard controller == nil else { return }

        availability = SoftwareUpdate.availability(in: .main)
        guard case .configured(let feedURL) = availability else {
            Log.updates.info("Updates are off for this build: \(String(describing: self.availability), privacy: .public)")
            return
        }

        // `startingUpdater: false`, then started explicitly, so nothing can check for updates
        // between the delegate being wired up and this method returning.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller

        let updater = controller.updater
        updater.updateCheckInterval = SoftwareUpdate.checkInterval
        // Never. What Sparkle downloads on its own it also offers to install on quit, and quitting
        // is already the one moment in this app that has a confirmation of its own about running
        // agents. Downloading only after the user has said yes keeps the whole sequence in front
        // of them.
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false

        controller.startUpdater()

        // `hopToMain` and not `assumeIsolated`: KVO fires on whichever thread mutated the
        // property and Sparkle documents no thread for either of these. See `OnMain` for why the
        // difference matters more than it looks, and note `.initial` makes the first of each of
        // these fire synchronously from right here, which is already the main actor.
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            hopToMain { self?.refreshCanCheck() }
        }
        automaticChecksObservation = updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            hopToMain { self?.refreshChecksAutomatically() }
        }

        Log.updates.info("Updates on, feed \(feedURL, privacy: .public)")
    }

    // MARK: - What the menu item and the Settings switch do

    /// The app menu's "Check for Updates" item.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    /// The Settings switch. Written through to Sparkle rather than into a default of our own.
    func setChecksAutomatically(_ isEnabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = isEnabled
        refreshChecksAutomatically()
    }

    /// Read before assigning, because `@Observable` publishes on every write and both of these are
    /// pushed by KVO rather than pulled.
    private func refreshCanCheck() {
        let value = controller?.updater.canCheckForUpdates ?? false
        if canCheckForUpdates != value { canCheckForUpdates = value }
    }

    private func refreshChecksAutomatically() {
        let value = controller?.updater.automaticallyChecksForUpdates ?? false
        if checksAutomatically != value { checksAutomatically = value }
    }

    // MARK: - SPUUpdaterDelegate

    /// No. `SUEnableAutomaticChecks` in `Info.plist` already answers it, and Sparkle's own
    /// permission sheet on second launch would arrive in the middle of whatever the user opened
    /// Bloom to do.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    /// The first of the two rules that keep an update away from work in flight.
    ///
    /// A scheduled check is refused outright while any agent is mid turn, because what a
    /// successful one produces is an alert offering to install and restart. A check the user asked
    /// for is always allowed: looking is not installing.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground else { return }

        let running = app?.runningAgentCount ?? 0
        guard !SoftwareUpdate.mayCheckInBackground(runningCount: running) else { return }

        Log.updates.info("Background check deferred: \(running, privacy: .public) agents running")
        throw NSError(
            domain: "be.spatie.bloom.updates",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: SoftwareUpdate.backgroundCheckDeferred]
        )
    }

    /// The second rule, and the one that actually protects the work.
    ///
    /// This is the last callback before Bloom is terminated and replaced, so it is the only place
    /// where "an agent is mid turn" can still be acted on. With nothing running it returns false
    /// and the restart happens immediately, which is the whole point of having pressed the button.
    ///
    /// With something running the user is asked, in the same words the quit confirmation uses,
    /// because it is the same loss. Two answers, and neither of them leaves the update in limbo:
    /// restart now, or hold the install handler until the last agent finishes and then invoke it.
    /// Sparkle's contract for this method is exactly that, an install that is deferred until a
    /// block is called, so waiting is a supported state rather than a stall.
    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        let running = app?.runningAgentCount ?? 0
        guard running > 0 else {
            allowTerminationWithoutAsking()
            return false
        }

        if installNowWasChosen(running: running) {
            allowTerminationWithoutAsking()
            return false
        }

        Log.updates.info("Install postponed until \(running, privacy: .public) agents finish")
        postponedInstall = installHandler
        waitForAgentsThenInstall()
        return true
    }

    /// Names the workspaces rather than only counting them, so the answer to "which ones would I
    /// lose?" is on screen at the moment it is needed.
    private func installNowWasChosen(running: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = SoftwareUpdate.interruptionTitle(runningCount: running)
        alert.informativeText = SoftwareUpdate.interruptionDetail(
            runningCount: running,
            workspaceNames: app?.runningAgentWorkspaceNames ?? []
        )

        alert.addButton(withTitle: SoftwareUpdate.installNowButtonTitle)
        alert.addButton(withTitle: SoftwareUpdate.waitButtonTitle)
        // So Return waits rather than restarts: the destructive answer should cost a deliberate
        // click, not the key your hand is already on. The same trade the quit confirmation makes.
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Polled rather than observed.
    ///
    /// `runningAgentCount` is observable, but `withObservationTracking` fires before the write it
    /// is reporting has landed, so reading the count back inside the callback is a race, and the
    /// callback is one-shot so it has to be re-armed on every turn that starts anywhere in the
    /// app. For an event that happens once, minutes from now, at the end of a sequence the user
    /// has already agreed to, a five second tick is the cheaper thing to be sure about.
    private func waitForAgentsThenInstall() {
        Task { @MainActor in
            while let app, app.runningAgentCount > 0 {
                try? await Task.sleep(for: .seconds(5))
            }
            guard let install = postponedInstall else { return }
            postponedInstall = nil
            Log.updates.info("Agents finished, installing the postponed update")
            allowTerminationWithoutAsking()
            install()
        }
    }

    /// Stops the quit confirmation asking a second time.
    ///
    /// Sparkle restarts the app by terminating it normally, which runs
    /// `applicationShouldTerminate` and, with agents running, its "agents are still running"
    /// alert. By this point that question has already been asked and answered by the alert above,
    /// in more detail, so asking it again would only be a way to leave Sparkle's installer waiting
    /// on an answer the user thought they had given.
    private func allowTerminationWithoutAsking() {
        (NSApp.delegate as? BloomAppDelegate)?.isInstallingUpdate = true
    }
}
