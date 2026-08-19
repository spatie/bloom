import Testing
import Foundation
@testable import BloomCore

/// What a setup, archive or run script is launched with.
///
/// Pinned as a set of names rather than left to be discovered when somebody's script breaks. The
/// names are an interface: repositories commit scripts that bind them, teams share those files,
/// and a rename that looks tidy from inside the app is a shell error inside somebody else's
/// worktree ten minutes after they asked for a workspace.
@Suite("Script environment")
struct ScriptEnvironmentTests {
    private func makeEnvironment(port: Int = 3_100) throws -> [String: String] {
        let repo = Repo(id: "r1", name: "There There", path: "/tmp/there", defaultBranch: "main")
        let workspace = Workspace(
            id: "w1",
            repoID: repo.id,
            name: "Fix the inbox",
            branch: "freek/fix-the-inbox",
            path: "/tmp/there-fix-the-inbox",
            baseBranch: "main"
        )
        let manager = WorkspaceManager(store: try Store.inMemory())
        return manager.environment(for: workspace, repo: repo, port: port)
    }

    @Test("BLOOM_ is the interface, and it is complete")
    func bloomNamesAreTheInterface() throws {
        let env = try makeEnvironment()

        #expect(env["BLOOM_WORKSPACE_NAME"] == "freek-fix-the-inbox")
        #expect(env["BLOOM_WORKSPACE_ID"] == "w1")
        #expect(env["BLOOM_WORKSPACE_PATH"] == "/tmp/there-fix-the-inbox")
        #expect(env["BLOOM_ROOT_PATH"] == "/tmp/there")
        #expect(env["BLOOM_DEFAULT_BRANCH"] == "main")
        #expect(env["BLOOM_PORT"] == "3100")
        #expect(env["BLOOM_IS_LOCAL"] == "1")

        // A slash in the branch would make a script that uses the name as a folder, a database or
        // a Valet site create something nested instead.
        #expect(env["BLOOM_WORKSPACE_NAME"]?.contains("/") == false)
    }

    @Test("CONDUCTOR_ is set to exactly the same values, and nothing else is")
    func theDeprecatedAliasMirrorsIt() throws {
        let env = try makeEnvironment()

        // The reason it is still here: a repository whose committed setup script says
        // `$CONDUCTOR_ROOT_PATH` must not break the day the variable is renamed.
        let bloom = env.filter { $0.key.hasPrefix("BLOOM_") }
        let conductor = env.filter { $0.key.hasPrefix("CONDUCTOR_") }

        #expect(bloom.count == conductor.count)
        // Nothing else at all: the two prefixes are the whole of what a script is handed.
        #expect(bloom.count + conductor.count == env.count)
        for (key, value) in bloom {
            let alias = key.replacingOccurrences(of: "BLOOM_", with: "CONDUCTOR_")
            #expect(conductor[alias] == value, "\(alias) does not mirror \(key)")
        }
    }

    @Test("the two prefixes are named apart, so a reader can tell an alias from an interface")
    func thePrefixesAreDistinguishable() {
        #expect(WorkspaceManager.environmentPrefix == "BLOOM")
        #expect(WorkspaceManager.deprecatedEnvironmentPrefix == "CONDUCTOR")
        #expect(WorkspaceManager.environmentPrefixes == ["BLOOM", "CONDUCTOR"])
    }

    @Test("a workspace with no port yet still gets the variable, set to zero")
    func aPortlessWorkspaceStillBindsThePort() throws {
        // The archive path passes 0 rather than allocating one. A script that reads `$BLOOM_PORT`
        // should see an empty-ish value rather than an unbound variable, which under `set -u` is
        // a hard failure in the middle of tearing a workspace down.
        let env = try makeEnvironment(port: 0)
        #expect(env["BLOOM_PORT"] == "0")
        #expect(env["CONDUCTOR_PORT"] == "0")
    }
}
