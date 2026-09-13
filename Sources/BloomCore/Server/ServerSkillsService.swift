import BloomClient
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Skills are service-account files. The durable index owns provenance; agent folders contain
/// only individually checked links, so unmanaged skills are never replaced or removed.
public actor ServerSkillsService {
    struct Pending: Sendable {
        var plan: ServerSkillsPlan
        var files: [ServerSkillFile]
        var baselines: [String: String]
    }
    struct Transaction: Codable { var before: [ServerSkill]; var after: [ServerSkill] }
    private let beforeIndexCommit: @Sendable () throws -> Void
    private let directory: String
    private let home: String
    private var plans: [String: Pending] = [:]
    private var fetching = false
    private let fetch: @Sendable (String, String, String) async throws -> ServerSkillsGit.Snapshot

    public init(directory: String, home: String) {
        self.directory = directory; self.home = home
        beforeIndexCommit = {}
        fetch = { try await ServerSkillsGit.fetch(repository: $0, ref: $1, staging: $2) }
    }

    init(directory: String, home: String,
         fetch: @escaping @Sendable (String, String, String) async throws -> ServerSkillsGit.Snapshot,
         beforeIndexCommit: @escaping @Sendable () throws -> Void = {}) {
        self.directory = directory; self.home = home; self.fetch = fetch; self.beforeIndexCommit = beforeIndexCommit
    }

    public func handle(_ request: ServerSkillsRequest, workspacePath: String? = nil) async throws -> ServerSkillsResponse {
        guard geteuid() != 0 else { throw ServerFailure("Skills must be managed by the Bloom service account, never root.") }
        try recoverTransaction()
        plans = plans.filter { $0.value.plan.expiresAt > Date() }
        switch request.action {
        case .inspect:
            return try inspect(workspacePath: workspacePath)
        case .read:
            return try read(request, workspacePath: workspacePath)
        case .previewImport:
            guard let files = request.files else { throw ServerFailure("Choose a skill folder to import.") }
            return try preview(files: files, source: .personal, repository: nil, commit: nil, ref: nil, collectionID: nil)
        case .previewGit:
            guard !fetching else { throw ServerFailure("A collection is already being downloaded. Wait for it to finish.") }
            guard let repository = request.repositoryURL else { throw ServerFailure("Enter a Git repository URL.") }
            let tracked = try records().first { $0.collectionID == request.collectionID && $0.source == .git }
            let ref = request.ref ?? tracked?.ref ?? "HEAD"
            try ServerSkillsGit.validate(repository: repository, ref: ref)
            try admission()
            if let id = request.collectionID {
                guard try records().contains(where: { $0.collectionID == id && $0.repositoryURL == repository && $0.source == .git }) else {
                    throw ServerFailure("This collection changed. Refresh its details before reviewing an update.")
                }
            }
            let storage = try storage()
            _ = try storage.directory("downloads", create: true)
            fetching = true
            defer { fetching = false }
            let snapshot = try await fetch(repository, ref, directory + "/downloads")
            try Task.checkCancellation()
            return try preview(files: snapshot.files, source: .git, repository: repository,
                               commit: snapshot.commit, ref: ref, collectionID: request.collectionID)
        case .apply:
            try apply(request)
            return try inspect(workspacePath: workspacePath)
        case .setEnabled:
            var all = try observed(records())
            let index = try selected(request, records: all)
            let agents = try agents(request.agents)
            let before = try observed(all)
            all[index].enabledAgents = agents
            try transition(before: before, after: all)
            return try inspect(workspacePath: workspacePath)
        case .remove:
            var all = try observed(records())
            let index = try selected(request, records: all)
            let before = try observed(all)
            all.remove(at: index)
            try transition(before: before, after: all)
            // Immutable package versions stay in managed storage for crash recovery. They are
            // no longer discoverable by agents and never include files outside this service.
            return try inspect(workspacePath: workspacePath)
        }
    }

    private func storage() throws -> ServerSkillDirectory {
        let url = URL(fileURLWithPath: directory)
        let parent = try ServerSkillDirectory(path: url.deletingLastPathComponent().path)
        return try parent.directory(url.lastPathComponent, create: true)
    }

    private func records() throws -> [ServerSkill] {
        let storage = try storage()
        guard try storage.names().contains("index.json") else { return [] }
        let values = try JSONDecoder().decode([ServerSkill].self, from: storage.read("index.json", limit: 4_194_304))
        try validateRecords(values)
        return values
    }

    private func validateRecords(_ values: [ServerSkill]) throws {
        guard values.count <= 256, Set(values.map(\.id)).count == values.count else { throw ServerFailure("The managed skill index is invalid.") }
        for value in values {
            guard UUID(uuidString: value.id) != nil, ServerSkillBundlePolicy.validName(value.name),
                  value.path.hasPrefix(directory + "/bundles/"),
                  value.path.dropFirst((directory + "/bundles/").count).split(separator: "/").count == 1,
                  UUID(uuidString: String(value.path.dropFirst((directory + "/bundles/").count))) != nil,
                  value.isManaged else { throw ServerFailure("The managed skill index contains an invalid entry.") }
        }
    }

    private func save(_ values: [ServerSkill]) throws {
        let data = try JSONEncoder().encode(values)
        guard data.count <= 4_194_304 else { throw ServerFailure("The managed skill catalogue has reached its size limit.") }
        try storage().write("index.json", data: data, replace: true)
    }

    private func inspect(workspacePath: String? = nil) throws -> ServerSkillsResponse {
        var values = try records().map { try actual($0) }
        var warnings: [String] = []
        for (agent, path) in [(ServerSkillAgent.claude, ".claude/skills"), (.codex, ".agents/skills"), (.codex, ".codex/skills")] {
            do {
                let root = try ServerSkillDirectory(path: home).directory(path)
                let managedNames = Set(values.filter { $0.isManaged && $0.enabledAgents.contains(agent) && path == Self.agentPath(agent) }.map(\.name))
                for name in try root.names() where !managedNames.contains(name) && ServerSkillBundlePolicy.validName(name) {
                    if let skill = try? inventory(root: root, name: name, source: .unmanaged,
                                                  path: home + "/" + path + "/" + name, agents: [agent]) {
                        values.append(skill)
                    } else {
                        warnings.append("An unmanaged \(agent.rawValue) skill named \(name) could not be read safely. Its files were preserved.")
                    }
                }
            } catch {
                // Missing agent directories are normal before the first skill is enabled.
                if FileManager.default.fileExists(atPath: home + "/" + path) {
                    warnings.append("The \(agent.rawValue) skills directory could not be inspected safely.")
                }
            }
        }
        if let workspacePath {
            for (path, agents): (String, [ServerSkillAgent]) in [(".claude/skills", [.claude]), (".agents/skills", [.codex]), (".codex/skills", [.codex])] {
                do {
                    let root = try ServerSkillDirectory(path: workspacePath).directory(path)
                    for name in try root.names() where ServerSkillBundlePolicy.validName(name) {
                        if let skill = try? inventory(root: root, name: name, source: .project,
                                                      path: path + "/" + name, agents: agents) { values.append(skill) }
                    }
                } catch {
                    if FileManager.default.fileExists(atPath: workspacePath + "/" + path) {
                        warnings.append("Some project skills in \(path) could not be read safely. Project skills are managed in the repository.")
                    }
                }
            }
        }
        guard values.count <= 512 else { throw ServerFailure("This server has too many skills to inspect in one list. Inspect one workspace at a time.") }
        values = values.map { var value = $0; value.filePaths = []; return value }
        return ServerSkillsResponse(skills: values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }, warnings: warnings)
    }

    private func inventory(root: ServerSkillDirectory, name: String, source: ServerSkillSource,
                           path: String, agents: [ServerSkillAgent]) throws -> ServerSkill {
        let data = try root.directory(name).read("SKILL.md", limit: ServerSkillBundlePolicy.maximumInstructionsBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw ServerFailure("SKILL.md is not UTF-8 text.") }
        return ServerSkill(id: source.rawValue + ":" + path, name: name, description: Self.summary(text), source: source,
                           revision: ServerFileOperations.revision(data), enabledAgents: agents, fileCount: 1, byteCount: data.count,
                           path: path, filePaths: ["SKILL.md"])
    }

    private func actual(_ value: ServerSkill) throws -> ServerSkill {
        var value = value
        var enabled: [ServerSkillAgent] = []
        for agent in ServerSkillAgent.allCases {
            if let root = try? ServerSkillDirectory(path: home).directory(Self.agentPath(agent)),
               let target = try? root.link(value.name), target == value.path { enabled.append(agent) }
        }
        value.enabledAgents = enabled
        // Include actual link state in the optimistic revision. Two clients cannot overwrite
        // each other's enable/disable decision using the same stale content revision.
        value.revision = ServerFileOperations.revision(Data((value.revision + enabled.map(\.rawValue).joined(separator: ",")).utf8))
        return value
    }

    private func read(_ request: ServerSkillsRequest, workspacePath: String?) throws -> ServerSkillsResponse {
        guard let id = request.skillID else { throw ServerFailure("Choose a skill to inspect.") }
        if let planID = request.planID {
            guard let pending = plans[planID], let skill = pending.plan.skills.first(where: { $0.id == id }),
                  let file = pending.files.first(where: { $0.path == skill.name + "/SKILL.md" }),
                  let text = String(data: file.data, encoding: .utf8) else { throw ServerFailure("This review expired. Preview the collection again.") }
            return ServerSkillsResponse(skills: [skill], content: text)
        }
        guard var skill = try inspect(workspacePath: workspacePath).skills.first(where: { $0.id == id }) else { throw ServerFailure("This skill is no longer available. Refresh the list.") }
        let data: Data
        if skill.isManaged {
            if let stored = try records().first(where: { $0.id == id }) { skill.filePaths = stored.filePaths }
            data = try storage().read(String(skill.path.dropFirst(directory.count + 1)) + "/SKILL.md", limit: ServerSkillBundlePolicy.maximumInstructionsBytes)
        } else if skill.source == .project, let workspacePath {
            data = try ServerSkillDirectory(path: workspacePath).read(skill.path + "/SKILL.md", limit: ServerSkillBundlePolicy.maximumInstructionsBytes)
        } else {
            data = try ServerSkillDirectory(path: home).read(String(skill.path.dropFirst(home.count + 1)) + "/SKILL.md", limit: ServerSkillBundlePolicy.maximumInstructionsBytes)
        }
        guard let content = String(data: data, encoding: .utf8) else { throw ServerFailure("SKILL.md is not UTF-8 text.") }
        return ServerSkillsResponse(skills: [skill], content: content)
    }

    private func admission() throws {
        guard plans.count < 4 else { throw ServerFailure("Four skill reviews are already open. Finish one or wait 15 minutes before preparing another.") }
    }

    private func preview(files: [ServerSkillFile], source: ServerSkillSource, repository: String?,
                         commit: String?, ref: String?, collectionID existingCollection: String?) throws -> ServerSkillsResponse {
        try admission()
        try ServerSkillBundlePolicy.validate(files)
        let all = try records()
        let collectionID = existingCollection ?? UUID().uuidString
        let groups = Dictionary(grouping: files) { String($0.path.split(separator: "/")[0]) }
        guard groups.count <= 64 else { throw ServerFailure("A collection can contain at most 64 skills.") }
        var skills: [ServerSkill] = []
        var baselines: [String: String] = [:]
        for (name, files) in groups.sorted(by: { $0.key < $1.key }) {
            guard let instructions = files.first(where: { $0.path == name + "/SKILL.md" }),
                  let text = String(data: instructions.data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServerFailure("Each skill needs a non-empty UTF-8 SKILL.md directly inside its folder.")
            }
            let existing = all.first { $0.collectionID == collectionID && $0.name == name }
            if let existing { baselines[existing.id] = try actual(existing).revision }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let revision = ServerFileOperations.revision(try encoder.encode(files.sorted { $0.path < $1.path }))
            skills.append(ServerSkill(id: existing?.id ?? UUID().uuidString, name: name, description: Self.summary(text),
                source: source, revision: revision, enabledAgents: existing?.enabledAgents ?? [], fileCount: files.count,
                byteCount: files.reduce(0) { $0 + $1.data.count }, repositoryURL: repository, commit: commit, ref: ref,
                collectionID: collectionID, path: name, filePaths: files.map { String($0.path.dropFirst(name.count + 1)) }.sorted()))
        }
        let plan = ServerSkillsPlan(id: UUID().uuidString, source: source, skills: skills, repositoryURL: repository,
            commit: commit, ref: ref, collectionID: collectionID, expiresAt: Date().addingTimeInterval(900), warnings: [
                "Skills can contain instructions and scripts that agents may execute later. Only enable skills from authors you trust.",
                "Existing conversations may need a new agent session to discover changed skills.",
            ])
        plans[plan.id] = Pending(plan: plan, files: files, baselines: baselines)
        return ServerSkillsResponse(plan: plan)
    }

    private func selected(_ request: ServerSkillsRequest, records: [ServerSkill]) throws -> Int {
        guard let id = request.skillID, let index = records.firstIndex(where: { $0.id == id }),
              request.revision == (try actual(records[index]).revision) else {
            throw ServerFailure("This skill changed since you opened it. Refresh before changing it.")
        }
        return index
    }

    private func agents(_ requested: [ServerSkillAgent]?) throws -> [ServerSkillAgent] {
        guard let requested, Set(requested).count == requested.count else { throw ServerFailure("Choose which agents should use these skills.") }
        return requested.sorted { $0.rawValue < $1.rawValue }
    }

    private func apply(_ request: ServerSkillsRequest) throws {
        guard let id = request.planID, let pending = plans[id], pending.plan.expiresAt > Date(),
              let names = request.selectedSkillNames, !names.isEmpty, Set(names).count == names.count,
              Set(names).isSubset(of: Set(pending.plan.skills.map(\.name))) else {
            throw ServerFailure("Choose skills from a current review before installing.")
        }
        let agents = try agents(request.agents)
        var all = try observed(records())
        let selected = pending.plan.skills.filter { names.contains($0.name) }
        guard all.count + selected.filter({ skill in !all.contains { $0.id == skill.id } }).count <= 256 else {
            throw ServerFailure("This server already has the maximum of 256 managed skills.")
        }
        for skill in selected {
            if let existing = all.first(where: { $0.id == skill.id }), pending.baselines[skill.id] != (try actual(existing).revision) {
                throw ServerFailure("A skill changed after this review was prepared. Preview the update again.")
            }
            try validateLinks(skill: all.first(where: { $0.id == skill.id }) ?? skill, agents: agents)
        }
        let storage = try storage()
        let before = try observed(all)
        for var skill in selected {
            let relative = "bundles/" + UUID().uuidString
            _ = try storage.directory(relative, create: true)
            for file in pending.files where file.path.hasPrefix(skill.name + "/") {
                try storage.write(relative + "/" + file.path.dropFirst(skill.name.count + 1), data: file.data,
                                  executable: file.isExecutable == true)
            }
            skill.path = directory + "/" + relative
            skill.enabledAgents = agents
            all.removeAll { $0.id == skill.id }
            all.append(skill)
        }
        try transition(before: before, after: all)
        plans.removeValue(forKey: id)
    }

    private func observed(_ records: [ServerSkill]) throws -> [ServerSkill] {
        try records.map { original in
            var value = original
            value.enabledAgents = try actual(original).enabledAgents
            return value
        }
    }

    private func reconcile(from old: [ServerSkill], to target: [ServerSkill]) throws {
        let removed = old.filter { original in !target.contains(original) }
        let added = target.filter { updated in !old.contains(updated) }
        for skill in added { try validateLinksForTransition(skill: skill, previous: removed) }
        for skill in removed { try changeLinks(skill: skill, agents: []) }
        for skill in added { try changeLinks(skill: skill, agents: skill.enabledAgents) }
    }

    private func validateLinksForTransition(skill: ServerSkill, previous: [ServerSkill]) throws {
        for agent in skill.enabledAgents {
            let root = try ServerSkillDirectory(path: home).directory(Self.agentPath(agent), create: true)
            if let link = try root.link(skill.name), link != skill.path,
               !previous.contains(where: { $0.name == skill.name && $0.path == link }) {
                throw ServerFailure("An unmanaged skill uses this name. Its files were preserved.")
            }
        }
    }

    private func transition(before: [ServerSkill], after: [ServerSkill]) throws {
        let storage = try storage()
        guard try JSONEncoder().encode(after).count <= 4_194_304 else { throw ServerFailure("The managed skill catalogue has reached its size limit.") }
        try storage.write("transaction.json", data: JSONEncoder().encode(Transaction(before: before, after: after)))
        do {
            try reconcile(from: before, to: after)
            try beforeIndexCommit()
            try save(after)
            try storage.removeFile("transaction.json")
        } catch {
            let failure = error.localizedDescription
            do {
                try reconcile(from: after, to: before)
                try save(before)
                try storage.removeFile("transaction.json")
            } catch {
                throw ServerFailure(failure + " Recovery could not finish: " + error.localizedDescription + " Refresh to retry recovery. No package scripts will run.")
            }
            throw ServerFailure(failure + " Previous skill settings were restored.")
        }
    }

    private func recoverTransaction() throws {
        let storage = try storage()
        guard try storage.names().contains("transaction.json") else { return }
        let transaction = try JSONDecoder().decode(Transaction.self, from: storage.read("transaction.json", limit: 8_388_608))
        try validateRecords(transaction.before)
        try validateRecords(transaction.after)
        let committed = try records() == transaction.after
        let target = committed ? transaction.after : transaction.before
        let previous = committed ? transaction.before : transaction.after
        try reconcile(from: previous, to: target)
        try save(target)
        try storage.removeFile("transaction.json")
    }

    private func validateLinks(skill: ServerSkill, agents: [ServerSkillAgent]) throws {
        if agents.contains(.codex), let legacy = try? ServerSkillDirectory(path: home).directory(".codex/skills"),
           try legacy.names().contains(skill.name) {
            throw ServerFailure("A legacy Codex skill already uses this name in ~/.codex/skills. Rename the imported skill first. Existing skills were preserved.")
        }
        for agent in agents {
            let root = try ServerSkillDirectory(path: home).directory(Self.agentPath(agent), create: true)
            if let existing = try root.link(skill.name), existing != skill.path {
                throw ServerFailure("An existing \(agent.rawValue) skill named \(skill.name) is not managed by this collection. It was preserved.")
            }
        }
    }

    private func changeLinks(skill: ServerSkill, agents: [ServerSkillAgent]) throws {
        try validateLinks(skill: skill, agents: agents)
        for agent in ServerSkillAgent.allCases {
            let root = try ServerSkillDirectory(path: home).directory(Self.agentPath(agent), create: true)
            let current = try? root.link(skill.name)
            if agents.contains(agent) {
                if current == nil { try root.publish(skill.name, target: skill.path) }
            } else if current == skill.path { try root.unpublish(skill.name, target: skill.path) }
        }
    }

    /// Container adapters mount these directories read-only. Bundle targets keep their original
    /// absolute path so the same discovery links work for both host and container agents.
    public func activeContainerEnvironment() throws -> [String: String] {
        guard try records().contains(where: { !$0.enabledAgents.isEmpty }) else { return [:] }
        return try Self.containerEnvironment(directory: directory, home: home)
    }

    public static func containerEnvironment(directory: String, home: String) throws -> [String: String] {
        guard geteuid() != 0 else { throw ServerFailure("Skill directories must belong to the Bloom service account.") }
        let url = URL(fileURLWithPath: directory)
        let storage = try ServerSkillDirectory(path: url.deletingLastPathComponent().path).directory(url.lastPathComponent, create: true)
        _ = try storage.directory("bundles", create: true)
        let account = try ServerSkillDirectory(path: home)
        _ = try account.directory(".claude/skills", create: true)
        _ = try account.directory(".agents/skills", create: true)
        return ["BLOOM_SKILL_BUNDLES_DIRECTORY": directory + "/bundles",
                "BLOOM_CLAUDE_SKILLS_DIRECTORY": home + "/.claude/skills",
                "BLOOM_CODEX_SKILLS_DIRECTORY": home + "/.agents/skills"]
    }

    static func agentPath(_ agent: ServerSkillAgent) -> String {
        switch agent {
        case .claude: ".claude/skills"
        case .codex: ".agents/skills"
        }
    }

    static func summary(_ text: String) -> String {
        let lines = text.split(separator: "\n")
        if let line = lines.first(where: { $0.hasPrefix("description:") }) {
            return String(line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces).prefix(500))
        }
        return String(lines.first(where: { !$0.hasPrefix("---") && !$0.hasPrefix("name:") }).map(String.init)?.prefix(500) ?? "")
    }
}
