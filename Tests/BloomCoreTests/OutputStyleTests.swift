import Testing
import Foundation
@testable import BloomCore

/// What the output style picker offers, and where each row came from.
///
/// Every one of these builds a whole `~/.claude` and a whole checkout in the test's own scratch
/// directory and points the index at it, exactly as `SlashCommandTests` does. Nothing here reads
/// the machine it runs on: the four built in styles are compiled into this app, so they can be
/// asserted, and anything on disk belongs to whoever is running the suite.
@Suite("Output styles", .scratchDirectory)
struct OutputStyleTests {
    /// A `~/.claude` and a checkout, written a file at a time.
    struct Tree {
        let home: String
        let project: String

        init() throws {
            home = TestScratch.unique("home")
            project = TestScratch.unique("project")
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        }

        func write(_ relative: String, _ contents: String, under root: String? = nil) throws {
            let path = ((root ?? home) as NSString).appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
        }

        func discover() -> [OutputStyle] {
            OutputStyleIndex.discover(home: home, project: project)
        }

        func names() -> [String] {
            discover().map(\.name)
        }
    }

    // MARK: - The built in list

    /// The four the CLI compiles in, plus the default. They cannot be read off disk, only
    /// asserted, so this is where the reading of the binary is written down.
    @Test("the built in styles are the ones the CLI carries, in its own order")
    func builtIns() {
        #expect(OutputStyle.builtIns.map(\.name) == [
            "default", "Proactive", "Concise", "Explanatory", "Learning",
        ])
        #expect(OutputStyle.builtIns.allSatisfy { $0.isBuiltIn })
        #expect(OutputStyle.builtIns.allSatisfy { !$0.detail.isEmpty })
    }

    /// The descriptions are the CLI's own words, not a paraphrase, because the menu presents them
    /// as what the style does rather than as what Bloom thinks it does.
    @Test("Concise describes itself the way the binary does")
    func conciseDetail() throws {
        let concise = try #require(OutputStyle.builtIns.first { $0.name == "Concise" })

        #expect(
            concise.detail
                == "Claude responds tersely, leading with results and skipping preamble and narration"
        )
    }

    /// Nothing on disk is a working picker, which is the state of almost every machine: neither
    /// `~/.claude/output-styles` nor a project one exists until somebody writes a style.
    @Test("a machine with no style directories at all still gets the built in list")
    func noDirectories() throws {
        let tree = try Tree()

        #expect(tree.names() == OutputStyle.builtIns.map(\.name))
    }

    // MARK: - Custom styles

    @Test("a style in the home directory joins the list")
    func userStyle() throws {
        let tree = try Tree()
        try tree.write(
            ".claude/output-styles/blunt.md",
            "---\nname: Blunt\ndescription: Claude says the thing and stops\n---\n\nBe blunt.\n"
        )

        let found = try #require(tree.discover().first { $0.name == "Blunt" })
        #expect(found.detail == "Claude says the thing and stops")
        #expect(!found.isBuiltIn)
    }

    @Test("a style in the checkout joins the list too")
    func projectStyle() throws {
        let tree = try Tree()
        try tree.write(
            ".claude/output-styles/house.md",
            "---\ndescription: The house voice\n---\n\nWrite like the handbook.\n",
            under: tree.project
        )

        #expect(tree.names().contains("house"))
    }

    /// The CLI names a style by its file and lets frontmatter override, so a file with no
    /// frontmatter at all is still a style rather than nothing.
    @Test("a style with no frontmatter is named by its file")
    func nameFromFile() throws {
        let tree = try Tree()
        try tree.write(".claude/output-styles/terse.md", "Be terse.\n")

        let found = try #require(tree.discover().first { $0.name == "terse" })
        #expect(!found.detail.isEmpty)
    }

    /// A file called `Concise.md` cannot replace the style the CLI compiled in, because the
    /// setting is one string and there is no way to say which of the two is meant. Keeping the
    /// built in row means the menu never describes one style and select another.
    @Test("a custom file cannot shadow a built in name")
    func builtInWins() throws {
        let tree = try Tree()
        try tree.write(
            ".claude/output-styles/Concise.md",
            "---\nname: Concise\ndescription: Something else entirely\n---\n\nNo.\n"
        )

        let concise = tree.discover().filter { $0.name == "Concise" }
        #expect(concise.count == 1)
        #expect(concise.first?.isBuiltIn == true)
    }

    /// The built in five keep the CLI's order at the top and the rest are sorted, so a menu does
    /// not reshuffle itself as files are added.
    @Test("the built in styles stay first and the found ones are sorted after them")
    func ordering() throws {
        let tree = try Tree()
        try tree.write(".claude/output-styles/zulu.md", "Z\n")
        try tree.write(".claude/output-styles/alpha.md", "A\n")

        #expect(tree.names() == [
            "default", "Proactive", "Concise", "Explanatory", "Learning", "alpha", "zulu",
        ])
    }

    /// A name is written into a JSON settings object and then drawn as one line of a menu. A
    /// newline in it would survive encoding as an escape and draw as a broken row.
    @Test("a name that cannot be a menu row is left out", arguments: ["", "   ", "one\ntwo"])
    func rejectsUnusableNames(name: String) {
        #expect(OutputStyleIndex.sanitised(name) == nil)
    }

    /// Looser than a slash command's name on purpose. A style is picked from a menu rather than
    /// typed, so spaces and capitals are the normal case, and the CLI's own four have capitals.
    @Test("a name with spaces and capitals is fine", arguments: ["Concise", "House Voice", "terse"])
    func acceptsOrdinaryNames(name: String) {
        #expect(OutputStyleIndex.sanitised(name) == name)
    }

    // MARK: - The default

    /// Empty and `default` are the same answer, and both mean "send no setting". The two ends of
    /// this, the composer's picker and the runner's argv, both ask this question rather than
    /// comparing strings themselves.
    @Test("nothing chosen and the default chosen are the same thing")
    func defaultIsAbsence() {
        #expect(OutputStyle.isDefault(nil))
        #expect(OutputStyle.isDefault(""))
        #expect(OutputStyle.isDefault("  "))
        #expect(OutputStyle.isDefault("default"))
        #expect(!OutputStyle.isDefault("Concise"))
        // Case matters, because the setting is case sensitive and `Default` is a name somebody
        // could give a style of their own.
        #expect(!OutputStyle.isDefault("Default"))
    }
}
