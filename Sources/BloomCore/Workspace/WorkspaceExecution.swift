import Foundation

/// A repository can put its tools in a container without teaching each agent about Docker.
/// The wrapper receives argv unchanged, and setup/archive remain on the host that owns it.
public struct WorkspaceExecution: Sendable, Hashable {
    public var commandPrefix: [String]
    public var environment: [String: String]
    public var bridgeEnabled: Bool
    public var supportsBridge: Bool { commandPrefix.isEmpty || bridgeEnabled }

    public init(commandPrefix: [String] = [], environment: [String: String] = [:], bridgeEnabled: Bool = false) {
        self.commandPrefix = commandPrefix
        self.environment = environment
        self.bridgeEnabled = bridgeEnabled
    }

    public static func resolve(workspace: Workspace, repo: Repo, environment: [String: String]) throws -> Self {
        let settings = SettingsLoader.load(workspace: workspace.path, repo: repo.path)
        guard var command = settings.executionCommand, !command.isEmpty else {
            return Self(environment: environment)
        }
        let root = URL(fileURLWithPath: workspace.path).resolvingSymlinksInPath().standardizedFileURL.path
        let executable = URL(fileURLWithPath: command[0], relativeTo: URL(fileURLWithPath: root + "/"))
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard !command[0].hasPrefix("/"), executable.hasPrefix(root + "/"),
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw Failure("The execution command must name an executable file inside this workspace: \(command[0])")
        }
        command[0] = executable
        return Self(commandPrefix: command, environment: environment, bridgeEnabled: settings.executionBridge == true)
    }

    public static func resolve(store: Store, session: Session) async throws -> Self {
        guard let workspaceID = session.workspaceID, let workspace = try await store.workspace(id: workspaceID) else { return Self() }
        return try await resolve(store: store, workspace: workspace)
    }

    public static func resolve(store: Store, workspace: Workspace) async throws -> Self {
        guard let repo = try await store.repo(id: workspace.repoID) else { return Self() }
        let manager = WorkspaceManager(store: store)
        let port = await manager.ensurePort(for: workspace)
        return try resolve(workspace: workspace, repo: repo,
            environment: manager.environment(for: workspace, repo: repo, port: port))
    }

    /// An opted-in wrapper mounts only this session's config, the private socket directory and
    /// the packaged shim runtime at the same absolute paths. No credentials are added here.
    public func bridgeEnvironment(_ attachment: BridgeAttachment?, configPath: String? = nil) -> [String: String] {
        guard !commandPrefix.isEmpty, supportsBridge, let attachment else { return [:] }
        let executable = URL(fileURLWithPath: attachment.shimPath)
        let bin = executable.deletingLastPathComponent()
        let runtime = bin.lastPathComponent == "bin" ? bin.deletingLastPathComponent() : bin
        var values = [
            "BLOOM_BRIDGE_SOCKET_DIRECTORY": URL(fileURLWithPath: attachment.socketPath).deletingLastPathComponent().path,
            "BLOOM_BRIDGE_RUNTIME_DIRECTORY": runtime.path,
            "BLOOM_BRIDGE_SHIM_PATH": attachment.shimPath,
        ]
        if let configPath { values["BLOOM_BRIDGE_CONFIG_PATH"] = configPath }
        return values
    }

    public func wrapping(_ launch: AgentLaunch) -> AgentLaunch {
        AgentLaunch(executable: commandPrefix.first ?? launch.executable,
            arguments: commandPrefix.isEmpty ? launch.arguments : Array(commandPrefix.dropFirst()) + [launch.executable] + launch.arguments,
            cwd: launch.cwd, environment: launch.environment.merging(environment) { _, workspaceValue in workspaceValue })
    }

    /// tmux accepts a single shell command, so quote each argv element exactly once at its boundary.
    public var terminalCommand: String? {
        guard !commandPrefix.isEmpty else { return nil }
        return (commandPrefix + ["/bin/bash", "-l"]).map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }.joined(separator: " ")
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
