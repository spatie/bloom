import Testing
import Foundation
@testable import BloomCore

/// Reading a probe's answer.
///
/// **Both fixtures below are real output**, captured from the probe script in `ServerProbe.script`
/// running unchanged against a real Ubuntu 26.04 VPS and against a Mac. Nothing here was written
/// by hand to suit the parser, which is the point: the first version of this parser was written
/// against invented output and the real server disagreed with it twice in the first minute.
@Suite("Server probe")
struct ServerProbeTests {
    // MARK: - The fixtures

    /// Ubuntu 26.04 LTS, x86_64. Node installed with `nvm`, Claude Code installed with that
    /// node's `npm`, `gh` genuinely absent, and a `codex` whose shebang points at an nvm node
    /// version that has been removed, which is the commonest way a CLI on a server stops working.
    static let ubuntu = [
        "bloom-probe\t1",
        "arch\tx86_64",
        "system\tLinux",
        "os\tUbuntu 26.04 LTS",
        "home\t/root",
        "loginpath\t/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:"
            + "/usr/local/games:/snap/bin",
        "path\t/root/.local/bin:/root/bin:/root/.npm-global/bin:/root/.npm-packages/bin:"
            + "/root/.bun/bin:/root/.cargo/bin:/root/.volta/bin:/root/.yarn/bin:/usr/local/bin:"
            + "/opt/homebrew/bin:/snap/bin:/root/.nvm/versions/node/v22.23.2/bin:"
            + "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:"
            + "/usr/local/games:/snap/bin",
        "tool\tgit\t/usr/bin/git\t0\tgit version 2.53.0",
        "tool\tpython3\t/usr/bin/python3\t0\tPython 3.14.4",
        "tool\tclaude\t/root/.nvm/versions/node/v22.23.2/bin/claude\t0\t2.1.247 (Claude Code)",
        "tool\tcodex\t/root/.local/bin/codex\t127\ttimeout: failed to execute process: "
            + "No such file or directory (os error 2)",
        "tool\tgh\t-\t127\t",
        "tool\ttmux\t/usr/bin/tmux\t0\ttmux 3.6",
        "disk\t/\t14309515264\t26320232448",
        "bloomd\t/root/.bloom/bin/bloomd\t1",
        "end",
    ].joined(separator: "\n") + "\n"

    /// A Mac, which is the distribution that words everything differently: no `/etc/os-release`,
    /// so the version comes from `sw_vers`; `arm64` rather than `aarch64`; and a `df` whose data
    /// volume is not mounted at `/`. The two PATH values are the real ones with the middle cut
    /// out, because the real ones are four thousand characters long.
    static let mac = [
        "bloom-probe\t1",
        "arch\tarm64",
        "system\tDarwin",
        "os\tmacOS 27.0",
        "home\t/Users/someone",
        "loginpath\t/Users/someone/.bun/bin:/Users/someone/.local/bin:/opt/homebrew/bin:"
            + "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "path\t/Users/someone/.local/bin:/Users/someone/bin:/Users/someone/.npm-global/bin:"
            + "/Users/someone/.npm-packages/bin:/usr/local/bin:/opt/homebrew/bin:"
            + "/Users/someone/.local/share/fnm/node-versions/v24.13.0/installation/bin:"
            + "/usr/bin:/bin:/usr/sbin:/sbin",
        "tool\tgit\t/usr/bin/git\t0\tgit version 2.50.1 (Apple Git-155)",
        "tool\tpython3\t/opt/homebrew/bin/python3\t0\tPython 3.14.3",
        "tool\tclaude\t/Users/someone/.local/bin/claude\t0\t2.1.247 (Claude Code)",
        "tool\tcodex\t/Users/someone/.npm-packages/bin/codex\t0\tcodex-cli 0.149.1",
        "tool\tgh\t/opt/homebrew/bin/gh\t0\tgh version 2.88.1 (2026-03-12)",
        "tool\ttmux\t/opt/homebrew/bin/tmux\t0\ttmux 3.6a",
        "disk\t/System/Volumes/Data\t108592992256\t1995218165760",
        "bloomd\t-\t-",
        "end",
    ].joined(separator: "\n") + "\n"

    // MARK: - The machine

    @Test("the machine's own facts")
    func machineFacts() throws {
        let facts = try ServerProbe.parse(Self.ubuntu)
        #expect(facts.formatVersion == 1)
        #expect(facts.architecture == "x86_64")
        #expect(facts.system == "Linux")
        #expect(facts.osName == "Ubuntu 26.04 LTS")
        #expect(facts.home == "/root")
        #expect(facts.diskMount == "/")
        #expect(facts.diskAvailableBytes == 14_309_515_264)
        #expect(facts.diskTotalBytes == 26_320_232_448)
        #expect(facts.bloomdVersion == "1")
    }

    /// A Mac has no `/etc/os-release` and its data volume is not at `/`. The same parser, because
    /// everything that varies was answered on the far end.
    @Test("a distribution that words things differently")
    func macFacts() throws {
        let facts = try ServerProbe.parse(Self.mac)
        #expect(facts.architecture == "arm64")
        #expect(facts.system == "Darwin")
        #expect(facts.osName == "macOS 27.0")
        #expect(facts.diskMount == "/System/Volumes/Data")
        #expect(facts.diskAvailableBytes == 108_592_992_256)
        #expect(facts.bloomdVersion == nil)
    }

    // MARK: - The tools

    @Test("a tool that is there gives its path and its version")
    func present() throws {
        let facts = try ServerProbe.parse(Self.ubuntu)
        #expect(facts.state(of: .git) == .present(path: "/usr/bin/git", version: "2.53.0"))
        #expect(facts.state(of: .python3) == .present(path: "/usr/bin/python3", version: "3.14.4"))
        #expect(facts.state(of: .tmux) == .present(path: "/usr/bin/tmux", version: "3.6"))
    }

    /// `tmux --version` exits 1 with "tmux: unknown option -- -", which is how a perfectly good
    /// tmux 3.6 was first reported as installed and broken. The flag is per tool now.
    @Test("tmux answers -V, not --version")
    func tmuxVersionFlag() {
        #expect(ServerTool.tmux.versionFlag == "-V")
        for tool in ServerTool.allCases where tool != .tmux {
            #expect(tool.versionFlag == "--version")
        }
    }

    @Test("a tool that is not installed is missing, and nothing else")
    func missing() throws {
        let facts = try ServerProbe.parse(Self.ubuntu)
        #expect(facts.state(of: .gh) == .missing)
        #expect(facts.state(of: .gh).path == nil)
        #expect(facts.finding(for: .gh)?.needsPathHelp == false)
    }

    /// **The state a boolean would round to "missing", and the one with a different fix.** This is
    /// a real broken `codex`: installed, on PATH, and its interpreter is gone.
    @Test("a tool that is there and does not run is broken, not missing")
    func broken() throws {
        let facts = try ServerProbe.parse(Self.ubuntu)
        let state = facts.state(of: .codex)
        #expect(state.isBroken)
        #expect(state.path == "/root/.local/bin/codex")
        #expect(state.version == nil)
        // And the message names the tool rather than `timeout`, which is what the probe happened
        // to run it under and which nobody asked for.
        guard case .broken(_, let detail) = state else {
            Issue.record("expected broken, got \(state)")
            return
        }
        #expect(detail == "it could not be started: No such file or directory (os error 2)")
        #expect(!detail.hasPrefix("timeout:"))
    }

    /// **The day-one problem, as it actually presents.** `claude` is installed and works, and a
    /// plain `ssh root@host claude` cannot find it, because nvm's lines live in `~/.bashrc` and
    /// Ubuntu's `~/.bashrc` returns immediately when there is no tty. Measured: `bash -lc` does
    /// not fix it either. So the probe widens PATH itself and says which tools needed the help.
    @Test("a tool only the widened PATH could find is flagged")
    func needsPathHelp() throws {
        let facts = try ServerProbe.parse(Self.ubuntu)
        #expect(facts.state(of: .claude).path == "/root/.nvm/versions/node/v22.23.2/bin/claude")
        #expect(facts.finding(for: .claude)?.needsPathHelp == true)
        // git is in /usr/bin, which the login PATH already had.
        #expect(facts.finding(for: .git)?.needsPathHelp == false)
        #expect(facts.finding(for: .python3)?.needsPathHelp == false)
    }

    // MARK: - What it adds up to

    /// The welcome window's four rows, out of the six looked for here, so the same drawing and the
    /// same verdict rules serve both screens.
    @Test("it resolves into the welcome window's SetupReport")
    func setupReport() throws {
        let report = try ServerProbe.parse(Self.ubuntu).setupReport
        #expect(report.outcome(for: .git) == .ready(detail: "2.53.0"))
        #expect(report.outcome(for: .claudeCode) == .ready(detail: "2.1.247"))
        #expect(report.outcome(for: .gitHub) == .missing)
        #expect(report.hasRunnableAgent)
        // git is there and one agent is there, so the machine is not blocked. The broken codex
        // and the absent gh are notes.
        #expect(report.verdict == .readyWithNotes)
        #expect(report.severity(for: .gitHub) == .note)
    }

    @Test("git and python3 together are what makes a server usable")
    func canHostWorkspaces() throws {
        #expect(try ServerProbe.parse(Self.ubuntu).canHostWorkspaces)

        let noPython = Self.ubuntu.replacingOccurrences(
            of: "tool\tpython3\t/usr/bin/python3\t0\tPython 3.14.4",
            with: "tool\tpython3\t-\t127\t"
        )
        #expect(try !ServerProbe.parse(noPython).canHostWorkspaces)
    }

    // MARK: - Answers that are not answers

    /// A connection cut half way through leaves plausible output with the sentinel missing. A
    /// probe that reported six missing tools because the link dropped would be confidently wrong,
    /// which is the worst kind.
    @Test("a truncated answer is refused rather than half believed")
    func truncated() {
        let cut = Self.ubuntu.components(separatedBy: "\n").prefix(9).joined(separator: "\n")
        #expect(throws: ServerProbe.Trouble.truncated) { try ServerProbe.parse(cut) }
    }

    @Test("output that is not a probe at all is quoted back")
    func notAProbe() {
        #expect(throws: ServerProbe.Trouble.notAProbe("")) { try ServerProbe.parse("") }
        #expect(throws: ServerProbe.Trouble.notAProbe("This account is restricted.")) {
            try ServerProbe.parse("This account is restricted.\n")
        }
    }

    @Test("a newer script than this Bloom reads says so")
    func fromTheFuture() {
        let newer = Self.ubuntu.replacingOccurrences(of: "bloom-probe\t1", with: "bloom-probe\t99")
        #expect(throws: ServerProbe.Trouble.fromTheFuture(99)) { try ServerProbe.parse(newer) }
    }

    /// A line the parser does not know is ignored rather than refused, which is what makes adding
    /// a fact to the script safe without bumping the format.
    @Test("an unknown line is ignored")
    func unknownLine() throws {
        let extra = Self.ubuntu.replacingOccurrences(
            of: "disk\t",
            with: "somethingnew\tvalue\ndisk\t"
        )
        let facts = try ServerProbe.parse(extra)
        #expect(facts.diskAvailableBytes == 14_309_515_264)
    }

    /// A short line is bytes off a network and is never trusted to have every column.
    @Test("a truncated field reads as blank rather than crashing")
    func shortLine() throws {
        let ragged = Self.ubuntu.replacingOccurrences(
            of: "disk\t/\t14309515264\t26320232448",
            with: "disk\t/"
        ).replacingOccurrences(of: "tool\ttmux\t/usr/bin/tmux\t0\ttmux 3.6", with: "tool\ttmux")
        let facts = try ServerProbe.parse(ragged)
        #expect(facts.diskAvailableBytes == 0)
        #expect(facts.state(of: .tmux) == .missing)
    }

    // MARK: - The script itself

    /// The script is generated from `ServerTool.displayOrder`, so a tool added to the enum is
    /// looked for without anybody editing shell.
    @Test("every tool reaches the script with its own version flag")
    func scriptCoversEveryTool() {
        for tool in ServerTool.displayOrder {
            #expect(ServerProbe.script.contains("\(tool.executableName):\(tool.versionFlag)"))
        }
        // And the prelude looks where the version managers actually put things, which is the
        // whole reason a tool installed under nvm is findable at all.
        #expect(ServerProbe.script.contains(".nvm/versions/node/*/bin"))
        #expect(ServerProbe.script.contains("printf 'end\\n'"))
    }
}
