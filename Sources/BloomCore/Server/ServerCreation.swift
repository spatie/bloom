import Foundation

public enum ServerCreationOperation: Codable, Sendable, Equatable {
    case githubRepositories(query: String, page: Int)
    case importGitHub(String)
    case projectContext
    case inspectProject(String)
    case startProject(typed: String, expected: NewProjectFacts)
    case workspaceContext(RepoID)
    case checkouts(RepoID)
    case resolveReference(repoID: RepoID, reference: String)

    var mutates: Bool {
        switch self {
        case .importGitHub, .startProject: true
        default: false
        }
    }
}

public struct ServerProjectContext: Codable, Sendable {
    public var home: String
    public var location: String
    public var projectPaths: [String]
    public var branch: String
    public var identityProblem: String?
}

public struct ServerProjectInspection: Codable, Sendable {
    public var facts: NewProjectFacts
    public var contents: FolderContents?
    public var completions: [String]
}

public struct ServerWorkspaceContext: Codable, Sendable {
    public var branches: [String]
    public var branchPrefix: String?
    public var hasSetupScript: Bool
    public var composer: ServerComposerState
    public var files: [String]
}

public struct ServerInitialAttachment: Codable, Sendable, Equatable {
    public var sourcePath: String
    public var name: String
    public var data: Data

    public init(sourcePath: String, name: String, data: Data) {
        self.sourcePath = sourcePath; self.name = name; self.data = data
    }
}

public enum ServerCreationResult: Codable, Sendable {
    case workspaceStarted(workspace: Workspace, session: Session?, setupSucceeded: Bool?, draft: String?)
    case repositories([GitHubRepositoryListing])
    case project(Repo)
    case projectContext(ServerProjectContext)
    case inspection(ServerProjectInspection)
    case workspaceContext(ServerWorkspaceContext)
    case checkouts(WorkspaceCheckoutOptions)
    case reference(WorkspaceCheckoutResolution)
}

/// All filesystem and gh work stays on the execution host. Both UIs use these same core planners.
public enum ProjectCreationOperations {
    public static func context(store: Store) async -> ServerProjectContext {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferences = await DirectoryPreferences.load(from: store)
        let paths = (try? await store.repos().map(\.path)) ?? []
        return ServerProjectContext(home: home, location: preferences.projectLocation(projectPaths: paths, home: home),
            projectPaths: paths, branch: await NewProjectStarter.plannedBranch(),
            identityProblem: await RepositoryStarter.identityProblem(at: home))
    }

    public static func perform(_ operation: ServerCreationOperation, store: Store, models: [CodexModel] = []) async throws -> ServerCreationResult {
        switch operation {
        case .githubRepositories(let query, let page):
            return .repositories(try await GitHubRepositoryBrowser.repositories(query: query, page: page))
        case .importGitHub(let name):
            let directory = URL(fileURLWithPath: await context(store: store).location)
            let path = try await GitHubRepositoryBrowser.clone(name, under: directory)
            return .project(try await WorkspaceManager(store: store).addRepository(at: path))
        case .projectContext: return .projectContext(await context(store: store))
        case .inspectProject(let typed):
            guard typed.utf8.count <= 4_096 else { throw ServerFailure("Use a shorter project path.") }
            let context = await context(store: store)
            let facts = NewProjectStarter.inspect(typed: typed, defaultLocation: context.location)
            let contents: FolderContents? = if case .track = ProjectTargetVerdict.of(facts) { RepositoryStarter.scan(facts.path) } else { nil }
            let preferences = await DirectoryPreferences.load(from: store)
            let locations = preferences.searchLocations(projectPaths: context.projectPaths, home: context.home)
            return .inspection(ServerProjectInspection(facts: facts, contents: contents,
                completions: ProjectCompletion.matches(typed, locations: locations, home: context.home)))
        case .startProject(let typed, let expected):
            let context = await context(store: store)
            let facts = NewProjectStarter.inspect(typed: typed, defaultLocation: context.location)
            guard facts == expected else { throw ServerFailure("The folder changed. Review it again before starting the project.") }
            let verdict = ProjectTargetVerdict.of(facts)
            guard verdict.isAllowed else { throw ServerFailure("This folder cannot become a project. Review the selected path.") }
            let path: String
            if case .add(let existing) = verdict { path = existing } else {
                if let problem = context.identityProblem { throw ServerFailure(problem) }
                path = try await NewProjectStarter.create(at: facts.path).path
            }
            return .project(try await WorkspaceManager(store: store).addRepository(at: path))
        case .workspaceContext(let id):
            let repo = try await repository(id, store: store)
            let context = await WorkspaceStartContext.load(repoPath: repo.path)
            let defaults = await AppDefaults.load(from: store)
            let controls = ComposerControls(defaults: ComposerDefaults.resolve(repo: context.settings, app: defaults),
                isFastMode: defaults.fastMode, outputStyle: defaults.outputStyle, codexContextWindow: defaults.codexContextWindow)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let listing = try await Git.checkRaw(["ls-files", "-z", "--cached"], in: repo.path)
            let files = String(decoding: listing.stdout, as: UTF8.self).split(separator: "\0").map(String.init)
            return .workspaceContext(ServerWorkspaceContext(branches: context.branches, branchPrefix: context.settings.branchPrefix,
                hasSetupScript: !(context.settings.setupScript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, composer: ServerComposerState(controls: controls, models: models, commands: SlashCommandIndex.discover(home: home, project: repo.path), styles: OutputStyleIndex.discover(home: home, project: repo.path)), files: files))
        case .checkouts(let id):
            let repo = try await repository(id, store: store)
            return .checkouts(await WorkspaceCheckoutOptions.load(repoPath: repo.path, repoID: repo.id, defaultBranch: repo.defaultBranch, workspaces: try await store.workspaces()))
        case .resolveReference(let id, let reference):
            let repo = try await repository(id, store: store)
            return .reference(await WorkspaceCheckoutResolver.resolve(reference, repoPath: repo.path))
        }
    }

    private static func repository(_ id: RepoID, store: Store) async throws -> Repo {
        guard let repo = try await store.repo(id: id) else { throw ServerFailure("This project is no longer available on the server.") }
        return repo
    }
}
