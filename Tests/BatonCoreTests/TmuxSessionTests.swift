import Foundation
import Testing
@testable import BatonCore

@Suite("tmux session naming")
struct TmuxSessionNamingTests {
    @Test("A pane always produces the same session name")
    func stable() {
        let workspace = "9d4b0f1e-1111-2222-3333-444455556666"
        let pane = "6f1c2b8a-0f4c-4a6b-9a1e-2c3d4e5f6071"
        let name = TmuxSessions.sessionName(workspaceID: workspace, paneID: pane)
        #expect(name == TmuxSessions.sessionName(workspaceID: workspace, paneID: pane))
        #expect(name == "baton_\(workspace)_\(pane)")
    }

    @Test("Different panes never share a session")
    func unique() {
        let workspace = newID()
        let names = Set((0..<200).map { _ in
            TmuxSessions.sessionName(workspaceID: workspace, paneID: newID())
        })
        #expect(names.count == 200)
    }

    @Test("A session name round trips back to its workspace and its pane")
    func roundTrip() {
        let workspace = newID()
        let pane = newID()
        let name = TmuxSessions.sessionName(workspaceID: workspace, paneID: pane)
        #expect(TmuxSessions.paneID(ofSessionName: name) == pane)
        #expect(TmuxSessions.workspaceID(ofSessionName: name) == workspace)
    }

    @Test("Only Baton's own shape is recognised, so a user's sessions are never touched")
    func foreignSessions() {
        #expect(TmuxSessions.isBatonSession(TmuxSessions.sessionName(workspaceID: newID(), paneID: newID())))
        #expect(!TmuxSessions.isBatonSession("work"))
        #expect(!TmuxSessions.isBatonSession("batonish"))
        #expect(!TmuxSessions.isBatonSession("my_baton_thing"))
        #expect(!TmuxSessions.isBatonSession("baton_"))
        #expect(!TmuxSessions.isBatonSession("baton__pane"))
        #expect(!TmuxSessions.isBatonSession("baton_ws_pane_extra"))
        #expect(TmuxSessions.paneID(ofSessionName: "0") == nil)
    }

    // tmux treats the first two as target separators, and the underscore is what splits a name
    // back into its fields, so none of them may survive into an id.
    @Test("Characters that would break a name are folded away", arguments: [".", ":", " ", "$", "_"])
    func unsafeCharacters(character: String) {
        let name = TmuxSessions.sessionName(workspaceID: "ws", paneID: "pane\(character)one")
        #expect(name == "baton_ws_pane-one")
        #expect(TmuxSessions.paneID(ofSessionName: name) == "pane-one")
    }

    @Test("The socket is per database, so a throwaway instance cannot see the real one")
    func socketPerDatabase() {
        let real = TmuxSessions.socketName(databasePath: "/Users/x/Library/Application Support/Baton/baton.sqlite")
        let copy = TmuxSessions.socketName(databasePath: "/tmp/scratch/baton.sqlite")
        #expect(real != copy)
        #expect(real == TmuxSessions.socketName(databasePath: "/Users/x/Library/Application Support/Baton/baton.sqlite"))
        #expect(real.hasPrefix("baton-"))
    }

    @Test("The fingerprint does not move between runs")
    func fingerprintIsStable() {
        // A literal, not a recomputation: the point is that a socket named by an older launch is
        // still found by this one. `Hashable` would pass a self-comparison and fail this.
        #expect(TmuxSessions.fingerprint("/tmp/baton.sqlite") == "f72c68c0")
        #expect(TmuxSessions.fingerprint("") == "811c9dc5")
    }
}

@Suite("tmux restore decision")
struct TmuxRestoreDecisionTests {
    private let workspace = "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9"
    private let pane = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
    private var name: String { TmuxSessions.sessionName(workspaceID: workspace, paneID: pane) }

    @Test("The setting off keeps the historical in-process shell")
    func settingOff() {
        let decision = TmuxSessions.decide(
            workspaceID: workspace, paneID: pane,
            persistenceEnabled: false, tmuxAvailable: true, existingSessions: []
        )
        #expect(decision == .inProcess)
    }

    @Test("No tmux on the machine falls back rather than failing")
    func noTmux() {
        let decision = TmuxSessions.decide(
            workspaceID: workspace,
            paneID: pane,
            persistenceEnabled: true,
            tmuxAvailable: false,
            existingSessions: [name]
        )
        #expect(decision == .inProcess)
    }

    @Test("A session that survived the last quit is reattached")
    func reattach() {
        let decision = TmuxSessions.decide(
            workspaceID: workspace,
            paneID: pane,
            persistenceEnabled: true,
            tmuxAvailable: true,
            existingSessions: [name, "baton_other_pane"]
        )
        #expect(decision == .attach(session: name))
    }

    @Test("A pane whose session is gone starts fresh instead of erroring")
    func startFresh() {
        let decision = TmuxSessions.decide(
            workspaceID: workspace,
            paneID: pane,
            persistenceEnabled: true,
            tmuxAvailable: true,
            existingSessions: ["baton_someone_else"]
        )
        #expect(decision == .createFresh(session: name))
    }

    @Test("Both tmux outcomes exec the same command, so a stale snapshot cannot break a pane")
    func sameArguments() {
        let command = TmuxCommand(executable: "/opt/homebrew/bin/tmux", socketName: "baton-1", configPath: "/c")
        let attach = TmuxSessions.decide(
            workspaceID: workspace, paneID: pane, persistenceEnabled: true, tmuxAvailable: true,
            existingSessions: [name]
        )
        let fresh = TmuxSessions.decide(
            workspaceID: workspace, paneID: pane, persistenceEnabled: true, tmuxAvailable: true,
            existingSessions: []
        )
        let arguments = { (decision: TerminalStartDecision) in
            command.attachOrCreate(session: decision.session ?? "", directory: "/w", environment: [:])
        }
        #expect(arguments(attach) == arguments(fresh))
    }
}

@Suite("tmux orphan rule")
struct TmuxOrphanTests {
    private let workspace = newID()

    private func session(_ pane: String) -> String {
        TmuxSessions.sessionName(workspaceID: workspace, paneID: pane)
    }

    @Test("A session whose pane is still reachable is kept")
    func keepsLive() {
        let pane = newID()
        #expect(TmuxSessions.orphans(sessions: [session(pane)], livePaneIDs: [pane]).isEmpty)
    }

    @Test("A session whose pane is gone is swept")
    func sweepsDeadPane() {
        let live = newID()
        let dead = newID()
        let orphans = TmuxSessions.orphans(
            sessions: [session(live), session(dead)], livePaneIDs: [live]
        )
        #expect(orphans == [session(dead)])
    }

    @Test("A session belonging to a workspace that is gone is swept with it")
    func sweepsArchivedWorkspace() {
        // The caller builds the live set from the workspaces still in the database, so an archived
        // workspace contributes no panes and every session it owned reads as unreachable.
        let archived = [newID(), newID()]
        let surviving = newID()
        let orphans = TmuxSessions.orphans(
            sessions: (archived + [surviving]).map(session), livePaneIDs: [surviving]
        )
        #expect(Set(orphans) == Set(archived.map(session)))
    }

    @Test("A session the user created themselves is never swept")
    func leavesForeignSessions() {
        let orphans = TmuxSessions.orphans(
            sessions: ["work", "dotfiles", "0", "baton", "baton_only-two-fields"], livePaneIDs: []
        )
        #expect(orphans.isEmpty)
    }

    @Test("Nothing live means nothing survives, which is what an empty database should do")
    func sweepsEverythingWhenNothingIsLive() {
        let sessions = [newID(), newID()].map(session)
        #expect(TmuxSessions.orphans(sessions: sessions, livePaneIDs: []) == sessions)
    }

    @Test("Turning the setting off makes every session unreachable, so the sweep takes them all")
    func settingOffSweepsEverything() {
        let live = newID()
        let panes = TmuxSessions.reachablePanes([live], persistenceEnabled: false)
        #expect(panes.isEmpty)
        #expect(TmuxSessions.orphans(sessions: [session(live)], livePaneIDs: panes) == [session(live)])
    }

    @Test("With the setting on, a live pane stays reachable")
    func settingOnKeepsLivePanes() {
        let live = newID()
        #expect(TmuxSessions.reachablePanes([live], persistenceEnabled: true) == [live])
    }

    @Test("list-sessions output is read line by line")
    func parsesList() {
        #expect(TmuxSessions.parseSessionList("baton_a_b\nbaton_c_d\n") == ["baton_a_b", "baton_c_d"])
        #expect(TmuxSessions.parseSessionList("") == [])
        // What tmux prints when no server is running arrives on stderr, so stdout is empty.
        #expect(TmuxSessions.parseSessionList("\n\n") == [])
    }
}

@Suite("tmux archive teardown")
struct TmuxArchiveTeardownTests {
    @Test("Archiving names every session of that workspace and nothing else")
    func archiveTargetsTheWorkspace() {
        let archived = newID()
        let other = newID()
        let doomed = (0..<3).map { _ in TmuxSessions.sessionName(workspaceID: archived, paneID: newID()) }
        let spared = [
            TmuxSessions.sessionName(workspaceID: other, paneID: newID()),
            "someone-elses-session",
        ]

        let killed = TmuxSessions.sessions(ofWorkspace: archived, in: doomed + spared)
        #expect(Set(killed) == Set(doomed))
    }

    @Test("An archived workspace leaves no tmux session behind")
    func nothingSurvivesAnArchive() {
        let archived = newID()
        var live = (0..<4).map { _ in TmuxSessions.sessionName(workspaceID: archived, paneID: newID()) }

        // What `TerminalSessionStore.discard` does: match by workspace, kill, then look again.
        for session in TmuxSessions.sessions(ofWorkspace: archived, in: live) {
            live.removeAll { $0 == session }
        }
        #expect(TmuxSessions.sessions(ofWorkspace: archived, in: live).isEmpty)
        #expect(live.isEmpty)
    }

    @Test("A workspace whose panes were never drawn is still torn down")
    func doesNotDependOnLoadedTabs() {
        // The names are the only bookkeeping this path trusts. A tab list that was never loaded,
        // or a split layout that was lost, cannot leave a shell alive in a deleted worktree.
        let archived = newID()
        let session = TmuxSessions.sessionName(workspaceID: archived, paneID: newID())
        #expect(TmuxSessions.sessions(ofWorkspace: archived, in: [session]) == [session])
    }

    @Test("A workspace with no terminals leaves nothing to kill")
    func noSessions() {
        #expect(TmuxSessions.sessions(ofWorkspace: newID(), in: []).isEmpty)
    }
}

@Suite("tmux command lines")
struct TmuxCommandTests {
    private let command = TmuxCommand(
        executable: "/opt/homebrew/bin/tmux", socketName: "baton-deadbeef", configPath: "/cfg/tmux.conf"
    )

    @Test("Every command names the private socket and the generated config")
    func globals() {
        #expect(command.globalArguments == ["-L", "baton-deadbeef", "-f", "/cfg/tmux.conf", "-u"])
        #expect(command.listSessions.starts(with: command.globalArguments))
        #expect(command.killSession("baton-x").starts(with: command.globalArguments))
    }

    @Test("A pane attaches or creates in one exec, with its workspace environment")
    func attachOrCreate() {
        let arguments = command.attachOrCreate(
            session: "baton-x",
            directory: "/tmp/work",
            environment: ["BATON_PORT": "3000", "CONDUCTOR_PORT": "3000"]
        )
        #expect(arguments == [
            "-L", "baton-deadbeef", "-f", "/cfg/tmux.conf", "-u",
            "new-session", "-A", "-D", "-s", "baton-x", "-c", "/tmp/work",
            "-e", "BATON_PORT=3000",
            "-e", "CONDUCTOR_PORT=3000",
        ])
    }

    @Test("Kills name the session exactly, so a prefix match can never take a second one")
    func exactKill() {
        #expect(command.killSession("baton-x").suffix(2) == ["-t", "=baton-x"])
    }

    @Test("The generated configuration turns off everything that would be noticed")
    func configuration() {
        let text = TmuxSessions.configuration(defaultShell: "/bin/zsh")
        #expect(text.contains("set -g default-shell \"/bin/zsh\""))
        #expect(text.contains("set -g escape-time 0"))
        #expect(text.contains("set -g status off"))
        #expect(text.contains("set -g prefix None"))
        #expect(text.contains("set -g prefix2 None"))
        #expect(text.contains("unbind-key -a -T prefix"))
        // The wheel is the one thing that must reach tmux: a client puts SwiftTerm into its
        // alternate screen, so without this a scroll would do nothing at all.
        #expect(text.contains("set -g mouse on"))
        #expect(text.contains("set -g set-clipboard on"))
    }
}
