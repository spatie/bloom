import Testing
import Foundation
@testable import BatonCore

@Suite("TOML", .scratchDirectory)
struct TOMLTests {
    @Test("parses the shape of a real conductor settings file")
    func parsesConductorSettings() throws {
        let source = """
        "$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

        [scripts]
        setup = '''
        set -e
        cp "$ROOT/.env" .env
        composer install
        '''
        run = "npm run dev"
        run_mode = "nonconcurrent"
        """

        let toml = try TOML.parse(source)
        #expect(toml["$schema"]?.stringValue?.hasPrefix("https://") == true)
        #expect(toml["scripts.run"]?.stringValue == "npm run dev")
        #expect(toml["scripts.run_mode"]?.stringValue == "nonconcurrent")

        let setup = try #require(toml["scripts.setup"]?.stringValue)
        #expect(setup.hasPrefix("set -e"))
        #expect(setup.contains("composer install"))
        // The newline right after ''' is trimmed, the rest is literal.
        #expect(setup.hasPrefix("\n") == false)
    }

    @Test("does not interpret escapes inside literal strings")
    func literalStringsAreLiteral() throws {
        let toml = try TOML.parse(#"""
        a = 'C:\not\an\escape'
        b = '''sed -i '' "s|^APP_URL=.*|x|"'''
        """#)
        #expect(toml["a"]?.stringValue == #"C:\not\an\escape"#)
        #expect(toml["b"]?.stringValue?.contains("sed -i") == true)
    }

    @Test("interprets escapes inside basic strings")
    func basicStringsEscape() throws {
        let toml = try TOML.parse(#"a = "line\nnext\ttab \u0041""#)
        #expect(toml["a"]?.stringValue == "line\nnext\ttab A")
    }

    @Test("parses nested tables and dotted keys")
    func parsesNesting() throws {
        let toml = try TOML.parse("""
        [models]
        default = "opus-5-1m"

        [models.codex]
        default_thinking_level = "high"

        [git]
        delete_branch_on_archive = false
        branch_prefix_type = "github_username"
        depth = 12
        """)
        #expect(toml["models.default"]?.stringValue == "opus-5-1m")
        #expect(toml["models.codex.default_thinking_level"]?.stringValue == "high")
        #expect(toml["git.delete_branch_on_archive"]?.boolValue == false)
        #expect(toml["git.depth"]?.intValue == 12)
    }

    @Test("parses arrays, inline tables and comments")
    func parsesCollections() throws {
        let toml = try TOML.parse("""
        # a leading comment
        files = ["*.env", ".env.local"]   # trailing comment
        point = { x = 1, y = 2 }
        empty = []
        """)
        #expect(toml["files"]?.stringArray == ["*.env", ".env.local"])
        #expect(toml["point.x"]?.intValue == 1)
        #expect(toml["point.y"]?.intValue == 2)
        #expect(toml["empty"]?.arrayValue?.isEmpty == true)
    }

    @Test("parses arrays of tables")
    func parsesArraysOfTables() throws {
        let toml = try TOML.parse("""
        [[ports]]
        name = "web"
        port = 3000

        [[ports]]
        name = "api"
        port = 3001
        """)
        let ports = try #require(toml["ports"]?.arrayValue)
        #expect(ports.count == 2)
        #expect(ports[0]["name"]?.stringValue == "web")
        #expect(ports[1]["port"]?.intValue == 3001)
    }

    @Test("keeps sibling keys when a table header is revisited")
    func mergesTables() throws {
        let toml = try TOML.parse("""
        [scripts]
        setup = "a"

        [scripts.run]
        dev = "b"
        """)
        #expect(toml["scripts.setup"]?.stringValue == "a")
        #expect(toml["scripts.run.dev"]?.stringValue == "b")
    }

    @Test("reads a file from disk, including one that is not there")
    func parsesFromDisk() throws {
        let path = TestScratch.unique("settings") + ".toml"
        try """
        [scripts]
        setup = "composer install"
        """.write(toFile: path, atomically: true, encoding: .utf8)

        let value = try #require(try TOML.parse(contentsOf: path))
        #expect(value["scripts.setup"]?.stringValue == "composer install")
        // A repository with no settings file is the normal case, not an error.
        #expect(try TOML.parse(contentsOf: TestScratch.unique("absent") + ".toml") == nil)
    }
}

/// Parses the `.conductor/settings.toml` files that actually exist on this machine.
///
/// Everything above is hermetic. This is not: what it reads depends on which repositories the
/// developer has checked out, so it cannot pass or fail the same way twice and is opt in.
///
///     BATON_LOCAL_SETTINGS=1 ./test-core.sh TOMLOnDisk
///
/// It earns its place because real settings files contain shapes nobody would think to write a
/// fixture for, which is how several of the parser bugs above were found in the first place.
private let localSettingsEnabled = ProcessInfo.processInfo.environment["BATON_LOCAL_SETTINGS"] == "1"

@Suite("TOMLOnDisk", .enabled(if: localSettingsEnabled))
struct TOMLOnDiskTests {
    @Test("reads every settings file already on this machine")
    func parsesRealFilesOnDisk() throws {
        let root = NSHomeDirectory() + "/dev/code"
        let candidates = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
            .map { "\(root)/\($0)/.conductor/settings.toml" }
            .filter { FileManager.default.fileExists(atPath: $0) }

        // A silent zero would make this test a no-op that looks like coverage. It used to print
        // the count and assert nothing.
        try #require(candidates.isEmpty == false, "no settings files under \(root) to read")

        for path in candidates {
            do {
                #expect(try TOML.parse(contentsOf: path) != nil, "\(path) parsed to nothing")
            } catch {
                Issue.record(error, "failed to parse \(path)")
            }
        }
    }
}
