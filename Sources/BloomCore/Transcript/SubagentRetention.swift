import Foundation

/// Which of a turn's subagents still have a row, and for how long.
///
/// **The rule changed once already and this is the second answer.** The first version removed a
/// row the moment its subagent finished, and it was replaced because three rows leaving one by one
/// take everything below them up the pane while you are reading the third. The version after it
/// kept every finished row until the next turn started, and a real fan-out showed why that is
/// worse: eight subagents under one workspace left eight rows standing, seven ticks and a cross,
/// and the sidebar had become a log of a turn that was still running. A sidebar is a navigation
/// surface. Eight finished rows is a transcript in the wrong pane.
///
/// Before any of that: a backgrounded shell command has no row at all, whatever state it is in.
/// See `keeps`. The rest of this file is about the rows that remain, which are agents.
///
/// So a finished row goes, with three exemptions, each of which is a thing you would otherwise
/// have to go and look for.
///
/// **A failure stays.** This is the one judgement in the file and it is deliberate. "Done" was the
/// instruction and a failure is also done, but a tick and a cross are not the same fact. A tick
/// says what the workspace carrying on already says. A cross is the only place a piece of a
/// fan-out dying is visible at a glance, and it is visible for as long as it takes to notice,
/// which is not two seconds. In the screenshot that prompted the change one of the eight had
/// failed; removing only the successes takes that list from eight rows to one, which is the short
/// list that was asked for, and the row that survives is the one worth surviving.
///
/// **A row you have opened stays.** A subagent's output can be the selected pane. Removing the row
/// under a reader is the same yank as removing it under a glance, and worse, because they are
/// looking at it. It is bounded by how many you clicked.
///
/// **A finished row is held briefly before it goes.** A row that appears and vanishes inside two
/// seconds is a flicker of its own, and the tick is the confirmation that the work landed. See
/// `lingerSeconds`.
///
/// The backstop is unchanged and is what keeps all three bounded: `SubagentRoster.turnStarted`
/// clears everything when the next turn begins.
public enum SubagentRetention: Sendable {
    /// How long a finished row is held before it leaves.
    ///
    /// Long enough that a glance at the pane catches the tick, short enough that a fan-out
    /// finishing over a minute never has more than a row or two standing at once. It is
    /// deliberately more than ten times `ProjectVisibilityMotion.seconds`: the reflow is how long
    /// the row takes to LEAVE, and a hold shorter than a small multiple of it would read as one
    /// continuous slide rather than as a mark that was shown and then withdrawn.
    public static let lingerSeconds: Double = 2.5

    /// How many failed rows are kept at once.
    ///
    /// Failures outliving successes is the exemption above; failures accumulating without limit
    /// would put the log straight back. A fan-out that half fails must not leave six rows behind,
    /// so the first three in spawn order keep their crosses and the rest are counted on the
    /// workspace row instead. Three, because that is what fits under a workspace row without the
    /// project below it leaving the first screen of a full sidebar.
    ///
    /// A failure past the cap that somebody has OPENED is the one thing that can put a fourth
    /// cross on the pane, and that is the right way round: they asked for that row by clicking it.
    public static let failureLimit = 3

    /// The rows to draw, in spawn order.
    ///
    /// - Parameters:
    ///   - now: passed in rather than read, because a duration decided inside a view is a duration
    ///     nothing can test.
    ///   - opened: the subagent whose output pane is open, if it is one of these.
    public static func rows(
        _ roster: SubagentRoster, now: Date, opened: SubagentID? = nil
    ) -> [SubagentRow] {
        var failuresKept = 0
        return roster.subagents.compactMap { subagent in
            guard keeps(subagent, now: now, opened: opened, failuresKept: &failuresKept) else {
                return nil
            }
            return SubagentRow(subagent, now: now)
        }
    }

    /// How many of this turn's subagents failed, whether or not they still have a row.
    ///
    /// What the workspace row says, and the reason the cap above is safe: the count is of every
    /// failure, so the three crosses and the number never disagree about how bad it was. Every
    /// failure this pane would ever draw, that is: a background command has no row here, so
    /// counting one would put a number on the workspace row that nothing under it explains.
    public static func failureCount(_ roster: SubagentRoster) -> Int {
        roster.subagents.count { $0.kind == .agent && $0.state == .failed }
    }

    /// When the row set next changes on its own, or nil when nothing is on a clock.
    ///
    /// Rows are recomputed when a line arrives about a subagent, and a row leaving is the one
    /// change no line announces: the last thing that happens to a successful subagent is the
    /// notification that finished it. Without this, the row would sit there until the next tick
    /// of some other subagent, or for ever if it was the last one working.
    public static func nextChange(
        _ roster: SubagentRoster, now: Date, opened: SubagentID? = nil
    ) -> Date? {
        var failuresKept = 0
        var earliest: Date?
        var isAnyoneWorking = false
        for subagent in roster.subagents {
            guard keeps(subagent, now: now, opened: opened, failuresKept: &failuresKept) else {
                continue
            }
            if subagent.state == .running { isAnyoneWorking = true }
            guard let expiry = expiry(of: subagent, opened: opened) else { continue }
            earliest = min(earliest ?? expiry, expiry)
        }
        // **A running row moves on its own too, and that is the second thing no line announces.**
        // The readout counts seconds off `SubagentRow.detail`, and `tool_progress` was supposed
        // to be what made it move; a fan-out arrived with no ticks at all and the readout stood
        // still, so a caller that only recomputed on a line drew a row that had been "working"
        // for four minutes without saying so. One second, because that is the unit the readout is
        // in and there is no point waking sooner. The caller's own equality check is what keeps
        // this cheap: a tick that changes nothing the row says writes nothing.
        if isAnyoneWorking {
            let tick = now.addingTimeInterval(1)
            earliest = min(earliest ?? tick, tick)
        }
        return earliest
    }

    /// Whether this row is still drawn. `failuresKept` is carried across the walk so the cap
    /// counts crosses on screen rather than failures in the roster.
    private static func keeps(
        _ subagent: Subagent, now: Date, opened: SubagentID?, failuresKept: inout Int
    ) -> Bool {
        // A backgrounded shell command never has a row. Both arrive on `system/task_started` and
        // `SubagentKind` is what tells them apart, so the pane had been drawing whichever the CLI
        // happened to start: three lines reading `agent-browser set viewport 1440 900 >/dev/null`
        // under a workspace, two of them crossed, which is a shell log in a navigation pane. What
        // this pane is for is the other AI working on the workspace, and a command is not one.
        // The roster still holds them and the transcript still draws their panes, both unchanged:
        // the command's output is worth reading, it is just not worth a permanent row beside the
        // workspace it was run in.
        guard subagent.kind == .agent else { return false }

        if subagent.state == .failed {
            let kept = subagent.id == opened || failuresKept < failureLimit
            if kept { failuresKept += 1 }
            return kept
        }
        guard let expiry = expiry(of: subagent, opened: opened) else { return true }
        return now < expiry
    }

    /// When this row runs out, or nil when it is not on a clock at all: still running, opened, or
    /// finished without the CLI ever saying when.
    private static func expiry(of subagent: Subagent, opened: SubagentID?) -> Date? {
        guard subagent.state != .running, subagent.id != opened else { return nil }
        guard subagent.state != .failed else { return nil }
        guard let finishedAt = subagent.finishedAt else { return nil }
        return finishedAt.addingTimeInterval(lingerSeconds)
    }
}
