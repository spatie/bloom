import Foundation

public enum ServerSkillAgent: String, Codable, Sendable, CaseIterable { case claude, codex }
public enum ServerSkillSource: String, Codable, Sendable { case personal, git, project, unmanaged }
public enum ServerSkillsAction: String, Codable, Sendable { case inspect, read, previewImport, previewGit, apply, setEnabled, remove }

public struct ServerSkillFile: Codable, Sendable, Equatable {
    public var path: String
    public var data: Data
    public var isExecutable: Bool?
    public init(path: String, data: Data, isExecutable: Bool = false) {
        self.path = path; self.data = data; self.isExecutable = isExecutable
    }
}

public struct ServerSkillsRequest: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ServerSkillsRequest(action: \(action.rawValue), fileCount: \(files?.count ?? 0))" }
    public var debugDescription: String { description }
    public var action: ServerSkillsAction
    public var workspaceID: WorkspaceID?
    public var files: [ServerSkillFile]?
    public var repositoryURL: String?
    public var ref: String?
    public var collectionID: String?
    public var planID: String?
    public var skillID: String?
    public var revision: String?
    public var selectedSkillNames: [String]?
    public var agents: [ServerSkillAgent]?
    public init(action: ServerSkillsAction, workspaceID: WorkspaceID? = nil, files: [ServerSkillFile]? = nil,
                repositoryURL: String? = nil, ref: String? = nil, collectionID: String? = nil,
                planID: String? = nil, skillID: String? = nil, revision: String? = nil,
                selectedSkillNames: [String]? = nil, agents: [ServerSkillAgent]? = nil) {
        self.action = action; self.workspaceID = workspaceID; self.files = files
        self.repositoryURL = repositoryURL; self.ref = ref; self.collectionID = collectionID
        self.planID = planID; self.skillID = skillID; self.revision = revision
        self.selectedSkillNames = selectedSkillNames; self.agents = agents
    }
}

public struct ServerSkill: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var filePaths: [String]
    public var source: ServerSkillSource
    public var revision: String
    public var enabledAgents: [ServerSkillAgent]
    public var fileCount: Int
    public var byteCount: Int
    public var repositoryURL: String?
    public var commit: String?
    public var ref: String?
    public var collectionID: String?
    public var path: String
    public var warning: String?
    public var isManaged: Bool { source == .personal || source == .git }
    public init(id: String, name: String, description: String, source: ServerSkillSource, revision: String,
                enabledAgents: [ServerSkillAgent], fileCount: Int, byteCount: Int,
                repositoryURL: String? = nil, commit: String? = nil, ref: String? = nil, collectionID: String? = nil,
                path: String, warning: String? = nil, filePaths: [String] = []) {
        self.id = id; self.name = name; self.description = description; self.source = source; self.revision = revision
        self.enabledAgents = enabledAgents; self.fileCount = fileCount; self.byteCount = byteCount
        self.repositoryURL = repositoryURL; self.commit = commit; self.ref = ref; self.collectionID = collectionID
        self.path = path; self.warning = warning; self.filePaths = filePaths
    }
}

public struct ServerSkillsPlan: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var source: ServerSkillSource
    public var skills: [ServerSkill]
    public var repositoryURL: String?
    public var commit: String?
    public var ref: String?
    public var collectionID: String
    public var expiresAt: Date
    public var warnings: [String]
    public init(id: String, source: ServerSkillSource, skills: [ServerSkill], repositoryURL: String?,
                commit: String?, ref: String? = nil, collectionID: String, expiresAt: Date, warnings: [String]) {
        self.id = id; self.source = source; self.skills = skills; self.repositoryURL = repositoryURL
        self.commit = commit; self.ref = ref; self.collectionID = collectionID; self.expiresAt = expiresAt; self.warnings = warnings
    }
}

public struct ServerSkillsResponse: Codable, Sendable, Equatable {
    public var skills: [ServerSkill]
    public var plan: ServerSkillsPlan?
    public var content: String?
    public var warnings: [String]
    public init(skills: [ServerSkill] = [], plan: ServerSkillsPlan? = nil, content: String? = nil, warnings: [String] = []) {
        self.skills = skills; self.plan = plan; self.content = content; self.warnings = warnings
    }
}
