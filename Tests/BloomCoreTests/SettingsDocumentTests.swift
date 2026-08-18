import Testing
import Foundation
@testable import BloomCore

/// The settings screen edits files a person wrote, so what it must never do is hand one back
/// reordered, stripped of its comments, or missing a key this app has never heard of.
@Suite("Settings document")
struct SettingsDocumentTests {
    @Test("replacing a value leaves comments, order and unknown keys alone")
    func surgicalReplacement() {
        var document = SettingsDocument(text: """
        "$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

        # Why this exists at all.
        [scripts]
        setup = "pnpm install"
        run_mode = "concurrent"
        something_bloom_has_never_heard_of = 42
        """)

        document.set(.string("bun install"), at: ["scripts", "setup"])

        #expect(document.text == """
        "$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

        # Why this exists at all.
        [scripts]
        setup = "bun install"
        run_mode = "concurrent"
        something_bloom_has_never_heard_of = 42
        """)
    }

    @Test("a multi-line script is replaced whole, not just its first line")
    func multiLineValueIsReplacedEntirely() {
        var document = SettingsDocument(text: """
        [scripts]
        setup = '''
        set -e
        composer install
        '''
        run_mode = "concurrent"
        """)

        document.set(.string("echo hi"), at: ["scripts", "setup"])

        #expect(document.text == """
        [scripts]
        setup = "echo hi"
        run_mode = "concurrent"
        """)
    }

    @Test("a script with newlines is written as a literal block and reads back unchanged")
    func multiLineRoundTrip() throws {
        let script = "set -e\nsed -i '' \"s|^APP_URL=.*|APP_URL=https://x.test|\" .env\ncomposer install"
        var document = SettingsDocument(text: "")
        document.set(.string(script), at: ["scripts", "setup"])

        // TOML's multi-line forms keep the newline before the closing delimiter, so the value
        // comes back one newline longer. That is the format's rule rather than a defect here, and
        // `SettingsWriter` trims a script on the way in so the difference cannot accumulate.
        let parsed = try TOML.parse(document.text)
        #expect(parsed["scripts.setup"]?.stringValue == script + "\n")
    }

    @Test("a script containing the literal delimiter falls back to the escaped form")
    func awkwardScriptStillRoundTrips() throws {
        let script = "echo '''\nawk '{print $1}' file"
        var document = SettingsDocument(text: "")
        document.set(.string(script), at: ["scripts", "setup"])

        let parsed = try TOML.parse(document.text)
        #expect(parsed["scripts.setup"]?.stringValue == script + "\n")
    }

    @Test("a key written as a dotted key at the root is edited where it is, not moved")
    func dottedKeyStaysPut() {
        var document = SettingsDocument(text: """
        scripts.setup = "old"
        """)

        document.set(.string("new"), at: ["scripts", "setup"])

        #expect(document.text == """
        scripts.setup = "new"
        """)
    }

    @Test("a missing table is created at the end rather than in the middle of another")
    func missingTableIsAppended() {
        var document = SettingsDocument(text: """
        [scripts]
        setup = "x"
        """)

        document.set(.boolean(true), at: ["git", "delete_branch_on_archive"])

        #expect(document.text == """
        [scripts]
        setup = "x"

        [git]
        delete_branch_on_archive = true
        """)
    }

    @Test("a root key lands in the preamble, above the first table")
    func rootKeyGoesInThePreamble() {
        var document = SettingsDocument(text: """
        "$schema" = "x"

        [scripts]
        setup = "y"
        """)

        document.set(.strings([".env*", "certs/*.pem"]), at: ["file_include_globs"])

        #expect(document.text == """
        "$schema" = "x"
        file_include_globs = [".env*", "certs/*.pem"]

        [scripts]
        setup = "y"
        """)
    }

    @Test("an array spread over several lines is replaced whole")
    func multiLineArrayIsReplacedEntirely() {
        var document = SettingsDocument(text: """
        file_include_globs = [
          ".env",
          ".env.local",
        ]

        [scripts]
        setup = "x"
        """)

        document.set(.strings([".env*"]), at: ["file_include_globs"])

        #expect(document.text == """
        file_include_globs = [".env*"]

        [scripts]
        setup = "x"
        """)
    }

    @Test("removing a key takes its whole value and nothing else")
    func removalTakesTheWholeValue() {
        var document = SettingsDocument(text: """
        [scripts]
        setup = '''
        one
        two
        '''
        archive = "bye"
        """)

        document.remove(at: ["scripts", "setup"])

        #expect(document.text == """
        [scripts]
        archive = "bye"
        """)
    }

    @Test("removing a key that is not there changes nothing")
    func removingAnAbsentKeyIsANoOp() {
        let source = """
        [scripts]
        archive = "bye"
        """
        var document = SettingsDocument(text: source)
        document.remove(at: ["scripts", "setup"])
        #expect(document.text == source)
    }

    @Test("tables under a path are found, and removing one takes its rows with it")
    func tablesUnderAPath() {
        var document = SettingsDocument(text: """
        [scripts.run.dev]
        command = "bun dev"

        [scripts.run.test]
        command = "bun test"

        [git]
        branch_prefix = "freek"
        """)

        #expect(document.tables(under: ["scripts", "run"]) == [
            ["scripts", "run", "dev"],
            ["scripts", "run", "test"],
        ])

        document.removeTable(at: ["scripts", "run", "dev"])

        #expect(document.text == """
        [scripts.run.test]
        command = "bun test"

        [git]
        branch_prefix = "freek"
        """)
    }

    @Test("a trailing newline is kept, and a file without one does not grow one")
    func trailingNewlineIsPreserved() {
        var withNewline = SettingsDocument(text: "[scripts]\nsetup = \"a\"\n")
        withNewline.set(.string("b"), at: ["scripts", "setup"])
        #expect(withNewline.text == "[scripts]\nsetup = \"b\"\n")

        var without = SettingsDocument(text: "[scripts]\nsetup = \"a\"")
        without.set(.string("b"), at: ["scripts", "setup"])
        #expect(without.text == "[scripts]\nsetup = \"b\"")
    }

    @Test("a file that never existed and still says nothing stays absent")
    func absentAndEmptyStaysAbsent() {
        let document = SettingsDocument(contentsOf: "/nowhere/at/all/settings.toml")
        #expect(document.exists == false)
        #expect(document.isEmpty)
    }
}
