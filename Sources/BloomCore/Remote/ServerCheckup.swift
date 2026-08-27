import Foundation

/// What one look at a server decided, as a value the store can write and the pane can draw.
///
/// A state and a sentence, worked out by a pure function from what came back, rather than assigned
/// at each of the places something can go wrong. There are eleven of those places and they are all
/// one line here, which is why this is testable and why the pane never has to invent a message of
/// its own.
public struct ServerVerdict: Sendable, Hashable {
    public var state: ServerState
    /// One sentence, or empty when the state says everything there is to say.
    public var detail: String

    public init(state: ServerState, detail: String = "") {
        self.state = state
        self.detail = detail
    }
}

public extension ServerVerdict {
    /// The server answered. What is left is whether it has what Bloom needs.
    ///
    /// Order matters, and it is the order somebody would fix things in: no git or no Python is the
    /// blocker, a `bloomd` that could not be installed is next, and only then is a missing agent
    /// worth mentioning. A server with git, Python and a current daemon is ready even with no
    /// agent on it, because an agent is installed per project and this pane is about the machine.
    static func reached(facts: ServerFacts, action: BloomdAction) -> ServerVerdict {
        var missing: [String] = []
        if !facts.state(of: .git).isPresent { missing.append("git") }
        if !facts.state(of: .python3).isPresent { missing.append("python3") }
        if !missing.isEmpty {
            return ServerVerdict(
                state: .incomplete,
                detail: "\(list(missing)) \(missing.count == 1 ? "is" : "are") not installed."
            )
        }

        if case .impossible = action {
            return ServerVerdict(state: .incomplete, detail: "There is no python3 to run bloomd.")
        }

        let quiet = ServerTool.displayOrder
            .filter { $0.setupTool != nil && $0 != .git }
            .filter { !facts.state(of: $0).isPresent }
            .map(\.title)

        // A tool that is there and does not run is worth saying out loud even when the server is
        // otherwise fine, because it is the state that looks like success from a distance.
        let broken = ServerTool.displayOrder
            .filter { facts.state(of: $0).isBroken }
            .map(\.title)
        if !broken.isEmpty {
            return ServerVerdict(
                state: .ready,
                detail: "\(list(broken)) \(broken.count == 1 ? "is" : "are") installed and did not run."
            )
        }

        guard !quiet.isEmpty else { return ServerVerdict(state: .ready) }
        return ServerVerdict(state: .ready, detail: "No \(list(quiet)) on it.")
    }

    /// Something stopped the look. Every branch here produces a sentence that names the thing to
    /// do about it, because "failed" on a row is a row nobody can act on.
    static func failed(_ error: any Error) -> ServerVerdict {
        switch error {
        case let trouble as RunTrouble:
            switch trouble {
            case .unreachable(let failure):
                return ServerVerdict(state: .unreachable, detail: failure.sentence)
            case .timedOut, .couldNotWrite:
                return ServerVerdict(state: .unreachable, detail: trouble.description)
            }
        case let trouble as ServerProbe.Trouble:
            // A truncated answer is the connection dropping; anything else is a server that
            // answered and answered oddly, which is a setup problem rather than a network one.
            let state: ServerState = trouble == .truncated ? .unreachable : .incomplete
            return ServerVerdict(state: state, detail: trouble.description)
        case let trouble as BloomdTrouble:
            return ServerVerdict(state: .incomplete, detail: trouble.description)
        case let trouble as ShellError:
            return ServerVerdict(state: .unreachable, detail: trouble.description)
        default:
            return ServerVerdict(state: .unreachable, detail: "\(error)")
        }
    }

    /// "git", "git and python3", "a, b and c". No Oxford comma, which is the house style.
    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: "\(items.dropLast().joined(separator: ", ")) and \(items[items.count - 1])"
        }
    }
}

/// Probe a server, install `bloomd` on it if it needs it, and say how it went.
///
/// **The install is not a separate button and there is nothing to press.** "Copy that file, so it
/// works seamless" is the whole requirement: a checkup notices that the version on the server is
/// not the version in the bundle and copies it, on the connection that is already open, in the
/// same look. `BloomdAction` is carried out of here so the pane can say what happened, but nobody
/// is ever asked.
///
/// It takes a runner rather than a destination, so the whole of this runs against this Mac with no
/// server anywhere, which is what `ServerCheckupTests` does.
public struct ServerCheckup: Sendable {
    public struct Outcome: Sendable {
        public var facts: ServerFacts
        public var action: BloomdAction
        /// What the daemon reports at the END of the checkup, so a fresh install shows its new
        /// version rather than the absence it started from.
        public var bloomdVersion: String?
        public var verdict: ServerVerdict
    }

    private let runner: any CommandRunning
    /// The `bloomd.py` this Bloom ships, already read. Passed in rather than read here, because
    /// the core must not care whether it is inside an app bundle.
    private let source: String?

    public init(runner: any CommandRunning, source: String?) {
        self.runner = runner
        self.source = source
    }

    public func run() async throws -> Outcome {
        let facts = try await ServerProbe(runner: runner).run()
        let hasPython = facts.state(of: .python3).isPresent

        guard let source = self.source, let shipping = Bloomd.version(of: source) else {
            // Bloom could not find its own copy of the file, which is a broken build rather than a
            // broken server. The probe still stands, so the row says what it found and says
            // nothing about a daemon it cannot install.
            let action: BloomdAction = hasPython
                ? .install(reason: .notThere, version: "")
                : .impossible
            return Outcome(
                facts: facts,
                action: action,
                bloomdVersion: facts.bloomdVersion,
                verdict: ServerVerdict(
                    state: .incomplete,
                    detail: "This copy of Bloom is missing its bloomd.py, so nothing can be installed."
                )
            )
        }

        let action = Bloomd.decide(
            shipping: shipping,
            installed: facts.bloomdVersion,
            hasPython: hasPython
        )

        var installed = facts.bloomdVersion
        if action.needsCopying {
            let client = BloomdClient(runner: runner, home: facts.home)
            installed = try await client.install(source: source)
        }

        return Outcome(
            facts: facts,
            action: action,
            bloomdVersion: installed,
            verdict: .reached(facts: facts, action: action)
        )
    }
}
