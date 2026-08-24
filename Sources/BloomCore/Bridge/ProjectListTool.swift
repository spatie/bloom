import Foundation

/// `project_list`: the projects Bloom has, for a client that is not sitting in one.
///
/// Owner only, and that is not caution about the cost of the call, which is one `SELECT`. A
/// workspace agent already knows its project and cannot act in any other, so the only thing this
/// would give it is the names and the paths of every other repository the owner works on, which is
/// information it has no use for and did not ask to be told. The owner's own client has no
/// workspace to be scoped by, so listing is the only way it can find out what it may name.
///
/// Read only, and it says so in the description because that is what the model weighs before
/// deciding whether the call is worth making.
public struct ProjectListTool: BridgeToolHandling {
    public init() {}

    public let roles: Set<BridgeRole> = [.owner]

    public let tool = BridgeTool(
        name: "project_list",
        description: """
            The projects Bloom knows about: the name and the path of each git repository \
            registered in the sidebar, its default branch, how many workspaces it has running, \
            whether it is still where Bloom recorded it, and whether the owner has hidden it \
            from the sidebar.

            Call it before naming a project in any other tool, because Bloom will only act on \
            repositories it already has and this is the list of them. Every project here can be \
            worked in, hidden or not: hidden is a view preference of the owner's sidebar and \
            says nothing about whether the project is finished with. Takes no arguments, reads \
            nothing but Bloom's own database, changes nothing and costs nothing.
            """,
        inputSchema: BridgeTool.noArguments
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        do {
            let projects = try await store.repos()
            guard !projects.isEmpty else {
                return .json(.object([
                    "projects": .array([]),
                    "note": .string(
                        "Bloom has no projects yet. Register an existing git repository with "
                            + "project_add."
                    ),
                ]))
            }

            var rows: [JSONValue] = []
            for project in projects {
                let live = try await store.workspaces(repoID: project.id)
                    .filter { $0.state != .archived }
                rows.append(.object([
                    "id": .string(project.id.rawValue),
                    "name": .string(project.name),
                    "path": .string(project.path),
                    "default_branch": .string(project.defaultBranch),
                    "workspaces_running": .integer(live.count),
                    // Asked of the file system rather than assumed, because a project whose folder
                    // has been moved still has a row, and a caller that starts a workspace in it
                    // gets a failure it could have been warned about here for nothing.
                    "on_disk": .bool(FileManager.default.fileExists(atPath: project.path)),
                    // Reported per project rather than by leaving the hidden ones out, because a
                    // client that could not see them would name one, be refused, and add it again
                    // as a duplicate. It is stated as the state it is (`hidden`) with the tool
                    // that reverses it named in the note below, so an agent asked to tidy or to
                    // restore has something to act on rather than a flag to guess at.
                    "hidden": .bool(project.hidden),
                ]))
            }

            let hidden = ProjectVisibility.hiddenCount(projects)
            guard hidden > 0 else { return .json(.object(["projects": .array(rows)])) }
            return .json(.object([
                "projects": .array(rows),
                "hidden_projects": .integer(hidden),
                "note": .string(
                    "\(hidden == 1 ? "One project is" : "\(hidden) projects are") hidden from "
                        + "Bloom's sidebar. That is a view preference and nothing else: they are "
                        + "still projects, their workspaces still run, and project_unhide puts "
                        + "one back in the list."
                ),
            ]))
        } catch {
            return .failure("Bloom could not read its projects: \(error.readableMessage)")
        }
    }
}
