import Foundation

public struct DirectoryPreferences: Equatable, Sendable {
    public static let projectKey = "directories.projects"
    public static let additionalKey = "directories.additionalProjects"
    public static let askKey = "directories.ask"
    public var projects = ""
    public var additionalProjects: [String] = []
    public var ask = ""

    public init() {}

    public static func load(from store: Store) async -> Self {
        var result = Self()
        result.projects = (try? await store.setting(projectKey)) ?? ""
        result.ask = (try? await store.setting(askKey)) ?? ""
        if let raw = try? await store.setting(additionalKey), let data = raw.data(using: .utf8) {
            result.additionalProjects = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        return result
    }

    public func save(to store: Store) async throws {
        try await store.setSetting(Self.projectKey, projects.isEmpty ? nil : projects)
        try await store.setSetting(Self.askKey, ask.isEmpty ? nil : ask)
        let data = try JSONEncoder().encode(additionalProjects)
        try await store.setSetting(Self.additionalKey, String(decoding: data, as: UTF8.self))
    }

    public func projectLocation(projectPaths: [String], home: String) -> String {
        projects.isEmpty
            ? NewProjectPlan.suggestedLocation(projectPaths: projectPaths, home: home)
            : NewProjectPlan.expand(projects, home: home)
    }

    public func searchLocations(projectPaths: [String], home: String) -> [String] {
        let parents = projectPaths.map { ($0 as NSString).deletingLastPathComponent }
        return Array(Set(parents + additionalProjects.map { NewProjectPlan.expand($0, home: home) }
            + [projectLocation(projectPaths: projectPaths, home: home)] )).sorted()
    }
}
