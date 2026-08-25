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
@MainActor
enum IdleProbe {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--idle-probe")
    }

    // MARK: - Arguments

    private static func value(for flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static var outputPath: String {
        value(for: "--idle-probe") ?? (NSTemporaryDirectory() + "bloom-idle-probe.json")
    }

    private static var base: String { value(for: "--idle-base") ?? "main" }
    private static var passes: Int { Int(value(for: "--idle-passes") ?? "") ?? 5 }

    private static var worktrees: [String] {
        guard let path = value(for: "--idle-worktrees"),
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
        // Not brought to the front, for the reason at the head of `FrameProbe`.
        try? await Task.sleep(for: .seconds(3))

        let trees = worktrees
        guard !trees.isEmpty else { return fail("no worktrees to probe") }

        // A warm pass that is thrown away. The first one pays for `Shell.which` walking PATH, for
        // git's own caches and for every baseline being worked out for the first time, and
        // reporting that as the steady state would overstate the cost of a loop that has been
        // running all day.
        _ = await pass(trees)

        var reports: [[String: Any]] = []
        for _ in 0..<passes {
            reports.append(await pass(trees))
        }

        write([
            "worktrees": trees.count,
            "base": base,
            "passes": reports,
            "median": [
                "wallMs": median(reports.map { $0["wallMs"] as? Double ?? 0 }),
                "cpuMs": median(reports.map { $0["cpuMs"] as? Double ?? 0 }),
                "spawns": median(reports.map { Double($0["spawns"] as? Int ?? 0) }),
                "spawnsPerWorktree": median(
                    reports.map { Double($0["spawns"] as? Int ?? 0) / Double(trees.count) }
                ),
            ],
        ])
        exit(0)
    }

    /// One sweep of `Git.diffStat` over every worktree, exactly as `AppModel.refreshDiffStats`
    /// runs it: one at a time, because that is what the loop does and a concurrent sweep would
    /// measure how many cores this Mac has rather than what the loop costs.
    private static func pass(_ trees: [String]) async -> [String: Any] {
        let spawnsBefore = Shell.spawnCount
        let cpuBefore = ProcessCPU.read()
        let wallBefore = CACurrentMediaTime()

        for tree in trees {
            _ = try? await Git.diffStat(worktree: tree, base: base)
        }

        let wall = (CACurrentMediaTime() - wallBefore) * 1000
        let cpu = ProcessCPU.read() - cpuBefore
        return [
            "wallMs": wall,
            "cpuMs": cpu.total * 1000,
            "selfCpuMs": cpu.own * 1000,
            "childCpuMs": cpu.children * 1000,
            "spawns": Shell.spawnCount - spawnsBefore,
        ]
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Reporting

    private static func fail(_ reason: String) {
        write(["error": reason])
        exit(1)
    }

    private static func write(_ report: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: outputPath))
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
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
