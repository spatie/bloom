import Foundation

/// Every process on this Mac as `ps` reports it, and the one question Bloom asks of them: what is
/// a shell running for somebody right now.
///
/// This is how a terminal pane is told apart from a terminal pane with a dev server in it. A pane
/// always has a shell, so the shell says nothing; what says something is the shell having a child
/// in a process group of its own, which is what job control means by a foreground job.
///
/// It is in the core rather than beside the terminal views because the parsing has to be pinned by
/// a test. `args` is the whole rest of the line and can hold anything a command line can hold,
/// spaces and quotes included, so the first three fields are taken by hand rather than by splitting
/// the line and hoping. `ps` writing into a pipe does not truncate, and the longest line on the
/// owner's machine was 9,826 characters, which is why the caller caps what it is willing to show
/// rather than assuming a command is short.
public struct ProcessTable: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public let pid: Int32
        public let parent: Int32
        public let group: Int32
        public let command: String

        public init(pid: Int32, parent: Int32, group: Int32, command: String) {
            self.pid = pid
            self.parent = parent
            self.group = group
            self.command = command
        }
    }

    public let rows: [Row]

    public init(rows: [Row] = []) {
        self.rows = rows
    }

    /// The arguments and the parser live next to each other so the two cannot drift. `=` after each
    /// column suppresses the header, which is the one line here that is not a process.
    public static let arguments = ["-Ao", "pid=,ppid=,pgid=,args="]

    /// A line is three integers and then the command. Anything else is skipped rather than guessed
    /// at: a partial read or a future `ps` that prints a warning to stdout must produce fewer rows,
    /// never a wrong one, because a wrong row here is a command offered to somebody who never ran it.
    public init(psOutput: String) {
        rows = psOutput.split(separator: "\n").compactMap { line in
            var rest = Substring(line)
            guard let pid = Self.takeNumber(&rest),
                  let parent = Self.takeNumber(&rest),
                  let group = Self.takeNumber(&rest) else { return nil }
            let command = rest.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }
            return Row(pid: pid, parent: parent, group: group, command: command)
        }
    }

    private static func takeNumber(_ rest: inout Substring) -> Int32? {
        rest = rest.drop { $0 == " " || $0 == "\t" }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, let value = Int32(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        // A number has to end at whitespace. `12ab` is not a pid, and reading it as 12 would file
        // a process under somebody else's parent.
        guard rest.first == nil || rest.first == " " || rest.first == "\t" else { return nil }
        return value
    }

    public static func current() async -> ProcessTable? {
        guard let result = try? await Shell.run("ps", arguments, timeout: .seconds(5)) else {
            return nil
        }
        return ProcessTable(psOutput: result.stdout)
    }

    /// What a shell is running, or nil when it is sitting at its prompt.
    ///
    /// A shell started in a pty is a session leader, so its own process group is itself and every
    /// job it starts gets a group of its own led by the first process of that job. That is what
    /// picks `npm run dev` out and leaves `tee` in `npm run dev | tee log` behind: both are the
    /// shell's children, both are in the job's group, and only the first leads it. Losing the tail
    /// of a pipeline is the right trade for never reporting the middle of one as the command.
    ///
    /// A shell with no job control puts its child in its own group, which no pty shell does but a
    /// `sh -c` under one might, so a child that leads nothing is still better than no answer at
    /// all. Where several jobs are running, the last `ps` printed wins, which is the newest of them
    /// on any machine that has not wrapped its pid counter round since the older one started.
    public func foregroundCommand(ofShell shell: Int32) -> String? {
        guard shell > 0 else { return nil }
        let children = rows.filter { $0.parent == shell && $0.pid != shell }
        let leaders = children.filter { $0.pid == $0.group }
        return (leaders.isEmpty ? children : leaders).last?.command
    }
    // This shares foregroundCommand's job heuristic; process presence does not prove an active turn.
    public func interactiveAgent(ofShell shell: Int32) -> AgentKind? {
        interactiveAgentProcess(ofShell: shell).flatMap { Self.interactiveAgent(command: $0.command) }
    }

    public func interactiveAgentProcess(ofShell shell: Int32) -> Row? {
        guard shell > 0 else { return nil }
        let children = rows.filter { $0.parent == shell && $0.pid != shell }
        let leaders = children.filter { $0.pid == $0.group }
        guard let job = (leaders.isEmpty ? children : leaders).last else { return nil }
        var pending = [job]
        var visited: Set<Int32> = []
        while let process = pending.popLast() {
            guard visited.insert(process.pid).inserted else { continue }
            if Self.interactiveAgent(command: process.command) != nil { return process }
            pending.append(contentsOf: rows.filter { $0.parent == process.pid })
        }
        return nil
    }

    public static func interactiveAgent(command: String) -> AgentKind? {
        var arguments = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let executable = arguments.first else { return nil }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if name == "node" || name == "nodejs" || name == "bun" {
            arguments.removeFirst()
            guard let script = arguments.first else { return nil }
            if script.hasSuffix("/@anthropic-ai/claude-code/cli.js") {
                arguments[0] = "claude"
            } else if script.hasSuffix("/@openai/codex/bin/codex.js") {
                arguments[0] = "codex"
            } else {
                return nil
            }
        }
        guard let commandName = arguments.first else { return nil }
        let binary = URL(fileURLWithPath: commandName).lastPathComponent
        let flags = arguments.dropFirst().prefix { $0 != "--" }
        if flags.contains("--help") || flags.contains("-h")
            || flags.contains("--version") || flags.contains("-V") { return nil }
        switch binary {
        case "claude":
            guard !flags.contains(where: {
                $0 == "--print" || $0.hasPrefix("--print=") || $0 == "-p"
                    || $0.hasPrefix("--output-format")
            }) else { return nil }
            let commands: Set<String> = ["auth", "mcp", "plugin", "install", "update", "doctor", "setup-token"]
            guard arguments.dropFirst().first.map({ !commands.contains($0) }) ?? true else { return nil }
            return .claudeCode
        case "codex":
            let commands: Set<String> = ["exec", "e", "review", "app-server", "mcp-server", "mcp", "login", "logout", "completion", "sandbox", "debug", "apply", "cloud", "features", "help"]
            let valueOptions: Set<String> = ["-c", "--config", "-m", "--model", "-C", "--cd", "-s", "--sandbox", "-a", "--ask-for-approval", "-i", "--image", "-p", "--profile", "--add-dir", "--enable", "--disable"]
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--" { break }
                if valueOptions.contains(argument) {
                    index += 2
                } else if argument.hasPrefix("-") {
                    index += 1
                } else {
                    guard !commands.contains(argument) else { return nil }
                    break
                }
            }
            return .codex
        default:
            return nil
        }
    }

}
