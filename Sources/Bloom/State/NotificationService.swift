import AppKit
import Observation
import SwiftUI
import UserNotifications
import BloomCore

/// Delivers the local notifications, and nothing else.
///
/// A service rather than logic inside the models, because the two places that know an agent turn
/// ended are `TranscriptModel` and `WorkspaceModel`, and neither of them should grow a second
/// subject. What they call is one line each. Everything about whether to interrupt somebody lives
/// in `NotificationPolicy` and `NotificationDigest`, in BloomCore, where it can be tested without
/// a bundle, a window or a permission.
///
/// One instance, because there is one Notification Center and one window. It is `@Observable` for
/// the settings pane alone, which needs to redraw when macOS changes its mind about the permission.
@MainActor
@Observable
final class NotificationService {
    static let shared = NotificationService()

    /// Whether this process has a Notification Center to talk to at all.
    ///
    /// `UNUserNotificationCenter.current()` does not fail politely for a process that is not a
    /// registered app bundle: it raises `NSInternalInconsistencyException`
    /// ("bundleProxyForCurrentProcess is nil") and the process aborts. That is the whole story of
    /// a morning of crash reports named Bloom: `.build/debug/Bloom` run as a bare executable died
    /// inside `applicationDidFinishLaunching` at the first touch of the centre, seconds after the
    /// window appeared, and because the abort lands when the launch's own Apple Event is
    /// processed it was mistaken for a crash in whatever the keyboard was doing at that moment.
    /// `Store` promises that an unbundled binary starts empty rather than not starting, so the
    /// centre is treated as absent here: no delegate, no categories, no banners, and the settings
    /// pane reports the permission as undetermined. A bare executable has no Dock icon for a
    /// banner to open anyway.
    nonisolated static let isAvailable = Bundle.main.bundleIdentifier != nil

    /// The category carrying Reply and Open. Only ever set on a banner that names one workspace,
    /// because a reply box on "6 agents finished" would silently send to whichever of the six the
    /// digest happened to point at.
    nonisolated private static let workspaceCategory = "bloom.workspace"
    /// Open only, for a digest and for the test banner.
    nonisolated private static let summaryCategory = "bloom.summary"
    nonisolated private static let replyAction = "bloom.reply"
    nonisolated private static let openAction = "bloom.open"

    /// How often the pull requests with pending checks get looked at again. Slow on purpose: each
    /// one is a `gh` subprocess, and CI takes minutes rather than seconds.
    private static let checksInterval = Duration.seconds(30)

    /// What macOS says right now, not what it said when the app launched. Somebody can revoke the
    /// permission in System Settings while Bloom is running, and a toggle that keeps claiming to
    /// work is exactly the silent failure this is meant to avoid.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// True while the system prompt is up, so the settings pane can stop somebody pressing the
    /// switch a second time behind it.
    private(set) var isRequestingPermission = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let preferences = NotificationPreferences()
    @ObservationIgnored private var digest = NotificationDigest()
    /// One pending flush per event. Unstructured because it is a debounce: there is nothing to
    /// wait for it, and the thing that starts it has already returned.
    @ObservationIgnored private var flushTasks: [NotificationEvent: Task<Void, Never>] = [:]
    @ObservationIgnored private var checksTask: Task<Void, Never>?
    /// What CI said about each workspace last time it was looked at, so a transition into a result
    /// can be told from a result that has been sitting there all along.
    @ObservationIgnored private var lastSeenChecks: [WorkspaceID: PullRequest.Checks] = [:]

    private init() {}

    // MARK: - Wiring

    /// Handed the app state once it exists, the same way `BloomAppDelegate` is. The suppression
    /// rule needs to know which workspace is selected, and asking for it at the moment an event
    /// arrives is the only way to get an answer that is still true.
    func attach(_ app: AppModel) {
        guard self.app !== app else { return }
        self.app = app
        Task { await refreshAuthorization() }
        startWatchingChecks()
    }

    /// Declares the buttons a banner can carry. Called once, on launch, because macOS keeps the
    /// registration for the app rather than for a request: a category named by a notification that
    /// was never registered arrives as a plain banner with no buttons at all.
    func registerCategories() {
        guard Self.isAvailable else { return }
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply to the agent"
        )
        let open = UNNotificationAction(
            identifier: Self.openAction,
            title: "Open",
            options: [.foreground]
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.workspaceCategory,
                actions: [reply, open],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.summaryCategory,
                actions: [open],
                intentIdentifiers: []
            ),
        ])
    }

    // MARK: - Permission

    func refreshAuthorization() async {
        guard Self.isAvailable else { return }
        authorization = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
    }

    /// Asked when somebody turns the setting on, never on launch.
    ///
    /// A permission prompt on the first launch of an app nobody has used yet is the reason people
    /// say no, and macOS only asks once: a refusal at that moment is close to permanent. Asked at
    /// the moment the switch is flipped, the prompt is an answer to something the user just did.
    ///
    /// Returns false without showing anything when the permission has already been refused, which
    /// is what makes the settings pane's blocked state reachable.
    @discardableResult
    func requestPermission() async -> Bool {
        guard Self.isAvailable else { return false }
        guard !isRequestingPermission else { return authorization == .authorized }
        isRequestingPermission = true
        defer { isRequestingPermission = false }

        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        await refreshAuthorization()
        return granted
    }

    /// Whether macOS is currently throwing away everything Bloom sends. Drives the warning in the
    /// settings pane.
    var isBlockedBySystem: Bool {
        authorization == .denied
    }

    func openSystemSettings() {
        // The Ventura-and-later pane id. The `id` query selects Bloom's own row, so the switch the
        // user has to flip is the one already on screen rather than one in a list of two hundred.
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let target = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(identifier)"
        guard let url = URL(string: target) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Events

    func turnFinished(workspace: Workspace, result: AgentResult, wasCancelled: Bool) {
        guard let outcome = result.outcome(wasCancelled: wasCancelled) else { return }
        submit(NotificationDraft(
            event: outcome.event,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            detail: result.summary
        ))
    }

    /// The agent is asking for permission and cannot go on until somebody answers.
    ///
    /// `needsInput` has been in `NotificationEvent` from the start, saying "An agent needs
    /// something from me", and until now nothing raised it: there was no moment when an agent
    /// needed something, because the CLI answered for the user and the answer was no. This is that
    /// moment, and it is the one notification in the set where the delay is the cost.
    func agentNeedsPermission(workspace: Workspace, detail: String = "") {
        submit(NotificationDraft(
            event: .needsInput,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            detail: detail
        ))
    }

    /// The agent died without ever producing a result, so there is no `AgentResult` to classify.
    func agentFailed(workspace: Workspace, message: String) {
        submit(NotificationDraft(
            event: .agentFailed,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            detail: message
        ))
    }

    func setupFailed(workspace: Workspace) {
        submit(NotificationDraft(
            event: .setupFailed,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            // One sentence for this event wherever it is said. See `SetupFailure`.
            detail: SetupFailure.instruction
        ))
    }

    /// Delivered straight past the policy, because it was asked for by somebody who is looking at
    /// the settings window: every rule that would suppress it would suppress exactly this case.
    func sendTestNotification() {
        deliver(PreparedNotification(
            identifier: "bloom.test",
            threadIdentifier: "bloom.test",
            title: "Bloom",
            body: "Notifications are working. This is what an agent finishing looks like.",
            workspaceID: app?.selection.workspaceID ?? WorkspaceID("")
        ))
    }

    // MARK: - The rule

    private var context: NotificationContext {
        NotificationContext(
            // Nil means there is no application object, which means nothing is on screen to have
            // seen the event happen.
            isAppActive: NSApp?.isActive ?? false,
            selectedWorkspaceID: app?.selection.workspaceID
        )
    }

    private func submit(_ draft: NotificationDraft) {
        let verdict = NotificationPolicy.verdict(
            for: draft.event,
            workspaceID: draft.workspaceID,
            settings: preferences.settings,
            context: context
        )
        guard verdict.delivers else { return }

        // Only the draft that opened a batch schedules its flush. Every later one joins the batch
        // that is already collecting, which is the whole point of the window.
        guard digest.add(draft) else { return }

        flushTasks[draft.event] = Task { [weak self] in
            try? await Task.sleep(for: NotificationDigest.window)
            guard !Task.isCancelled else { return }
            self?.flush(draft.event)
        }
    }

    private func flush(_ event: NotificationEvent) {
        flushTasks[event] = nil
        guard let prepared = digest.drain(event) else { return }
        deliver(prepared)
    }

    private func deliver(_ prepared: PreparedNotification) {
        guard Self.isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = prepared.title
        content.body = prepared.body
        content.sound = .default
        content.threadIdentifier = prepared.threadIdentifier
        content.userInfo = BannerUserInfo.encode(workspaceID: prepared.workspaceID)
        // `NotificationDigest` threads a single banner under the workspace it is about and a digest
        // under its event, so the two are told apart by whether the thread IS the workspace. That
        // is the same fact the reply box needs: exactly one agent to send to.
        content.categoryIdentifier = prepared.threadIdentifier == prepared.workspaceID.rawValue
            ? Self.workspaceCategory
            : Self.summaryCategory

        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: prepared.identifier, content: content, trigger: nil
        ))
    }

    // MARK: - Replying from the banner

    /// Sends text typed into a banner down the same path a composer submit takes.
    ///
    /// Deliberately `TranscriptModel.send`, not a second route to the runner: the composer's
    /// submit is one line calling exactly this, and everything either of them needs to do (clear
    /// the draft, mark the turn's start, raise the alert when the agent will not start) lives
    /// inside it.
    ///
    /// The one thing the banner has to decide for itself is which session, because a banner names
    /// a workspace and a workspace can hold several. The active one is the right answer: it is the
    /// conversation the notification came out of, and the one the window would show if the click
    /// had opened it instead.
    func reply(_ text: String, toWorkspace workspaceID: WorkspaceID) async {
        guard let app, let workspace = app.workspaces.first(where: { $0.id == workspaceID }) else { return }

        let model = app.model(for: workspace)
        // A workspace nobody opened this launch has no sessions loaded. Replying to a banner is
        // one of the few ways to reach a workspace without ever selecting it.
        if model.sessions.isEmpty { await model.reloadSessions() }
        guard let session = model.activeSession else { return }

        // A turn that started between the banner arriving and the reply being typed used to be
        // handled here, by parking the text in the composer and raising the window so it could be
        // seen sitting there. That was the right instinct and the wrong mechanism: it made the
        // reply the user's problem again, and it was a second answer to the question the composer
        // was also answering for itself. `submit` is now the only way into a chat and it queues
        // whatever cannot go yet, so a reply typed into a banner mid turn lands in the same place,
        // in the same order, as one typed into the box. See `Delivery`.
        await model.transcript(for: session).submit(text)
    }

    /// Which workspace a click should select. Nonisolated because a click is delivered to the app
    /// delegate off the main actor and has to be read before hopping.
    nonisolated static func workspaceID(from response: UNNotificationResponse) -> WorkspaceID? {
        BannerUserInfo.workspaceID(from: response.notification.request.content.userInfo)
    }

    // MARK: - Checks

    /// Watches CI on the pull requests Bloom already knows about.
    ///
    /// This is the one event with no moment to hook: nothing in the app is told that a check run
    /// finished. The Checks tab polls, but only while it is the tab on screen, which is the one
    /// case where a notification would be pointless. So the watcher rides on the pull request
    /// state each `WorkspaceModel` already holds, and refreshes only the ones whose checks are
    /// pending. A workspace the user has not opened this launch has no model and no pull request
    /// loaded, and is therefore not watched at all.
    private func startWatchingChecks() {
        checksTask?.cancel()
        checksTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checksInterval)
                guard let self else { return }
                await self.pollChecks()
            }
        }
    }

    private func pollChecks() async {
        guard let app,
              preferences.isEnabled,
              preferences.isEnabled(.checksFinished) else { return }

        let onScreen = context.isAppActive ? context.selectedWorkspaceID : nil

        for workspace in app.workspaces {
            guard !Task.isCancelled else { return }
            // The workspace in front of the user refreshes itself when they look at it, and a
            // background refresh would flash the inspector's pull request spinner every half
            // minute while they read. It is also the one workspace that would never be notified
            // about, so there is nothing to watch for.
            guard workspace.id != onScreen else { continue }
            guard let model = app.existingModel(for: workspace.id),
                  let pullRequest = model.pullRequest else {
                lastSeenChecks[workspace.id] = nil
                continue
            }

            let previous = lastSeenChecks[workspace.id]
            lastSeenChecks[workspace.id] = pullRequest.checks

            // Only the transition, never the state. A pull request that has been green since
            // yesterday would otherwise announce itself on every pass.
            if previous == .pending, pullRequest.checks == .passing || pullRequest.checks == .failing {
                submit(NotificationDraft(
                    event: .checksFinished,
                    workspaceID: workspace.id,
                    workspaceName: workspace.name,
                    detail: pullRequest.checksSummary
                ))
            }

            // Nothing else in the app refreshes a pull request while the user is elsewhere, so
            // pending checks are the only reason to spend a `gh` call here.
            if pullRequest.checks == .pending {
                await model.refreshPullRequest()
            }
        }
    }
}
