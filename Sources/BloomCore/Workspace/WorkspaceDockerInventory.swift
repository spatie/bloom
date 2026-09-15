import Foundation
import BloomClient

/// Docker's listings read into resources, each with the workspace `WorkspaceDockerOwnership`
/// says it belongs to.
///
/// Templates rather than `--format json`, because the JSON listings join every label into one
/// comma separated string, and compose's `config_files` label is itself a comma separated list.
/// `{{.Label "name"}}` asks the engine for exactly one label and cannot be misread.
public enum WorkspaceDockerInventory {
    public struct Entry: Sendable, Hashable {
        public var workspaceID: WorkspaceID
        public var resource: WorkspaceDockerResource
    }

    private static let labels = "{{.Label \"\(WorkspaceDockerOwnership.composeProjectLabel)\"}}\t{{.Label \"\(WorkspaceDockerOwnership.workspaceLabel)\"}}"

    static let containerArguments = ["container", "ls", "--all", "--no-trunc", "--format", "{{.Names}}\t{{.State}}\t" + labels]
    static let volumeArguments = ["volume", "ls", "--format", "{{.Name}}\t" + labels]
    static let networkArguments = ["network", "ls", "--no-trunc", "--format", "{{.Name}}\t" + labels]
    /// Verbose `system df` is the only listing that measures volumes. It is slow on a large engine,
    /// which is why only Storage & Cleanup asks for it and an archive never does.
    static let sizeArguments = ["system", "df", "--verbose", "--format", "json"]

    static func containers(_ text: String) -> [Entry] {
        rows(text, columns: 4).compactMap { fields in
            // A container with legacy links lists several names; the first is its own.
            let name = String(fields[0].split(separator: ",").first ?? "")
            return entry(.container, name: name, project: fields[2], label: fields[3], isRunning: fields[1] == "running")
        }
    }

    static func volumes(_ text: String) -> [Entry] {
        rows(text, columns: 3).compactMap { entry(.volume, name: $0[0], project: $0[1], label: $0[2], isRunning: false) }
    }

    static func networks(_ text: String) -> [Entry] {
        rows(text, columns: 3).compactMap { entry(.network, name: $0[0], project: $0[1], label: $0[2], isRunning: false) }
    }

    /// Sizes by resource id, from `system df --verbose --format json`. Anything unreadable is left
    /// out rather than failing the listing, because a leftover without a size is still a leftover.
    static func sizes(_ text: String) -> [String: String] {
        struct Usage: Decodable {
            struct Container: Decodable {
                let names: String?
                let size: String?
                enum CodingKeys: String, CodingKey { case names = "Names", size = "Size" }
            }
            struct Volume: Decodable {
                let name: String?
                let size: String?
                enum CodingKeys: String, CodingKey { case name = "Name", size = "Size" }
            }
            let containers: [Container]?
            let volumes: [Volume]?
            enum CodingKeys: String, CodingKey { case containers = "Containers", volumes = "Volumes" }
        }
        guard let usage = try? JSONDecoder().decode(Usage.self, from: Data(text.utf8)) else { return [:] }
        var sizes: [String: String] = [:]
        for container in usage.containers ?? [] {
            // "12kB (virtual 1.2GB)": the virtual part is the shared image, which removing this
            // container does not reclaim.
            guard let name = container.names?.split(separator: ",").first,
                  let size = container.size?.components(separatedBy: " (").first,
                  ServerStorageDocker.validSize(size) else { continue }
            sizes[WorkspaceDockerResource.Kind.container.rawValue + ":" + name] = size
        }
        for volume in usage.volumes ?? [] {
            guard let name = volume.name, let size = volume.size, ServerStorageDocker.validSize(size) else { continue }
            sizes[WorkspaceDockerResource.Kind.volume.rawValue + ":" + name] = size
        }
        return sizes
    }

    /// Docker's own name grammar. Checked because these names go back on a command line, and a
    /// name that began with a dash would be read as an option.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.utf8.count <= 255,
              CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)) }
    }

    private static func rows(_ text: String, columns: Int) -> [[String]] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return fields.count == columns ? fields : nil
        }
    }

    private static func entry(_ kind: WorkspaceDockerResource.Kind, name: String, project: String, label: String, isRunning: Bool) -> Entry? {
        guard isValidName(name),
              let id = WorkspaceDockerOwnership.workspaceID(composeProject: project, workspaceLabel: label) else { return nil }
        let resource = WorkspaceDockerResource(kind: kind, name: name, composeProject: project.isEmpty ? nil : project, isRunning: isRunning)
        return Entry(workspaceID: id, resource: resource)
    }
}
