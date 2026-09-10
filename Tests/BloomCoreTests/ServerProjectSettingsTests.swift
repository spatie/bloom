import Foundation
import Testing
@testable import BloomCore

@Suite("Remote project settings", .scratchDirectory, .tags(.git, .persistence))
struct ServerProjectSettingsTests {
    @Test func readsAndSavesProjectFilesThroughTheProtocol() async throws {
        let directory = try await TempRepo()
        try directory.write(".bloom/settings.toml", "# Keep this comment\n[scripts.run.web]\nname = \"Web\"\ncommand = \"php artisan serve\"\n")
        try directory.write(".bloom/merge-instructions.md", "Use the project merge instructions.")
        try directory.write(".env.preview", "EXAMPLE=1\n")
        let store = try makeTestStore("remote-project-settings")
        let repo = try await store.upsert(Repo(name: "Remote project", path: directory.path))
        let runtime = ServerRuntime(store: store, authentication: { agent, _, _ in .init(agent: agent, state: .unknown) })
        let request = ServerRequest(.project(repoID: repo.id, action: .settings))
        #expect(!request.operation.mutates)
        let response = await runtime.respond(to: request)
        guard case .projectSettings(let snapshot) = response.result else { Issue.record("Missing settings"); return }
        #expect(snapshot.settings.runScripts.first?.command == "php artisan serve")
        #expect(!snapshot.instructionFiles.isEmpty)
        #expect(snapshot.settings.sources.contains(directory.path + "/.bloom/settings.toml"))
        let decoded = try JSONDecoder().decode(ServerReply.self, from: JSONEncoder().encode(response))
        guard case .projectSettings(let roundTrip) = decoded.result else { Issue.record("Settings did not survive the wire"); return }
        #expect(roundTrip.settings == snapshot.settings)

        let edit = ServerRequest(.project(repoID: repo.id, action: .saveSettings(
            edits: [.branchPrefix("preview/"), .setupScript("#!/bin/bash\necho ready"), .runScripts([.init(id: "web", name: "Laravel", command: "php artisan serve --port=\"$BLOOM_PORT\"")])],
            expected: roundTrip.settings)))
        let encoded = try JSONEncoder().encode(edit)
        let saved = await runtime.respond(to: try JSONDecoder().decode(ServerRequest.self, from: encoded))
        guard case .projectSettings(let updated) = saved.result else { Issue.record("Save failed: \(saved.result)"); return }
        #expect(updated.settings.branchPrefix == "preview/")
        #expect(updated.settings.runScripts.first?.name == "Laravel")
        #expect(updated.settings.setupScript?.contains("echo ready") == true)
        #expect(!updated.savedPaths.isEmpty)
        #expect(try String(contentsOfFile: directory.path + "/.bloom/settings.toml", encoding: .utf8).contains("# Keep this comment"))
        let retry = await runtime.respond(to: edit)
        guard case .projectSettings = retry.result else { Issue.record("A repeated save lost its result"); return }
        let preview = await runtime.respond(to: ServerRequest(.project(repoID: repo.id, action: .filesToCopy(patterns: [".env*", "../*"]))))
        guard case .filesToCopy(let plan) = preview.result else { Issue.record("Missing copy preview"); return }
        #expect(plan.matches.map(\.path) == [".env.preview"])
        #expect(plan.unmatchedPatterns.contains("../*"))
        await runtime.shutdown()
    }

    @Test func rejectsStaleSettingsAndUnknownProjects() async throws {
        let directory = try await TempRepo()
        try directory.write(".bloom/settings.toml", "[git]\nbranch_prefix = \"first/\"\n")
        let store = try makeTestStore("remote-project-conflict")
        let repo = try await store.upsert(Repo(name: "Remote project", path: directory.path))
        let runtime = ServerRuntime(store: store, authentication: { agent, _, _ in .init(agent: agent, state: .unknown) })
        let baseline = SettingsLoader.load(repo: directory.path)
        try directory.write(".bloom/settings.toml", "[git]\nbranch_prefix = \"external/\"\n")
        let response = await runtime.respond(to: ServerRequest(.project(repoID: repo.id,
            action: .saveSettings(edits: [.branchPrefix("client/")], expected: baseline))))
        guard case .failure(let message) = response.result else { Issue.record("Overwrote an external edit"); return }
        #expect(message.contains("changed on the server"))
        #expect(SettingsLoader.load(repo: directory.path).branchPrefix == "external/")
        let missing = await runtime.respond(to: ServerRequest(.project(repoID: RepoID(UUID().uuidString), action: .settings)))
        guard case .failure = missing.result else { Issue.record("Unknown project was accepted"); return }
        let colour = await runtime.respond(to: ServerRequest(.project(repoID: repo.id, action: .setAccent("AABBCC"))))
        guard case .accepted = colour.result else { Issue.record("Colour update failed"); return }
        #expect(try await store.repo(id: repo.id)?.accent == "AABBCC")
        let invalid = await runtime.respond(to: ServerRequest(.project(repoID: repo.id, action: .setAccent("bad"))))
        guard case .failure = invalid.result else { Issue.record("Invalid colour was accepted"); return }
        await runtime.shutdown()
    }
}
