import Foundation

/// Looks for each of the four tools on this machine, once.
///
/// In the core rather than beside the view, so the welcome window can be a drawing and nothing
/// else. Every one of these calls is a subprocess or a file read, and CLAUDE.md's rule about what
/// a `View` may do is the whole reason this file exists at the level it does.
///
/// It writes nothing and it starts nothing. A probe is allowed to ask `--version` and to ask the
/// GitHub CLI whether it is signed in, and that is the end of its powers: signing anything in is a
/// thing the user presses a button for.
public struct SetupProbe: Sendable {
    /// The same per-agent executable overrides the Agents settings pane writes. Passed in rather
    /// than read here, because reading `UserDefaults` from the core would put the app's storage
    /// inside a type the test suite has to be able to run in isolation.
    private let catalog: AgentCatalog

    public init(agentOverrides: [AgentKind: String] = [:]) {
        // A catalog of its own, not a shared one. The settings pane's catalog caches until
        // something invalidates it, and a person who has just installed `gh` in another window and
        // pressed Check again is asking for the world to be looked at now.
        catalog = AgentCatalog(overrides: agentOverrides)
    }

    /// Every check, run at the same time, delivered as each one lands.
    ///
    /// A stream rather than an array, because the window draws the settling. Four sequential
    /// probes would be four `--version` subprocesses end to end, and on a cold machine that is
    /// long enough to sit through; concurrently it is as slow as the slowest one.
    public func run() -> AsyncStream<SetupCheck> {
        AsyncStream { continuation in
            let work = Task {
                await withTaskGroup(of: SetupCheck.self) { group in
                    for tool in SetupTool.displayOrder {
                        group.addTask { await check(tool) }
                    }
                    for await result in group {
                        continuation.yield(result)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Everything, gathered. For the launch decision, which has nothing to draw and only needs a
    /// verdict.
    public func report() async -> SetupReport {
        var byTool: [SetupTool: SetupCheck] = [:]
        for await check in run() { byTool[check.tool] = check }
        return SetupReport(checks: SetupTool.displayOrder.map {
            byTool[$0] ?? SetupCheck(tool: $0, outcome: .missing)
        })
    }

    public func check(_ tool: SetupTool) async -> SetupCheck {
        switch tool {
        case .git: await SetupCheck(tool: tool, outcome: gitOutcome())
        case .claudeCode, .codex: await SetupCheck(tool: tool, outcome: agentOutcome(tool))
        case .gitHub: await SetupCheck(tool: tool, outcome: gitHubOutcome())
        }
    }

    // MARK: - git

    /// Git has no account, so "found" is the whole question. The version is read anyway, because
    /// a row that says only "Installed" is a row that could have been a tick.
    private func gitOutcome() async -> SetupOutcome {
        guard let path = Shell.which("git") else { return .missing }
        // Five seconds, the same deadline `AgentCatalog.readVersion` uses, and for the same
        // reason: a hung binary must not hold a window open.
        guard let result = try? await Shell.run(path, ["--version"], timeout: .seconds(5)),
              result.ok else {
            return .ready(detail: nil)
        }
        return .ready(detail: AgentCatalog.parseVersion(result.trimmed))
    }

    // MARK: - The agents

    /// Straight through `AgentCatalog`, which already knows what "connected" means for each CLI
    /// and already refuses to render anything out of the credential files but derived facts.
    /// Writing a second detector here would be a second answer to a question that has one.
    private func agentOutcome(_ tool: SetupTool) async -> SetupOutcome {
        guard let kind = tool.agentKind else { return .missing }
        let status = await catalog.status(for: kind)

        switch status.connection {
        case .notInstalled:
            return .missing
        case .installed:
            // Found, and no account facts. For Claude Code and Codex that means signed out, which
            // is what both of their auth files being absent looks like.
            return .needsSignIn(detail: status.version)
        case .connected:
            return .ready(detail: Self.accountLine(status))
        }
    }

    /// The one fact worth printing beside a connected agent: who it is signed in as, falling back
    /// to the version. Never a token, never a raw field, and only ever one of the labels
    /// `AgentCatalog` already decided was safe to show. See docs/AGENTS-INTEGRATION.md.
    static func accountLine(_ status: AgentStatus) -> String? {
        let wanted = ["Email", "Account", "Organization"]
        for label in wanted {
            if let value = status.details.first(where: { $0.label == label })?.value,
               value != AgentCatalog.unknown, !value.isEmpty {
                return value
            }
        }
        return status.version
    }

    // MARK: - GitHub

    /// `GitHub.access()` is the existing answer to this exact question, and it already keeps the
    /// two failures apart: missing is installed with `brew`, signed out is fixed with a login.
    private func gitHubOutcome() async -> SetupOutcome {
        switch await GitHub.access() {
        case .notInstalled: return .missing
        case .signedOut: return .needsSignIn(detail: nil)
        case .ready: return .ready(detail: "Signed in")
        }
    }
}
