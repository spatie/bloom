import Foundation

/// Asks a server what it has, in one round trip, and reads the answer.
///
/// **One round trip is the requirement, not an optimisation.** Six `command -v` calls over six
/// SSH channels is six network waits before anything has been decided, and the whole reason for
/// `ControlMaster` is that a network wait is the expensive thing here. So the questions go over as
/// a shell script on stdin, the answers come back as one stream of tab separated lines, and the
/// only work left on this side is parsing.
///
/// **The script runs on the server and the parsing runs here, and the split is deliberate.**
/// Anything that varies between distributions is answered on the far end, where the machine
/// knows: `df` has a POSIX mode so the shell does the arithmetic, `/etc/os-release` is read where
/// it exists, `uname` answers where it does not. What crosses is already normalised, so this
/// parser has one format to read rather than one per distribution, and that format is what the
/// tests are written against.
public struct ServerProbe: Sendable {
    /// The script's own format. Bumped when a line changes shape, so an old server answering a new
    /// Bloom is a sentence rather than a mis-read field.
    public static let format = 1

    /// Long enough for a cold machine to page in six binaries and answer, short enough that
    /// somebody watching a spinner gives up after it rather than before.
    public static let timeout = Duration.seconds(20)

    private let runner: any CommandRunning

    public init(runner: any CommandRunning) {
        self.runner = runner
    }

    /// One round trip, parsed.
    public func run() async throws -> ServerFacts {
        let result = try await runner.run(.script(Self.script, timeout: Self.timeout))
        return try Self.parse(result.stdout)
    }

    // MARK: - The script

    /// What runs on the server. POSIX `sh`, no `bash`, nothing installed.
    ///
    /// **The PATH prelude is the day-one problem, and the obvious fix for it does not work.**
    /// Measured on a stock Ubuntu 26.04 with node installed through `nvm` and Claude Code
    /// installed through that node's `npm`:
    ///
    ///     ssh root@host 'claude --version'              bash: claude: command not found   (127)
    ///     ssh root@host 'bash -lc "claude --version"'   bash: claude: command not found   (127)
    ///     ssh root@host 'bash -ic "claude --version"'   2.1.247 (Claude Code)             (0)
    ///
    /// A LOGIN shell is not enough. `nvm` appends its lines to `~/.bashrc`, and Ubuntu's
    /// `~/.bashrc` opens with `case $- in *i*) ;; *) return;; esac`, so it returns immediately
    /// when there is no tty however it was reached. Only an INTERACTIVE shell gets there, and
    /// asking for one over SSH means a pty, two lines of "cannot set terminal process group" on
    /// stderr, and the user's whole prompt and profile running before every command Bloom sends.
    ///
    /// So the prelude does the looking itself. It knows where the version managers put things,
    /// the original PATH is reported alongside as `loginpath` so the screen can say that a tool
    /// needed the help, and nothing here sources a file the user wrote. Measured against the same
    /// server, the prelude found `claude` at
    /// `/root/.nvm/versions/node/v22.23.2/bin/claude`.
    ///
    /// Every command is `2>/dev/null`'d or has its status caught, because a probe that dies on the
    /// first missing thing tells you nothing about the second.
    public static let script = #"""
        # Bloom's server probe. Reads, never writes. One line per fact, tab separated.
        BLOOM_LOGIN_PATH="$PATH"

        # The version managers, which put their binaries behind a directory whose name is the
        # version. Globbed rather than listed, and a glob that matches nothing leaves the pattern
        # itself, which the -d test then rejects.
        for candidate in "$HOME"/.nvm/versions/node/*/bin \
                         "$HOME"/.local/share/fnm/node-versions/*/installation/bin \
                         "$HOME"/.asdf/shims \
                         "$HOME"/.local/share/pnpm; do
            [ -d "$candidate" ] && PATH="$candidate:$PATH"
        done
        PATH="$HOME/.local/bin:$HOME/bin:$HOME/.npm-global/bin:$HOME/.npm-packages/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.volta/bin:$HOME/.yarn/bin:/usr/local/bin:/opt/homebrew/bin:/snap/bin:$PATH"
        export PATH

        printf 'bloom-probe\t%s\n' '\#(format)'
        printf 'arch\t%s\n' "$(uname -m 2>/dev/null)"
        printf 'system\t%s\n' "$(uname -s 2>/dev/null)"

        # What the machine calls itself. Every mainstream Linux has /etc/os-release and nothing
        # else does, so the two fallbacks are a Mac and then whatever uname will say.
        os=''
        if [ -r /etc/os-release ]; then
            os=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-}}")
        fi
        if [ -z "$os" ] && command -v sw_vers >/dev/null 2>&1; then
            os="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"
        fi
        [ -z "$os" ] && os=$(uname -sr 2>/dev/null)
        printf 'os\t%s\n' "$os"

        printf 'home\t%s\n' "$HOME"
        printf 'loginpath\t%s\n' "$BLOOM_LOGIN_PATH"
        printf 'path\t%s\n' "$PATH"

        # A binary that hangs on --version would hang the probe, so it is given ten seconds where
        # the server has `timeout` to give it. Unquoted on purpose: an empty variable has to
        # disappear rather than become an empty first argument.
        limit=''
        command -v timeout >/dev/null 2>&1 && limit='timeout 10'

        # Each entry is `name:flag`, because the flag is not the same for all of them: tmux
        # answers -V and exits 1 on --version. Split with the shell's own prefix and suffix
        # removal, which is POSIX and needs no `cut`.
        for entry in \#(displayOrderList); do
            tool=${entry%%:*}
            flag=${entry#*:}
            found=$(command -v "$tool" 2>/dev/null) || found=''
            if [ -z "$found" ]; then
                printf 'tool\t%s\t-\t127\t\n' "$tool"
                continue
            fi
            # shellcheck disable=SC2086
            out=$($limit "$found" "$flag" 2>&1)
            status=$?
            # First line only, tabs flattened, so one field cannot become two.
            line=$(printf '%s' "$out" | tr -d '\r' | tr '\t' ' ' | sed -n '1p')
            printf 'tool\t%s\t%s\t%s\t%s\n' "$tool" "$found" "$status" "$line"
        done

        # -P is POSIX output: one line per filesystem whatever the device name's length, and the
        # columns in a fixed order. -k makes them 1024 byte blocks on every implementation, so the
        # arithmetic is done here and what crosses is bytes.
        df -Pk "$HOME" 2>/dev/null |
            awk 'NR == 2 { printf "disk\t%s\t%.0f\t%.0f\n", $6, $4 * 1024, $2 * 1024 }'

        # Asked for by running it, not by reading the file, because what matters is the version
        # the server would actually execute.
        daemon="$HOME/.bloom/bin/bloomd"
        if [ -r "$daemon" ] && command -v python3 >/dev/null 2>&1; then
            reported=$(python3 "$daemon" version 2>/dev/null) || reported=''
            printf 'bloomd\t%s\t%s\n' "$daemon" "${reported:--}"
        else
            printf 'bloomd\t-\t-\n'
        fi

        # The sentinel. A connection cut half way through leaves plausible output with this line
        # missing, and a probe that reported six missing tools because the link dropped would be
        # the worst kind of wrong: confident.
        printf 'end\n'
        """#

    /// `name:flag` per tool, in reading order, for the loop in the script above.
    private static var displayOrderList: String {
        ServerTool.displayOrder
            .map { "\($0.executableName):\($0.versionFlag)" }
            .joined(separator: " ")
    }

    // MARK: - Reading it back

    public enum Trouble: Error, Sendable, Hashable, CustomStringConvertible {
        case notAProbe(String)
        case truncated
        case fromTheFuture(Int)

        public var description: String {
            switch self {
            case .notAProbe(let head):
                head.isEmpty
                    ? "The server answered with nothing."
                    : "The server answered with something that is not a probe: \(head)"
            case .truncated:
                "The answer stopped part way through, so the connection dropped mid-probe."
            case .fromTheFuture(let version):
                "This server answered in probe format \(version) and this Bloom reads \(format)."
            }
        }
    }

    /// Reads the probe's output.
    ///
    /// Unknown lines are ignored rather than refused, which is what makes a newer script safe to
    /// put on an older Bloom: the format number covers a line that CHANGED, and a line that was
    /// merely added needs no ceremony at all.
    public static func parse(_ output: String) throws -> ServerFacts {
        let lines = output.components(separatedBy: "\n")
        guard let header = lines.first(where: { $0.hasPrefix("bloom-probe\t") }) else {
            let head = output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
            throw Trouble.notAProbe(String(head))
        }
        let version = Int(field(header, 1) ?? "") ?? 0
        guard version <= format else { throw Trouble.fromTheFuture(version) }
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "end" }) else {
            throw Trouble.truncated
        }

        var facts = ServerFacts(formatVersion: version)
        var tools: [ServerTool: (state: ServerToolState, directory: String?)] = [:]

        for line in lines {
            let parts = line.components(separatedBy: "\t")
            guard let key = parts.first else { continue }
            switch key {
            case "arch": facts.architecture = parts.value(1)
            case "system": facts.system = parts.value(1)
            case "os": facts.osName = parts.value(1)
            case "home": facts.home = parts.value(1)
            case "loginpath": facts.loginPath = parts.value(1)
            case "path": facts.searchPath = parts.value(1)
            case "disk":
                facts.diskMount = parts.value(1)
                facts.diskAvailableBytes = Int64(parts.value(2)) ?? 0
                facts.diskTotalBytes = Int64(parts.value(3)) ?? 0
            case "bloomd":
                let reported = parts.value(2)
                facts.bloomdVersion = (reported.isEmpty || reported == "-") ? nil : reported
            case "tool":
                guard let tool = ServerTool(rawValue: parts.value(1)) else { continue }
                tools[tool] = readTool(parts)
            default:
                continue
            }
        }

        // The login PATH split once, rather than per tool, because the answer is the same for all
        // six and the list is long on a machine with several version managers.
        let loginDirectories = Set(facts.loginPath.components(separatedBy: ":").filter { !$0.isEmpty })
        facts.findings = ServerTool.displayOrder.map { tool in
            guard let found = tools[tool] else {
                return ServerToolFinding(tool: tool, state: .missing)
            }
            let helped = found.directory.map { !loginDirectories.contains($0) } ?? false
            return ServerToolFinding(tool: tool, state: found.state, needsPathHelp: helped)
        }
        return facts
    }

    /// One `tool` line: name, path, exit status, first line of what it printed.
    ///
    /// **A non-zero status with a real path is not "missing".** That is a `codex` whose Node is
    /// too old, or a `git` on a filesystem mounted without exec, and the fix for either is not the
    /// install command. 127 with no path is the only shape that means missing, and it is the shape
    /// the script prints when `command -v` came back empty.
    private static func readTool(_ parts: [String]) -> (state: ServerToolState, directory: String?) {
        let path = parts.value(2)
        let status = Int(parts.value(3)) ?? 0
        let detail = parts.count > 4
            ? parts[4...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            : ""

        guard !path.isEmpty, path != "-" else { return (.missing, nil) }
        let directory = (path as NSString).deletingLastPathComponent
        guard status == 0 else {
            return (.broken(path: path, detail: reason(status: status, detail: detail)), directory)
        }
        return (.present(path: path, version: AgentCatalog.parseVersion(detail)), directory)
    }

    /// Turns what the probe captured into a sentence about the TOOL rather than about the probe.
    ///
    /// **The script runs each binary under `timeout`, and `timeout` reports its own failures in
    /// its own name.** A `codex` whose shebang points at an nvm node version that has been
    /// removed, which is the commonest way a CLI on a server stops working, comes back as
    /// `timeout: failed to execute process: No such file or directory (os error 2)` with status
    /// 127. Printed as it stands, that row tells somebody their tool timed out, which is not what
    /// happened and sends them looking in the wrong place. Measured on a real server, which is
    /// the only reason this is here at all.
    private static func reason(status: Int, detail: String) -> String {
        // 124 is `timeout`'s own "I killed it", and there the word timeout is the truth.
        if status == 124 {
            return "it did not answer within ten seconds"
        }
        let prefix = "timeout: failed to execute process: "
        if detail.hasPrefix(prefix) {
            return "it could not be started: " + String(detail.dropFirst(prefix.count))
        }
        if detail.hasPrefix("timeout: ") {
            return String(detail.dropFirst("timeout: ".count))
        }
        return detail.isEmpty ? "exited \(status)" : detail
    }

    private static func field(_ line: String, _ index: Int) -> String? {
        let parts = line.components(separatedBy: "\t")
        return parts.indices.contains(index) ? parts[index] : nil
    }
}

private extension [String] {
    /// The field at `index`, or an empty string, so a short line reads as blank rather than
    /// crashing. A probe answer is bytes off a network and is never trusted to have every column.
    func value(_ index: Int) -> String {
        indices.contains(index) ? self[index].trimmingCharacters(in: .whitespaces) : ""
    }
}
