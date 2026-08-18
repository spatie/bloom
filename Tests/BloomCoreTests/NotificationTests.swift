import Testing
import Foundation
@testable import BloomCore

/// Bloom runs several agents at once, so a notification is only useful when it names a workspace
/// and only welcome when the user was not already watching that workspace. Both of those, plus the
/// per-event switches and the batching that keeps six simultaneous finishes down to one banner,
/// live in BloomCore precisely so they can be asserted on without a bundle or a permission.
@Suite("Notification policy")
struct NotificationPolicyTests {
    private let allOn = NotificationSettings(isEnabled: true)

    @Test("frontmost and looking at that workspace stays quiet")
    func suppressesWhatIsAlreadyOnScreen() {
        let verdict = NotificationPolicy.verdict(
            for: .turnFinished,
            workspaceID: "w1",
            settings: allOn,
            context: NotificationContext(isAppActive: true, selectedWorkspaceID: "w1")
        )

        #expect(verdict == .alreadyOnScreen)
        #expect(verdict.delivers == false)
    }

    @Test("frontmost but looking at a different workspace still notifies")
    func notifiesForOtherWorkspacesWhileActive() {
        // The case the whole feature exists for: five agents running, one window, four of them
        // finishing somewhere the user cannot see.
        let verdict = NotificationPolicy.verdict(
            for: .turnFinished,
            workspaceID: "w2",
            settings: allOn,
            context: NotificationContext(isAppActive: true, selectedWorkspaceID: "w1")
        )

        #expect(verdict == .deliver)
    }

    @Test("frontmost on Home or Search notifies for every workspace")
    func notifiesWhenNoWorkspaceIsSelected() {
        let verdict = NotificationPolicy.verdict(
            for: .turnFinished,
            workspaceID: "w1",
            settings: allOn,
            context: NotificationContext(isAppActive: true, selectedWorkspaceID: nil)
        )

        #expect(verdict == .deliver)
    }

    @Test("in the background, even the selected workspace notifies")
    func notifiesInBackgroundRegardlessOfSelection() {
        let verdict = NotificationPolicy.verdict(
            for: .turnFinished,
            workspaceID: "w1",
            settings: allOn,
            context: NotificationContext(isAppActive: false, selectedWorkspaceID: "w1")
        )

        #expect(verdict == .deliver)
    }

    @Test("the master switch beats everything, including being in another app")
    func masterSwitchWins() {
        for event in NotificationEvent.allCases {
            let verdict = NotificationPolicy.verdict(
                for: event,
                workspaceID: "w1",
                settings: NotificationSettings(isEnabled: false),
                context: NotificationContext(isAppActive: false, selectedWorkspaceID: nil)
            )

            #expect(verdict == .notificationsAreOff)
        }
    }

    @Test("a per-event switch gates only its own event")
    func perEventSwitchesGateOnlyThemselves() {
        for event in NotificationEvent.allCases {
            let settings = NotificationSettings(
                isEnabled: true,
                enabledEvents: Set(NotificationEvent.allCases).subtracting([event])
            )
            let context = NotificationContext(isAppActive: false, selectedWorkspaceID: nil)

            #expect(
                NotificationPolicy.verdict(
                    for: event, workspaceID: "w1", settings: settings, context: context
                ) == .eventIsOff
            )

            for other in NotificationEvent.allCases where other != event {
                #expect(
                    NotificationPolicy.verdict(
                        for: other, workspaceID: "w1", settings: settings, context: context
                    ) == .deliver
                )
            }
        }
    }

    @Test("an event that is switched off is still off for a workspace on screen")
    func offBeatsOnScreen() {
        // Order matters only for what gets reported, but reporting the preference rather than the
        // suppression is what makes "why did it go quiet?" answerable.
        let verdict = NotificationPolicy.verdict(
            for: .checksFinished,
            workspaceID: "w1",
            settings: NotificationSettings(isEnabled: true, enabledEvents: [.turnFinished]),
            context: NotificationContext(isAppActive: true, selectedWorkspaceID: "w1")
        )

        #expect(verdict == .eventIsOff)
    }
}

@Suite("Notification preferences")
struct NotificationPreferencesTests {
    /// Its own defaults suite per test, so a stored toggle cannot leak into the next one or into
    /// the machine's real preferences.
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "bloom.notifications.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    @Test("out of the box, nothing is sent and no permission is needed")
    func startsOff() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let preferences = NotificationPreferences(defaults: defaults)

        #expect(preferences.isEnabled == false)
        #expect(preferences.settings.allows(.turnFinished) == false)
    }

    @Test("every event is on once the master switch is, without anything being stored")
    func eventsDefaultToOn() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let preferences = NotificationPreferences(defaults: defaults)
        preferences.isEnabled = true

        for event in NotificationEvent.allCases {
            // `bool(forKey:)` would answer false here, which is the opposite of what the form draws.
            #expect(defaults.object(forKey: NotificationPreferences.key(for: event)) == nil)
            #expect(preferences.isEnabled(event))
            #expect(preferences.settings.allows(event))
        }
    }

    @Test("switching one event off leaves the others alone")
    func storesOneEventAtATime() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let preferences = NotificationPreferences(defaults: defaults)
        preferences.isEnabled = true
        preferences.setEnabled(false, for: .checksFinished)

        #expect(preferences.settings.allows(.checksFinished) == false)
        #expect(preferences.settings.allows(.turnFinished))
    }

    @Test("the keys the settings form binds to are the keys the rule reads")
    func keysAreStable() {
        // `@AppStorage` takes a string. If these two ever drift, the window shows one thing and
        // the app does another, with nothing failing to say so.
        #expect(NotificationPreferences.enabledKey == "notifications.enabled")
        #expect(NotificationPreferences.key(for: .turnFinished) == "notifications.event.turnFinished")
    }
}

@Suite("Notification coalescing")
struct NotificationDigestTests {
    private func draft(
        _ event: NotificationEvent = .turnFinished,
        id: String,
        name: String,
        detail: String = ""
    ) -> NotificationDraft {
        NotificationDraft(event: event, workspaceID: id, workspaceName: name, detail: detail)
    }

    @Test("one workspace gets a banner titled with its own name")
    func singleKeepsTheWorkspaceName() {
        var digest = NotificationDigest()
        digest.add(draft(id: "w1", name: "auth-refactor", detail: "Added the token refresh."))

        let prepared = digest.drain(.turnFinished)

        #expect(prepared?.title == "auth-refactor")
        #expect(prepared?.body == "Added the token refresh.")
        #expect(prepared?.workspaceID == "w1")
        #expect(prepared?.identifier == "bloom.turnFinished.w1")
    }

    @Test("a workspace with nothing to say still says something")
    func singleFallsBackToTheEventWording() {
        var digest = NotificationDigest()
        digest.add(draft(id: "w1", name: "auth-refactor"))

        let prepared = digest.drain(.turnFinished)

        #expect(prepared?.body == NotificationEvent.turnFinished.fallbackDetail)
    }

    @Test("several finishing together become one banner that names them")
    func collapsesABatchIntoASummary() {
        var digest = NotificationDigest()
        // Only the first one opens a batch. The rest join it, which is what stops five timers.
        let opened = digest.add(draft(id: "w1", name: "auth"))
        let joinedSecond = digest.add(draft(id: "w2", name: "billing"))
        let joinedThird = digest.add(draft(id: "w3", name: "search"))

        #expect(opened)
        #expect(joinedSecond == false)
        #expect(joinedThird == false)

        let prepared = digest.drain(.turnFinished)

        #expect(prepared?.title == "3 agents finished")
        #expect(prepared?.body == "auth, billing, search")
        // Clicking has to land somewhere, and the first of them is the only defensible choice.
        #expect(prepared?.workspaceID == "w1")
        #expect(prepared?.threadIdentifier == "bloom.turnFinished")
    }

    @Test("the same workspace twice inside one window counts once, and the later one wins")
    func dedupesAWorkspaceWithinABatch() {
        var digest = NotificationDigest()
        digest.add(draft(id: "w1", name: "auth", detail: "first"))
        digest.add(draft(id: "w1", name: "auth", detail: "second"))

        let prepared = digest.drain(.turnFinished)

        #expect(prepared?.title == "auth")
        #expect(prepared?.body == "second")
    }

    @Test("different events never merge into one sentence")
    func keepsEventsApart() {
        var digest = NotificationDigest()
        // Both open their own batch, because a failure and a finish are two pieces of news.
        let openedFinish = digest.add(draft(.turnFinished, id: "w1", name: "auth"))
        let openedFailure = digest.add(draft(.agentFailed, id: "w2", name: "billing"))

        #expect(openedFinish)
        #expect(openedFailure)

        let finish = digest.drain(.turnFinished)
        let failure = digest.drain(.agentFailed)

        #expect(finish?.title == "auth")
        #expect(failure?.title == "billing")
        #expect(digest.isEmpty)
    }

    @Test("draining twice does not send the same thing twice")
    func drainEmptiesTheBatch() {
        var digest = NotificationDigest()
        digest.add(draft(id: "w1", name: "auth"))

        let first = digest.drain(.turnFinished)
        let second = digest.drain(.turnFinished)

        #expect(first != nil)
        #expect(second == nil)
        #expect(digest.isEmpty)
    }

    @Test("every event has its own summary wording")
    func everyEventHasASummary() {
        for event in NotificationEvent.allCases {
            var digest = NotificationDigest()
            digest.add(draft(event, id: "w1", name: "auth"))
            digest.add(draft(event, id: "w2", name: "billing"))

            let prepared = digest.drain(event)

            #expect(prepared?.title == event.summaryTitle(count: 2))
            #expect(prepared?.title.contains("2") == true)
            #expect(prepared?.identifier == "bloom.\(event.rawValue).digest")
        }
    }

    @Test("a body is cut at the first line break, then at a length macOS will show")
    func capsTheBody() {
        var digest = NotificationDigest()
        digest.add(draft(id: "w1", name: "auth", detail: "The headline.\nAnd then the detail nobody reads."))

        let headline = digest.drain(.turnFinished)?.body
        #expect(headline == "The headline.")

        let long = String(repeating: "x", count: NotificationDigest.bodyLimit + 200)
        digest.add(draft(id: "w1", name: "auth", detail: long))
        let body = try? #require(digest.drain(.turnFinished)?.body)

        #expect((body?.count ?? 0) <= NotificationDigest.bodyLimit + 1)
        #expect(body?.hasSuffix("\u{2026}") == true)
    }
}

@Suite("Turn outcomes")
struct TurnOutcomeTests {
    @Test("a clean result is a finish")
    func successIsAFinish() {
        let result = AgentResult(summary: "Done.", isError: false, subtype: "success")

        #expect(result.outcome(wasCancelled: false) == .finished)
        #expect(result.outcome(wasCancelled: false)?.event == .turnFinished)
    }

    @Test("pressing Stop is not a failure and is not worth a banner")
    func cancellationSaysNothing() {
        // The CLI reports its own SIGTERM as an error result, so without this the user's own click
        // would come back at them as "the agent stopped".
        let result = AgentResult(isError: true, subtype: "error_during_execution")

        #expect(result.outcome(wasCancelled: true) == nil)
    }

    @Test("an error result is a failure")
    func errorIsAFailure() {
        let result = AgentResult(isError: true, subtype: "error_during_execution")

        #expect(result.outcome(wasCancelled: false) == .failed)
        #expect(result.outcome(wasCancelled: false)?.event == .agentFailed)
    }

    @Test("a denied permission means the agent is waiting on a person")
    func permissionDenialNeedsInput() {
        // There is nobody at the CLI to answer a permission prompt, so a denial is the closest
        // thing the protocol has to "it needs you".
        let result = AgentResult(isError: false, subtype: "success", permissionDenials: 2)

        #expect(result.outcome(wasCancelled: false) == .needsInput)
        #expect(result.outcome(wasCancelled: false)?.event == .needsInput)
    }

    @Test("running out of turns means the agent is waiting on a person")
    func maxTurnsNeedsInput() {
        let result = AgentResult(isError: true, subtype: "error_max_turns")

        // Beats `isError`, because "it gave up early" and "it crashed" want different reactions.
        #expect(result.outcome(wasCancelled: false) == .needsInput)
    }
}
