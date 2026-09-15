import Foundation
import BloomClient

public typealias AgentAuthenticationStatus = BloomClient.AgentAuthenticationStatus
public typealias AgentAuthenticationRequired = BloomClient.AgentAuthenticationRequired

/// Probe the same CLI and execution environment as a turn. The result contains no CLI output,
/// account metadata or credentials, and a probe never starts a prompt or opens a browser.
public enum ServerAgentAuthentication {
    public typealias Check = @Sendable (AgentKind, Store, Workspace?) async -> AgentAuthenticationStatus

    public static func inspect(agent: AgentKind, store: Store, workspace: Workspace?) async -> AgentAuthenticationStatus {
        guard let arguments = arguments(for: agent) else { return .init(agent: agent, state: .unknown) }
        do {
            let overrides = await AgentCatalog.executablePathOverrides(in: store)
            let executable = AgentCatalog.executable(for: agent, override: overrides[agent])
            let execution: WorkspaceExecution
            if let workspace { execution = try await WorkspaceExecution.resolve(store: store, workspace: workspace) } else { execution = WorkspaceExecution() }
            let launch = execution.wrapping(AgentLaunch(executable: executable, arguments: arguments,
                cwd: workspace?.path ?? FileManager.default.temporaryDirectory.path, environment: [:]))
            guard let path = Shell.which(launch.executable) else { return .init(agent: agent, state: .unavailable) }
            let environment = Shell.environment(extra: launch.environment)
            let result = try await ServerCredentialImportProcess.run(path, launch.arguments, environment: environment,
                limit: 65_536, timeout: 8, workingDirectory: launch.cwd, captureStderr: true)
            try Task.checkCancellation()
            let status = classify(agent: agent, status: result.status, output: String(decoding: result.output, as: UTF8.self))
            let externalKeys = agent == .codex ? ["OPENAI_API_KEY", "CODEX_ACCESS_TOKEN"] : ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]
            if status.requiresSignIn, externalKeys.contains(where: { !(environment[$0] ?? "").isEmpty }) {
                return .init(agent: agent, state: .unknown)
            }
            return status
        } catch { return .init(agent: agent, state: .unknown) }
    }

    /// At most two independent CLI probes run together, so account diagnostics stay inside
    /// the client deadline without spawning every configured backend at once.
    static func checkAll(_ agents: [AgentKind], store: Store, workspace: Workspace? = nil,
                         check: @escaping Check) async -> [AgentAuthenticationStatus] {
        await withTaskGroup(of: (Int, AgentAuthenticationStatus).self) { group in
            var results = [AgentAuthenticationStatus?](repeating: nil, count: agents.count)
            var next = 0
            for index in 0..<min(2, agents.count) {
                let agent = agents[index]
                group.addTask { (index, await check(agent, store, workspace)) }
                next += 1
            }
            while let (index, status) = await group.next() {
                results[index] = status
                if next < agents.count {
                    let index = next, agent = agents[next]
                    group.addTask { (index, await check(agent, store, workspace)) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    static func arguments(for agent: AgentKind) -> [String]? {
        switch agent {
        case .codex: ["login", "status"]
        case .claudeCode: ["auth", "status", "--json"]
        default: nil
        }
    }

    static func classify(agent: AgentKind, status: Int32, output: String) -> AgentAuthenticationStatus {
        guard output.utf8.count <= 65_536 else { return .init(agent: agent, state: .unknown) }
        if agent == .claudeCode,
           let json = JSONValue.parse(Data(output.trimmingCharacters(in: .whitespacesAndNewlines).utf8)),
           let loggedIn = json["loggedIn"]?.boolValue {
            return .init(agent: agent, state: loggedIn && status == 0 ? .ready : (loggedIn ? .unknown : .signInRequired))
        }
        if status != 0, AgentAuthenticationStatus.isSignInFailure(output) {
            return .init(agent: agent, state: .signInRequired)
        }
        if agent == .codex, status == 0, output.lowercased().contains("logged in") {
            return .init(agent: agent, state: .ready)
        }
        return .init(agent: agent, state: .unknown)
    }
}
