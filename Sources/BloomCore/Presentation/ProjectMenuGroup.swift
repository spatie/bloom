import Foundation

/// The workspace picker has its own alphabetical order so hidden projects stay available
/// without interrupting the projects shown in the sidebar.
public struct ProjectMenuGroup: Identifiable, Sendable {
    public let hidden: Bool
    public let repos: [Repo]

    public var id: Bool { hidden }
    public var title: String { hidden ? "Hidden projects" : "Visible projects" }

    public static func grouped(_ repos: [Repo]) -> [ProjectMenuGroup] {
        let sorted = repos.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        return [false, true].compactMap { hidden in
            let members = sorted.filter { $0.hidden == hidden }
            guard !members.isEmpty else { return nil }
            return ProjectMenuGroup(hidden: hidden, repos: members)
        }
    }
}
