import Foundation

/// Where the window is being pointed, and the rules that turn a name into it.
///
/// In the core with its sentences rather than in the app, for the reason `WorkspaceTabChoice` is:
/// the test target cannot see `Sources/Bloom`, so a refusal composed there is a refusal nothing
/// can read back. Everything here is a pure function of what the caller said and what the store
/// holds; the app is handed the answer and moves the selection.
public enum RevealTarget: Sendable, Equatable {
    case workspace(WorkspaceID)
    /// Home, under a scope and a search string. This is the arm that makes "clean up the finished
    /// ones" end honestly: the candidates selected, and the owner's finger on the button.
    case home(HomeFilter)
}

/// A resolved reveal: where to point, and what to say once it has been pointed there.
///
/// The sentence is built here rather than by the app because it is built out of what was
/// resolved, and resolving is what this file does. The app's closure only has to say whether the
/// window was there to be moved.
///
/// `Plan` rather than the bare noun for two reasons. `Sources/Bloom` already has a `Reveal`, which
/// is the menu item's family of verbs for showing a path in Finder, in Terminal or in an editor:
/// a related idea about a different place, and the bare name inside the app target resolved to
/// that one. And `Plan` is what this tree already calls a resolved, executable description of
/// something about to happen; see `WorkspaceStartPlan` and `RepositoryStartPlan`.
public struct RevealPlan: Sendable, Equatable {
    public let target: RevealTarget
    public let sentence: String

    public init(target: RevealTarget, sentence: String) {
        self.target = target
        self.sentence = sentence
    }
}

public enum RevealOutcome: Sendable, Equatable {
    case revealed(String)
    case refused(String)
}

/// What the caller asked for, before anything has been looked up.
public struct RevealOrder: Sendable, Equatable {
    public var workspace: String?
    public var project: String?
    public var scope: HomeScope
    public var search: String

    public init(
        workspace: String? = nil,
        project: String? = nil,
        scope: HomeScope = .all,
        search: String = ""
    ) {
        self.workspace = workspace
        self.project = project
        self.scope = scope
        self.search = search
    }
}

public enum RevealChoice {
    /// How many names a refusal lists before it stops. The same ten `WorkspaceTabChoice` stops at,
    /// and for the same reason: a refusal that prints four hundred workspaces is a refusal nobody
    /// reads.
    static let listLimit = 10

    /// Reads the arguments, with nothing looked up yet.
    ///
    /// **A workspace and a Home narrowing together is a refusal rather than a precedence rule.**
    /// Either would be a defensible winner, which is exactly why neither may be: a caller that
    /// asked for both got one of them silently, and the one it did not get was the one it meant
    /// half the time.
    public static func parse(
        workspace: JSONValue?,
        project: JSONValue?,
        scope: JSONValue?,
        search: JSONValue?
    ) -> Result<RevealOrder, PaneRefusal> {
        let workspaceName = text(workspace)
        let projectName = text(project)
        let query = text(search) ?? ""

        var narrowing: HomeScope = .all
        if let raw = text(scope) {
            guard let known = HomeScope(rawValue: raw), Self.offered.contains(known) else {
                return .failure(PaneRefusal(
                    "'\(raw)' is not one of Home's scopes. They are: "
                        + Self.offered.map(\.rawValue).joined(separator: ", ") + "."
                ))
            }
            narrowing = known
        }

        if workspaceName != nil, projectName != nil || narrowing != .all || !query.isEmpty {
            return .failure(PaneRefusal(
                "reveal points at one workspace, or at Home narrowed by project, scope and "
                    + "search. Asking for both at once leaves it ambiguous which you meant, so "
                    + "pass 'workspace' on its own, or leave it out and pass the rest."
            ))
        }

        return .success(RevealOrder(
            workspace: workspaceName, project: projectName, scope: narrowing, search: query
        ))
    }

    /// The scopes a caller may name. Home's search-only chips are left out because they narrow a
    /// search by what kind of thing matched, and a reveal that arrives with no query would select
    /// a chip that shows nothing.
    static let offered: [HomeScope] = [.all, .needsYou, .running, .live, .archived]

    /// Turns names into a target, against the rows as they are right now.
    public static func resolve(
        _ order: RevealOrder,
        workspaces: [Workspace],
        projects: [Repo]
    ) -> Result<RevealPlan, PaneRefusal> {
        if let name = order.workspace {
            return workspaceTarget(name, among: workspaces, projects: projects)
        }

        var filter = HomeFilter(query: order.search, scope: order.scope)
        var project: Repo?
        if let name = order.project {
            switch match(name, among: projects) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let found):
                project = found
                filter.projects = [found.id]
            }
        }

        return .success(RevealPlan(target: .home(filter), sentence: homeSentence(filter, project: project)))
    }

    private static func workspaceTarget(
        _ name: String,
        among workspaces: [Workspace],
        projects: [Repo]
    ) -> Result<RevealPlan, PaneRefusal> {
        if let exact = workspaces.first(where: { $0.id.rawValue == name }) {
            return .success(RevealPlan(
                target: .workspace(exact.id), sentence: sentence(for: exact, projects: projects)
            ))
        }

        let needle = name.lowercased()
        let matches = workspaces.filter { $0.name.lowercased() == needle }
        switch matches.count {
        case 1:
            return .success(RevealPlan(
                target: .workspace(matches[0].id),
                sentence: sentence(for: matches[0], projects: projects)
            ))
        case 0:
            return .failure(PaneRefusal(
                "There is no workspace called '\(name)'. There is: "
                    + list(workspaces.map(\.name)) + "."
            ))
        default:
            return .failure(PaneRefusal(
                "\(matches.count) workspaces are called '\(name)', in "
                    + list(matches.map { projectName($0, projects: projects) })
                    + ". Pass the workspace's id instead, which workspace_list prints."
            ))
        }
    }

    private static func match(_ name: String, among projects: [Repo]) -> Result<Repo, PaneRefusal> {
        let needle = name.lowercased()
        if let exact = projects.first(where: { $0.name.lowercased() == needle }) { return .success(exact) }
        if let byPath = projects.first(where: { $0.path.lowercased() == needle }) { return .success(byPath) }
        return .failure(PaneRefusal(
            "There is no project called '\(name)'. There is: " + list(projects.map(\.name)) + "."
        ))
    }

    private static func sentence(for workspace: Workspace, projects: [Repo]) -> String {
        "Bloom is showing \(workspace.name) in \(projectName(workspace, projects: projects))."
    }

    private static func homeSentence(_ filter: HomeFilter, project: Repo?) -> String {
        var clauses: [String] = []
        if let project { clauses.append("in \(project.name)") }
        if filter.scope != .all { clauses.append("scoped to \(filter.scope.label(searching: false))") }
        if !filter.query.isEmpty { clauses.append("matching '\(filter.query)'") }

        guard !clauses.isEmpty else { return "Bloom is showing Home, with nothing narrowed." }
        return "Bloom is showing Home, " + clauses.joined(separator: ", ") + "."
    }

    private static func projectName(_ workspace: Workspace, projects: [Repo]) -> String {
        projects.first { $0.id == workspace.repoID }?.name ?? "a project Bloom no longer has"
    }

    /// Names, comma separated, cut off before a refusal turns into a directory listing.
    static func list(_ names: [String]) -> String {
        guard !names.isEmpty else { return "nothing" }
        let shown = names.prefix(listLimit).joined(separator: ", ")
        let rest = names.count - listLimit
        return rest > 0 ? shown + " and \(rest) more" : shown
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        return raw
    }
}
