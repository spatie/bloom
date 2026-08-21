import AppIntents
import BloomCore

/// A repository Bloom knows about, so "create a workspace" can be pointed at one from a picker.
struct ProjectEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Bloom Project",
        numericFormat: "\(placeholder: .int) projects"
    )

    static let defaultQuery = ProjectEntityQuery()

    var id: RepoID

    @Property(title: "Name") var name: String
    @Property(title: "Folder") var folder: String
    @Property(title: "Default Branch") var defaultBranch: String

    init(repo: Repo) {
        self.id = repo.id
        self.name = repo.name
        self.folder = repo.path
        self.defaultBranch = repo.defaultBranch
    }

    /// The folder is the subtitle because two checkouts of the same repository are a normal thing
    /// to have, and then the name alone is ambiguous in the one place it matters.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(folder)")
    }
}

struct ProjectEntityQuery: EntityStringQuery {
    func entities(for identifiers: [ProjectEntity.ID]) async throws -> [ProjectEntity] {
        let wanted = Set(identifiers)
        return try await repos().filter { wanted.contains($0.id) }.map(ProjectEntity.init)
    }

    func suggestedEntities() async throws -> [ProjectEntity] {
        try await repos().map(ProjectEntity.init)
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {
        let needle = string.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return try await suggestedEntities() }
        return try await repos()
            .filter { $0.name.lowercased().contains(needle) || $0.path.lowercased().contains(needle) }
            .map(ProjectEntity.init)
    }

    private func repos() async throws -> [Repo] {
        try await IntentDatabase.store().repos()
    }
}
