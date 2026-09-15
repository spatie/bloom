import Foundation

/// One Docker container, volume or network that names a workspace as its owner.
///
/// Only resources that pass `WorkspaceDockerOwnership` in the core are ever built into one of
/// these, so a value here is already a claim that the resource is this workspace's own. Images
/// have no kind, deliberately: a project's dev image is shared by every workspace built from it,
/// and removing it per workspace would make the next setup rebuild it from nothing.
public struct WorkspaceDockerResource: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case container, volume, network
    }

    public var kind: Kind
    public var name: String
    public var composeProject: String?
    public var isRunning: Bool
    /// Docker's own rounded label, when it was measured. Never summed, for the reason
    /// `ServerStorageReport` gives.
    public var sizeLabel: String?

    public var id: String { kind.rawValue + ":" + name }

    public init(kind: Kind, name: String, composeProject: String? = nil, isRunning: Bool = false, sizeLabel: String? = nil) {
        self.kind = kind; self.name = name; self.composeProject = composeProject
        self.isRunning = isRunning; self.sizeLabel = sizeLabel
    }

    /// "3 containers and 2 volumes", counting only what a reader weighs.
    ///
    /// Networks are removed alongside and never named. A compose network holds no data, and a
    /// sentence that says "and 1 network" next to a database is a sentence that makes the
    /// database harder to see.
    public static func summary(_ resources: [WorkspaceDockerResource]) -> String {
        let containers = resources.filter { $0.kind == .container }.count
        let volumes = resources.filter { $0.kind == .volume }.count
        var parts: [String] = []
        if containers > 0 { parts.append(containers == 1 ? "1 container" : "\(containers) containers") }
        if volumes > 0 { parts.append(volumes == 1 ? "1 volume" : "\(volumes) volumes") }
        if parts.isEmpty {
            let networks = resources.filter { $0.kind == .network }.count
            return networks == 1 ? "1 network" : "\(networks) networks"
        }
        return parts.joined(separator: " and ")
    }
}

/// The Docker resources an archive would offer to remove, measured when the confirmation was
/// built. The archive itself lists them again, so this is what the reader is told rather than a
/// list of names anything acts on.
public struct ArchiveDockerFootprint: Codable, Sendable, Hashable {
    public var resources: [WorkspaceDockerResource]

    public init(resources: [WorkspaceDockerResource]) { self.resources = resources }

    /// Networks alone are not worth a question: they hold nothing, and asking about them would
    /// put a confirmation in front of an archive that has nothing at stake.
    public var offersRemoval: Bool { resources.contains { $0.kind != .network } }

    public var summary: String { WorkspaceDockerResource.summary(resources) }
}
