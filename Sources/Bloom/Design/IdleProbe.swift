import AppKit
import Foundation
import QuartzCore
import BloomCore

/// Measures what Bloom costs while nothing is happening.
///
/// The fifth of the family, after `FrameProbe`, `SwitchProbe`, `TabProbe` and `ScrollProbe`. All
/// four of those measure a moment somebody caused: a drag, a switch, a tab, a flick. **None of
/// them measures the idle case**, and idle is the one the battery menu complains about. An app
/// listed under "Using Significant Energy" is usually one doing work when nothing is happening,
/// and until this existed the only evidence available was the battery menu itself, which is a
/// verdict rather than a number.
///
/// # What it measures, and why it is not the timer
///
/// It drives the same pass the six second diff stat loop drives, `Git.diffStat` over a list of
/// worktrees, and reports the process time, the wall time and the subprocess count of each pass.
///
/// It drives that pass itself rather than waiting for the loop to fire it, and the reason is the
/// owner. The loop stands down whenever the window is not frontmost (`NSApp.isActive`), so a probe
/// that waited for it would have to bring Bloom to the front, and taking the front from somebody
/// working at this Mac is not a step in a measurement. See "Do not take over the machine" in
/// `CLAUDE.md`. What is left is the work itself, which is what the loop would have done and what
/// the fix has to make cheaper.
///
/// # Why the subprocess count is taken from inside
///
/// Because it cannot be taken from outside. Polling `ps` at 20Hz for a minute against the running
/// app saw nine children, which reads as an app at rest; a `git rev-parse` lives for about ten
/// milliseconds, so a sampler at that rate misses most of them. `Shell.spawnCount` is incremented
/// where the process is actually started and cannot miss one.
///
/// The children's CPU is reported separately from this process's own, because that is the whole
/// story here: Bloom's own thread barely moves while it burns a second of `git` every six.
/// `RUSAGE_CHILDREN` is only counted for children that have been reaped, which every `Shell.run`
/// waits for, so the number is complete by the time a pass has finished.
///
/// # What it answered
///
/// Seventeen of this machine's real worktrees, seven passes, median. The loop used to hand a pass
/// every workspace in the sidebar and now hands it the two or three `DiffRefreshSchedule` says are
/// due:
///
///     seventeen worktrees   104 processes   2,864ms of process time
///     three worktrees        12 processes     651ms
///
/// A pass every six seconds is 48% of a core against 11%. The `git rev-parse` cache under
/// `BaselineCache` shows up in the same probe as 6.12 processes per worktree against 4.00, with
/// the process time unmoved, which is how it was found not to be the fix.
///
///     Bloom --idle-probe /tmp/idle.json --idle-worktrees /tmp/trees.txt
///           [--idle-base main] [--idle-passes 5]
///
/// `--idle-worktrees` is a file with one worktree path per line, which is how a run needs no
/// database and cannot touch the owner's. `ls -d ~/bloom/workspaces/*/*/ > /tmp/trees.txt` is the
/// list this was written against.
///
/// It is the one probe in the family with no window in it, so `ProbeHarness` gives it the flags,
/// the settle, the failure and the report and nothing else.
@MainActor
enum IdleProbe {
    private static let harness = ProbeHarness(subject: "idle")

    static var isRequested: Bool { harness.isRequested }

    // MARK: - Arguments

    private static var base: String { ProbeHarness.text("--idle-base", or: "main") }
    private static var passes: Int { ProbeHarness.count("--idle-passes", or: 5) }

    private static var worktrees: [String] {
        guard let path = ProbeHarness.value(for: "--idle-worktrees"),
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { FileManager.default.fileExists(atPath: $0 + "/.git") }
    }

    // MARK: - Entry

    static func schedule() {
        Task { @MainActor in await run() }
    }

    private static func run() async {
        // Not brought to the front, for the reason at the head of `ProbeHarness.window`. This one
        // waits without a window to wait for: what it measures is the work, and a launch's own
        // git reads landing inside the first pass would be counted as the loop's.
        await harness.settle()

        let trees = worktrees
        guard !trees.isEmpty else { harness.fail("no worktrees to probe") }

        // A warm pass that is thrown away. The first one pays for `Shell.which` walking PATH, for
        // git's own caches and for every baseline being worked out for the first time, and
        // reporting that as the steady state would overstate the cost of a loop that has been
        // running all day.
        _ = await pass(trees)

        var runs: [Pass] = []
        for _ in 0..<passes {
            runs.append(await pass(trees))
        }

        let own: [String: JSONValue] = [
            "worktrees": .integer(trees.count),
            "base": .string(base),
            "passes": .array(runs.map(\.json)),
            "median": .object([
                "wallMs": .number(median(runs.map(\.wallMs))),
                "cpuMs": .number(median(runs.map { $0.cpu.total * 1000 })),
                "spawns": .number(median(runs.map { Double($0.spawns) })),
                "spawnsPerWorktree": .number(
                    median(runs.map { Double($0.spawns) / Double(trees.count) })
                ),
            ]),
        ]
        // Echoed as well as written, because a run of this one is short and is driven from a shell
        // that never opens the file.
        harness.write(
            .object(own.merging(harness.conditions(window: nil)) { mine, _ in mine }), echo: true
        )
        exit(0)
    }

    /// What one pass cost.
    ///
    /// A type rather than the `[String: Any]` this used to be. The medians above read every one of
    /// these numbers back out again, and they used to do it with a string key, a dynamic cast and
    /// a `?? 0`, so a key renamed on one line and not on the other would have reported nought for
    /// the whole run without a word to anybody.
    private struct Pass {
        var wallMs: Double
        var cpu: ProcessCPU.Sample
        var spawns: Int

        var json: JSONValue {
            .object([
                "wallMs": .number(wallMs),
                "cpuMs": .number(cpu.total * 1000),
                "selfCpuMs": .number(cpu.own * 1000),
                "childCpuMs": .number(cpu.children * 1000),
                "spawns": .integer(spawns),
            ])
        }
    }

    /// One sweep of `Git.diffStat` over every worktree, exactly as `AppModel.refreshDiffStats`
    /// runs it: one at a time, because that is what the loop does and a concurrent sweep would
    /// measure how many cores this Mac has rather than what the loop costs.
    private static func pass(_ trees: [String]) async -> Pass {
        let spawnsBefore = Shell.spawnCount
        let cpuBefore = ProcessCPU.read()
        let wallBefore = CACurrentMediaTime()

        for tree in trees {
            _ = try? await Git.diffStat(worktree: tree, base: base)
        }

        return Pass(
            wallMs: (CACurrentMediaTime() - wallBefore) * 1000,
            cpu: ProcessCPU.read() - cpuBefore,
            spawns: Shell.spawnCount - spawnsBefore
        )
    }

    /// The same middle value the rest of the family reports, taken the same way. It used to be
    /// `sorted[count / 2]` here and a rank in the other two, which agreed and said so nowhere;
    /// `ProbeStatsTests` is where that is now written down.
    private static func median(_ values: [Double]) -> Double {
        ProbeStats.percentile(0.5, of: values.sorted())
    }
}

/// The process time this app and the children it has reaped have used, in seconds.
///
/// `getrusage` rather than `task_info`, because the children are half the answer and only
/// `RUSAGE_CHILDREN` has them. A pass that spawns four hundred `git` processes moves this app's
/// own line hardly at all and the children's line by most of a second, and reporting only the
/// first is how an app that is burning a battery looks innocent in a profile.
enum ProcessCPU {
    struct Sample {
        var own: Double
        var children: Double

        var total: Double { own + children }

        static func - (lhs: Sample, rhs: Sample) -> Sample {
            Sample(own: lhs.own - rhs.own, children: lhs.children - rhs.children)
        }
    }

    static func read() -> Sample {
        Sample(own: seconds(of: RUSAGE_SELF), children: seconds(of: RUSAGE_CHILDREN))
    }

    private static func seconds(of who: Int32) -> Double {
        var usage = rusage()
        guard getrusage(who, &usage) == 0 else { return 0 }
        return interval(usage.ru_utime) + interval(usage.ru_stime)
    }

    private static func interval(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
}
