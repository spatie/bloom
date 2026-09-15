import Foundation
import BloomClient

/// The Docker engine a workspace's containers run on, reached the same way by the Mac and the
/// server so that finding and removing them is one piece of code.
///
/// The two differ only in how a command reaches the engine. On a Mac it is the owner's own
/// `docker`, with whatever context Docker Desktop or OrbStack set. On a server it is the service
/// account's private rootless engine, verified and pinned by socket through
/// `ServerStorageDocker` exactly as storage cleanup is, so a context changed underneath cannot
/// point a volume removal at another engine.
public struct WorkspaceDocker: Sendable {
    public struct Output: Sendable {
        public let status: Int32
        public let text: String

        public init(status: Int32, text: String) { self.status = status; self.text = text }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unavailable(String)
        case removal(kind: WorkspaceDockerResource.Kind, detail: String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let detail):
                "Docker could not list this workspace\u{2019}s containers. " + detail
            case .removal(let kind, let detail):
                "Docker could not remove this workspace\u{2019}s \(kind.rawValue)s. " + detail
            }
        }
    }

    public typealias Run = @Sendable (_ arguments: [String], _ timeout: TimeInterval) async throws -> Output

    let prepare: @Sendable () async throws -> Void
    let run: Run

    public init(prepare: @escaping @Sendable () async throws -> Void = {}, run: @escaping Run) {
        self.prepare = prepare; self.run = run
    }

    /// The owner's own `docker`, found on the login shell's `PATH`.
    public static let local = WorkspaceDocker { arguments, timeout in
        let result = try await Shell.run("docker", arguments, timeout: .seconds(timeout), outputLimit: 4 * 1_024 * 1_024)
        return Output(status: result.status, text: result.ok ? result.stdout : result.stderr + result.stdout)
    }

    init(storage docker: ServerStorageDocker) {
        prepare = { try await docker.validate() }
        run = { arguments, timeout in
            let output = try await docker.run(docker.engineArguments(arguments), docker.configuration.environment, timeout, 4 * 1_024 * 1_024)
            return Output(status: output.status, text: output.text)
        }
    }

    /// Every container, volume and network that names a workspace, whichever workspace it names.
    public func inventory(measuringSizes: Bool = false) async throws -> [WorkspaceDockerInventory.Entry] {
        try await prepare()
        async let containers = checked(WorkspaceDockerInventory.containerArguments)
        async let volumes = checked(WorkspaceDockerInventory.volumeArguments)
        async let networks = checked(WorkspaceDockerInventory.networkArguments)
        var entries = try await WorkspaceDockerInventory.containers(containers)
            + WorkspaceDockerInventory.volumes(volumes)
            + WorkspaceDockerInventory.networks(networks)
        guard measuringSizes, !entries.isEmpty,
              let usage = try? await run(WorkspaceDockerInventory.sizeArguments, 60), usage.status == 0 else { return entries }
        let sizes = WorkspaceDockerInventory.sizes(usage.text)
        for index in entries.indices {
            entries[index].resource.sizeLabel = sizes[entries[index].resource.id]
        }
        return entries
    }

    /// What an archive confirmation says about this workspace, or nil when there is nothing to
    /// offer or Docker could not be asked. Never throws: a Mac without Docker, or a server whose
    /// engine is stopped, archives exactly as it did before this existed.
    public func footprint(of id: WorkspaceID) async -> ArchiveDockerFootprint? {
        guard let entries = try? await inventory() else { return nil }
        let footprint = ArchiveDockerFootprint(resources: entries.filter { $0.workspaceID == id }.map(\.resource))
        return footprint.offersRemoval ? footprint : nil
    }

    /// Lists again and removes what names this workspace now, rather than what a confirmation
    /// listed minutes ago: the archive script has run since then and will usually have removed
    /// some of it, and a name remembered from before could have been reused.
    public func removeResources(of id: WorkspaceID) async throws {
        let resources: [WorkspaceDockerResource]
        do {
            resources = try await inventory().filter { $0.workspaceID == id }.map(\.resource)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unavailable(Self.detail(error.localizedDescription))
        }
        try await remove(resources)
    }

    /// Containers, then volumes, then networks, which is the only order Docker allows: a volume
    /// or network still attached to a container refuses to go.
    ///
    /// `--volumes` on the container removal takes the anonymous volumes that container created,
    /// which belong to nothing else and have no label to be found by later. Images are never
    /// removed. `--` ends the options, as a second guard behind `isValidName`.
    func remove(_ resources: [WorkspaceDockerResource]) async throws {
        let steps: [(WorkspaceDockerResource.Kind, [String])] = [
            (.container, ["container", "rm", "--force", "--volumes", "--"]),
            (.volume, ["volume", "rm", "--"]),
            (.network, ["network", "rm", "--"]),
        ]
        for (kind, command) in steps {
            let names = resources.filter { $0.kind == kind }.map(\.name).filter(WorkspaceDockerInventory.isValidName)
            guard !names.isEmpty else { continue }
            let output: Output
            do {
                output = try await run(command + names, 180)
            } catch {
                throw Failure.removal(kind: kind, detail: Self.detail(error.localizedDescription))
            }
            // A resource that vanished between the listing and the removal is already gone,
            // which is what was asked for.
            guard output.status == 0 || Self.onlyMissing(output.text) else {
                throw Failure.removal(kind: kind, detail: Self.detail(output.text))
            }
        }
    }

    private func checked(_ arguments: [String]) async throws -> String {
        let output: Output
        do {
            output = try await run(arguments, 20)
        } catch {
            throw Failure.unavailable(Self.detail(error.localizedDescription))
        }
        guard output.status == 0 else { throw Failure.unavailable(Self.detail(output.text)) }
        return output.text
    }

    static func onlyMissing(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.lowercased() }
        return !lines.isEmpty && lines.allSatisfy { $0.contains("no such") || $0.contains("not found") }
    }

    private static func detail(_ text: String) -> String {
        let trimmed = ServerSetupDiagnostics.sanitise(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return trimmed.isEmpty ? "Check that Docker is running." : String(trimmed.suffix(600))
    }
}
