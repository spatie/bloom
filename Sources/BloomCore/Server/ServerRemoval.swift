import Foundation

/// A permanent removal a Bloom Server has worked out, in the words a client shows.
///
/// The server keeps the plan behind it, exactly as it keeps an archive preview, and a client can
/// only hand back the opaque `id`. Nothing a client sends says what is removed: the server looks
/// again when the confirmation comes back and answers with a fresh preview if what it finds is
/// not what the reader was shown.
public struct ServerRemovalPreview: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var message: String
    public var confirmLabel: String
    public var cancelLabel: String
    /// Why this cannot go ahead yet. A client shows it instead of a confirmation, and the server
    /// refuses the removal while it is set.
    public var blocker: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, message: String, confirmLabel: String, cancelLabel: String,
                blocker: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.blocker = blocker
        self.createdAt = createdAt
    }
}

/// What a removal will take, gathered once and gathered again before anything goes.
struct ServerRemovalPlan: Sendable {
    enum Target: Sendable, Equatable {
        case workspace(WorkspaceID)
        case project(RepoID)
    }

    var target: Target
    var preview: ServerRemovalPreview
    /// Everything the confirmation promised apart from sizes, which move while a person reads and
    /// would otherwise send every confirmation back as stale.
    var fingerprint: [String]
    /// Every workspace whose records go, active ones included for a project.
    var workspaceIDs: [WorkspaceID]
    /// Active workspaces a project removal archives first, with the archive confirmation each.
    var archives: [WorkspaceID: UUID] = [:]
    var transcripts: [AgentTranscriptFiles] = []
    var browserProfiles: [String] = []
    /// The managed clone, only when Bloom made it and nothing else uses it.
    var clone: String?

    func matches(_ other: ServerRemovalPlan) -> Bool {
        target == other.target && fingerprint == other.fingerprint && preview.blocker == other.preview.blocker
    }
}

/// Where a server's derived files are, so the planner can be pointed at a scratch directory.
struct ServerRemovalContext: Sendable {
    var store: Store
    var dataDirectory: String
    var home: String
    var codexHome: String?

    init(store: Store, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
         codexHome: String? = ProcessInfo.processInfo.environment["CODEX_HOME"]) {
        self.store = store
        dataDirectory = (store.path as NSString).deletingLastPathComponent
        self.home = home
        self.codexHome = codexHome
    }
}

/// Whether a project's repository goes with it.
enum ServerCloneStanding: Sendable, Equatable {
    case deleted(path: String, bytes: Int)
    case kept(path: String, reason: String)
}

enum ServerRemoval {
    /// Said at the foot of both confirmations, because a delete that frees nothing a person can
    /// see is the complaint this whole feature answers.
    static let compaction = "Bloom Server then compacts its database once no agent is working, so the space goes back to the disk."

    // MARK: - Deleting an archived workspace

    static func workspacePlan(_ workspace: Workspace, context: ServerRemovalContext) async throws -> ServerRemovalPlan {
        guard workspace.state == .archived else {
            throw ServerFailure("Only an archived workspace can be deleted permanently. Archive it first.")
        }
        let store = context.store
        guard var footprint = try await store.archivedFootprints().first(where: { $0.id == workspace.id }) else {
            throw ServerFailure("This workspace is no longer available.")
        }
        if let repo = try await store.repo(id: workspace.repoID), let branches = try? await Git.branches(of: repo.path) {
            footprint.branchIsLocal = branches.contains(workspace.branch)
        }
        let keeping = try await store.agentThreadIDs(outside: [workspace.id])
        let transcripts = try await Self.transcripts(for: workspace, keeping: keeping, context: context)
        let profiles = browserProfiles(for: workspace, context: context)
        let deletion = ArchiveDeletion([footprint], host: "the server",
                                       filesOnDisk: fileLosses(transcripts: [transcripts], browserProfiles: profiles))
        let preview = ServerRemovalPreview(title: deletion.title, message: deletion.message + "\n\n" + compaction,
                                           confirmLabel: deletion.confirmLabel, cancelLabel: deletion.cancelLabel)
        let fingerprint = [workspace.id.rawValue, workspace.state.rawValue, "\(footprint.sessionCount)", "\(footprint.messageCount)",
                           "\(footprint.reviewCommentCount)", "\(footprint.hasNote)", "\(String(describing: footprint.branchIsLocal))"]
            + transcripts.paths + profiles
        return ServerRemovalPlan(target: .workspace(workspace.id), preview: preview, fingerprint: fingerprint,
                                 workspaceIDs: [workspace.id], transcripts: [transcripts], browserProfiles: profiles)
    }

    // MARK: - Removing a project

    /// - Parameter archives: the archive preview of every active workspace, or the reason one
    ///   could not be prepared. The runtime owns those previews, so it hands them in.
    static func projectPlan(_ repo: Repo, archives: [WorkspaceID: Result<ServerArchivePreview, ServerFailure>],
                            context: ServerRemovalContext) async throws -> ServerRemovalPlan {
        let store = context.store
        let footprints = try await store.footprints(repoID: repo.id)
        let workspaces = footprints.map(\.workspace)
        let keeping = try await store.agentThreadIDs(outside: workspaces.map(\.id))
        var transcripts: [AgentTranscriptFiles] = []
        var profiles: [String] = []
        for workspace in workspaces {
            transcripts.append(try await Self.transcripts(for: workspace, keeping: keeping, context: context))
            profiles += browserProfiles(for: workspace, context: context)
        }
        let active = workspaces.filter { $0.state == .active }
        var blockers: [String] = []
        var confirmations: [WorkspaceID: UUID] = [:]
        for workspace in active {
            switch archives[workspace.id] {
            case .success(let preview) where preview.request.severity == .routine:
                confirmations[workspace.id] = preview.id
            case .success(let preview):
                blockers.append("\u{201C}\(workspace.name)\u{201D} \(preview.hazards.isAgentRunning ? "has an agent working in it" : "holds work that exists nowhere else").")
            case .failure(let failure):
                blockers.append("\u{201C}\(workspace.name)\u{201D}: \(failure.localizedDescription)")
            case nil:
                blockers.append("\u{201C}\(workspace.name)\u{201D} could not be checked.")
            }
        }
        let clone = await cloneStanding(repo, archiving: active, context: context)
        let facts = ServerProjectRemovalFacts(
            projectName: repo.name, activeCount: active.count, deletion: ArchiveDeletion(footprints, host: "the server",
                filesOnDisk: fileLosses(transcripts: transcripts, browserProfiles: profiles)),
            clone: clone, blockers: blockers)
        var fingerprint = footprints.flatMap { [$0.id.rawValue, $0.workspace.state.rawValue, "\($0.sessionCount)", "\($0.messageCount)", "\($0.reviewCommentCount)", "\($0.hasNote)"] }
        fingerprint += transcripts.flatMap(\.paths) + profiles
        switch clone {
        case .deleted(let path, _): fingerprint.append("delete " + path)
        case .kept(let path, let reason): fingerprint.append("keep \(path) \(reason)")
        }
        var clonePath: String?
        if case .deleted(let path, _) = clone { clonePath = path }
        return ServerRemovalPlan(target: .project(repo.id), preview: ServerRemovalCopy.project(facts), fingerprint: fingerprint,
                                 workspaceIDs: workspaces.map(\.id), archives: confirmations, transcripts: transcripts,
                                 browserProfiles: profiles, clone: clonePath)
    }

    // MARK: - Files

    static func transcripts(for workspace: Workspace, keeping: Set<String>, context: ServerRemovalContext) async throws -> AgentTranscriptFiles {
        let threads = try await context.store.agentThreads(workspaceID: workspace.id)
        return AgentTranscriptFiles.find(worktree: workspace.path, threads: threads, keeping: keeping,
                                         home: context.home, codexHome: context.codexHome)
    }

    /// A workspace's browser profile, as `install-bloom-browser.py` lays it out: the first 24 hex
    /// digits of the SHA-256 of `BLOOM_WORKSPACE_ID`, or of the working directory when that is not
    /// set, under `browser/workspaces` in the data directory. Both keys are tried, under both the
    /// store's own data directory and the default one the browser wrapper writes to, and only a
    /// real directory with exactly that name is taken.
    static func browserProfiles(for workspace: Workspace, context: ServerRemovalContext) -> [String] {
        let roots = Set([(context.dataDirectory as NSString).appendingPathComponent("browser"),
                         (context.home as NSString).appendingPathComponent("bloom/data/browser")])
        let keys = Set([workspace.id.rawValue, workspace.path].map { String(ServerFileOperations.revision(Data($0.utf8)).prefix(24)) })
        var found: [String] = []
        for root in roots.sorted() {
            for key in keys.sorted() {
                let path = ((root as NSString).appendingPathComponent("workspaces") as NSString).appendingPathComponent(key)
                if isRealDirectory(path) { found.append(path) }
            }
        }
        return found
    }

    static func fileLosses(transcripts: [AgentTranscriptFiles], browserProfiles: [String]) -> [String] {
        var lines: [String] = []
        let claude = transcripts.reduce(0) { $0 + $1.claudeSessions }
        let codex = transcripts.reduce(0) { $0 + $1.codexSessions }
        let merged = AgentTranscriptFiles(paths: transcripts.flatMap(\.paths), bytes: transcripts.reduce(0) { $0 + $1.bytes },
                                          claudeSessions: claude, codexSessions: codex)
        if let loss = merged.loss { lines.append(loss) }
        if !browserProfiles.isEmpty {
            let bytes = browserProfiles.reduce(0) { $0 + AgentTranscriptFiles.size(of: $1) }
            let noun = browserProfiles.count == 1 ? "The workspace browser profile" : "\(browserProfiles.count) workspace browser profiles"
            lines.append("\(noun), holding \(ArchiveDeletion.bytes(bytes))")
        }
        return lines
    }

    /// Removes a plan's files, and names what would not go.
    static func removeFiles(of plan: ServerRemovalPlan) -> [String] {
        var failures = plan.transcripts.flatMap { $0.remove() }
        for path in plan.browserProfiles {
            do { try FileManager.default.removeItem(atPath: path) } catch {
                if FileManager.default.fileExists(atPath: path) { failures.append(path) }
            }
        }
        return failures
    }

    // MARK: - The repository

    /// Decides whether a project's repository is deleted with it, and says why when it is not.
    ///
    /// **Only a clone Bloom made.** `ServerRepositoryResolver` clones a URL into
    /// `<data>/repositories/<name>-<12 hex digits>`, so a directory there with that shape is one
    /// Bloom created. A path somebody typed is their repository and is never touched, whatever it
    /// looks like. A clone another project row points at, that holds another project's workspace,
    /// or that git says still has a worktree this removal is not archiving, is kept as well.
    static func cloneStanding(_ repo: Repo, archiving: [Workspace], context: ServerRemovalContext) async -> ServerCloneStanding {
        let path = (repo.path as NSString).standardizingPath
        guard isManagedClone(path, dataDirectory: context.dataDirectory) else {
            return .kept(path: repo.path, reason: "Bloom did not create it")
        }
        let store = context.store
        let others = ((try? await store.repos()) ?? []).filter { $0.id != repo.id }
        if others.contains(where: { ($0.path as NSString).standardizingPath == path }) {
            return .kept(path: repo.path, reason: "another project on this server uses it")
        }
        let foreign = ((try? await store.workspaces(includeArchived: true)) ?? []).filter { $0.repoID != repo.id }
        if foreign.contains(where: { ($0.path as NSString).standardizingPath.hasPrefix(path + "/") }) {
            return .kept(path: repo.path, reason: "a workspace of another project lives inside it")
        }
        guard let worktrees = try? await Git.worktrees(of: path) else {
            return .kept(path: repo.path, reason: "Bloom could not read its worktrees")
        }
        let leaving = Set(archiving.map { ($0.path as NSString).standardizingPath })
        let remaining = worktrees.map { ($0.path as NSString).standardizingPath }
            .filter { $0 != path && !leaving.contains($0) && FileManager.default.fileExists(atPath: $0) }
        guard remaining.isEmpty else {
            return .kept(path: repo.path, reason: "a worktree Bloom does not know about still uses it")
        }
        return .deleted(path: repo.path, bytes: AgentTranscriptFiles.size(of: path))
    }

    static func isManagedClone(_ path: String, dataDirectory: String) -> Bool {
        let root = ((dataDirectory as NSString).appendingPathComponent("repositories") as NSString).standardizingPath
        let standardized = (path as NSString).standardizingPath
        let name = (standardized as NSString).lastPathComponent
        guard (standardized as NSString).deletingLastPathComponent == root,
              name.range(of: "^[A-Za-z0-9_.-]+-[0-9a-f]{12}$", options: .regularExpression) != nil else { return false }
        return isRealDirectory(standardized)
    }

    static func isRealDirectory(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }
}

/// What a project removal on a server takes, gathered so the words can be tested without one.
struct ServerProjectRemovalFacts: Sendable, Equatable {
    var projectName: String
    var activeCount: Int
    /// Every workspace the project has, measured, with the files on disk that go with them.
    var deletion: ArchiveDeletion
    var clone: ServerCloneStanding
    /// One sentence per active workspace that cannot be archived without asking.
    var blockers: [String]
}

enum ServerRemovalCopy {
    static func project(_ facts: ServerProjectRemovalFacts) -> ServerRemovalPreview {
        let title = "Remove \(facts.projectName)?"
        if !facts.blockers.isEmpty {
            let pronoun = facts.blockers.count == 1 ? "it" : "them"
            let blocker = "\(facts.projectName) cannot be removed yet, because its active workspaces are archived first and "
                + "\(facts.blockers.count == 1 ? "one of them" : "some of them") cannot be archived without asking.\n\n"
                + facts.blockers.map { "\u{2022} \($0)" }.joined(separator: "\n")
                + "\n\nArchive \(pronoun) from the sidebar, where the confirmation shows what would be lost, then remove the project."
            return ServerRemovalPreview(title: "\(facts.projectName) cannot be removed yet", message: blocker,
                                        confirmLabel: "Remove Project", cancelLabel: "OK", blocker: blocker)
        }

        var body = "Bloom Server forgets this project and permanently deletes everything it kept about its workspaces."
        if facts.activeCount > 0 {
            body += facts.activeCount == 1
                ? " Its active workspace is archived first: its archive script runs and its worktree is removed."
                : " Its \(Counted.of(facts.activeCount, "active workspace")) are archived first: their archive scripts run and their worktrees are removed."
        }
        var losses = facts.deletion.losses
        switch facts.clone {
        case .deleted(let path, let bytes):
            losses.append("The repository clone Bloom made at \(path), holding \(ArchiveDeletion.bytes(bytes)), with any branch that was never pushed")
        case .kept: break
        }
        if !losses.isEmpty {
            body += "\n\nThis deletes:\n" + losses.map { "\u{2022} \($0)" }.joined(separator: "\n")
        }
        if case .kept(let path, let reason) = facts.clone {
            body += "\n\nThe repository at \(path) stays on the server, because \(reason)."
        }
        body += "\n\n" + ServerRemoval.compaction
        return ServerRemovalPreview(title: title, message: body,
                                    confirmLabel: facts.activeCount > 0 ? "Archive and Remove" : "Remove Project",
                                    cancelLabel: "Keep Project")
    }
}
