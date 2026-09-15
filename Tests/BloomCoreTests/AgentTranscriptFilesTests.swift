import Foundation
import Testing
@testable import BloomCore

/// A permanent delete takes the agent CLIs' own transcripts for a worktree, and only those.
///
/// The directory names below were read off `~/.claude/projects` on the owner's Mac rather than
/// reasoned out, and every negative case is a file that sits next to a matching one and must stay.
@Suite("Agent CLI transcripts for a worktree", .scratchDirectory, .tags(.persistence))
struct AgentTranscriptFilesTests {
    private let worktree = "/srv/bloom/workspaces/project/amundsen-sea"

    @Test("names a project directory the way Claude Code does")
    func claudeDirectoryName() {
        #expect(AgentTranscriptFiles.claudeProjectDirectoryName(forWorktree: "/Users/freek/bloom/workspaces/bloom/freekmurze-amundsen-sea")
            == "-Users-freek-bloom-workspaces-bloom-freekmurze-amundsen-sea")
        #expect(AgentTranscriptFiles.claudeProjectDirectoryName(forWorktree: "/private/tmp/claude-501/-Users-freek")
            == "-private-tmp-claude-501--Users-freek")
        #expect(AgentTranscriptFiles.claudeProjectDirectoryName(forWorktree: "/a/b.c_d e") == "-a-b-c-d-e")
        #expect(AgentTranscriptFiles.claudeProjectDirectoryName(forWorktree: "/" + String(repeating: "a", count: 240)) == nil)
    }

    @Test("takes this worktree's sessions and leaves a neighbour that shares the directory name")
    func claudeSessions() throws {
        let home = TestScratch.unique("home")
        let directory = try claudeDirectory(home: home)
        try line(["cwd": worktree, "sessionId": "one"], to: directory + "/one.jsonl")
        try FileManager.default.createDirectory(atPath: directory + "/one/subagents", withIntermediateDirectories: true)
        try line(["type": "queue-operation", "sessionId": "two"], to: directory + "/two.jsonl")
        try line(["cwd": worktree + "/app"], to: directory + "/three.jsonl")
        try line(["cwd": "/srv/bloom/workspaces/project.amundsen-sea"], to: directory + "/neighbour.jsonl")
        try line(["type": "queue-operation"], to: directory + "/unknown.jsonl")

        let plan = AgentTranscriptFiles.find(worktree: worktree, threads: [AgentThread(kind: .claudeCode, agentSessionID: "two")], keeping: [], home: home)

        #expect(plan.paths == ["one", "one.jsonl", "three.jsonl", "two.jsonl"].map { directory + "/" + $0 })
        #expect(plan.claudeSessions == 3)
        #expect(plan.remove().isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory + "/neighbour.jsonl"))
        #expect(!FileManager.default.fileExists(atPath: directory + "/one"))
    }

    @Test("takes the whole directory once nothing else is in it")
    func wholeDirectory() throws {
        let home = TestScratch.unique("home")
        let directory = try claudeDirectory(home: home)
        try line(["cwd": worktree], to: directory + "/one.jsonl")
        let plan = AgentTranscriptFiles.find(worktree: worktree, threads: [], keeping: [], home: home)
        #expect(plan.paths == [directory])
        #expect(plan.loss?.hasPrefix("1 Claude Code session kept by the agent CLIs, holding") == true)
    }

    @Test("leaves a session another workspace carried on")
    func carriedOnSessionStays() throws {
        let home = TestScratch.unique("home")
        let directory = try claudeDirectory(home: home)
        try line(["cwd": worktree], to: directory + "/resumed.jsonl")
        let plan = AgentTranscriptFiles.find(worktree: worktree, threads: [AgentThread(kind: .claudeCode, agentSessionID: "resumed")],
                                             keeping: ["resumed"], home: home)
        #expect(plan.isEmpty)
    }

    @Test("does not follow a symbolic link planted as the project directory")
    func symlinkIgnored() throws {
        let home = TestScratch.unique("home")
        let elsewhere = TestScratch.unique("elsewhere")
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try line(["cwd": worktree], to: elsewhere + "/one.jsonl")
        let projects = home + "/.claude/projects"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        let name = try #require(AgentTranscriptFiles.claudeProjectDirectoryName(forWorktree: worktree))
        try FileManager.default.createSymbolicLink(atPath: projects + "/" + name, withDestinationPath: elsewhere)
        #expect(AgentTranscriptFiles.find(worktree: worktree, threads: [], keeping: [], home: home).isEmpty)
    }

    @Test("takes a Codex rollout only when its own first line names the thread and the worktree")
    func codexRollouts() throws {
        let home = TestScratch.unique("home")
        let day = home + "/.codex/sessions/2026/09/01"
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        let thread = "01a05e74-3273-7440-8ccd-5889a67f7b29"
        let other = "01a05e74-3273-7440-8ccd-000000000000"
        let ours = day + "/rollout-2026-09-01T21-31-08-\(thread).jsonl"
        try line(["type": "session_meta", "payload": ["id": thread, "cwd": worktree]], to: ours)
        try line(["type": "session_meta", "payload": ["id": other, "cwd": "/elsewhere"]], to: day + "/rollout-2026-09-01T21-40-00-\(other).jsonl")
        try line(["type": "session_meta", "payload": ["id": thread, "cwd": "/elsewhere"]], to: day + "/rollout-2026-09-02T00-00-00-copy-\(thread).jsonl.bak")

        let plan = AgentTranscriptFiles.find(worktree: worktree,
                                             threads: [AgentThread(kind: .codex, agentSessionID: thread), AgentThread(kind: .codex, agentSessionID: other), AgentThread(kind: .codex, agentSessionID: "../../x")],
                                             keeping: [], home: home)
        #expect(plan.paths == [ours])
        #expect(plan.codexSessions == 1)
    }

    private func claudeDirectory(home: String) throws -> String {
        let name = try #require(AgentTranscriptFiles.claudeProjectDirectoryName(forWorktree: worktree))
        let directory = home + "/.claude/projects/" + name
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func line(_ object: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try (String(decoding: data, as: UTF8.self) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
