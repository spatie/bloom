import Testing
@testable import BloomCore

/// What a crew call looks like in the transcript.
///
/// The four tools an agent runs a crew with used to fall through to the generic MCP row, which
/// reads "Bloom: agent start" behind a puzzle piece: the transport and the word "extension", where
/// every other row in the transcript names the thing that happened. What happened is that a second
/// agent started writing in this worktree, and that is the one line in a turn a reader must not
/// have to decode.
///
/// Asserted in the core because that is the whole reason `ToolPresentation` stopped carrying a
/// `Color`. None of this is testable in the view that draws it.
@Suite("A crew call, as a reader meets it")
struct CrewPresentationTests {
    private func present(_ tool: String, _ input: [String: JSONValue] = [:]) -> ToolPresentation {
        ToolPresenter.present(
            name: "mcp__\(BridgeRegistration.serverName)__\(tool)", input: .object(input)
        )
    }

    // MARK: - The four rows

    @Test("starting one says so, and says who")
    func startingNamesTheAgent() {
        let row = present(CrewToolName.start, [
            "name": .string("read-the-cascade"),
            "task": .string("Read every file under Sources/BloomCore/Git and report."),
        ])

        #expect(row.label == "Start subagent")
        #expect(row.detail == "read-the-cascade")
    }

    @Test("saying something names the agent it was said to, not what was said")
    func sayingNamesTheTarget() {
        let row = present(CrewToolName.say, [
            "to": .string("tests"),
            "message": .string("The parser moved to Sources/BloomCore/Git/DiffParser.swift."),
        ])

        #expect(row.label == "Say to")
        #expect(row.detail == "tests")
    }

    /// A subagent talks upwards and names nobody, because `agent_say` refuses a `to` from one. The
    /// row is the label alone rather than a name the call never carried.
    @Test("a subagent talking upwards names nobody")
    func sayingUpwardsNamesNobody() {
        let row = present(CrewToolName.say, ["message": .string("I am done with the read.")])

        #expect(row.label == "Say to")
        #expect(row.detail.isEmpty)
    }

    @Test("listing takes no arguments and draws none")
    func listingIsTheLabelAlone() {
        let row = present(CrewToolName.list)

        #expect(row.label == "List subagents")
        #expect(row.detail.isEmpty)
    }

    /// The one argument a listing could ever grow. A count is a number rather than an address, so
    /// it stays in the proportional face the way `TodoWrite`'s count does.
    @Test("a listing that carries a count shows it, as prose")
    func listingShowsACount() {
        let row = present(CrewToolName.list, ["count": .integer(3)])

        #expect(row.detail == "3")
        #expect(!row.detailIsCode)
    }

    @Test("stopping one says so, and says which")
    func stoppingNamesTheAgent() {
        let row = present(CrewToolName.stop, ["name": .string("tests")])

        #expect(row.label == "Stop subagent")
        #expect(row.detail == "tests")
    }

    // MARK: - What the four have in common

    /// The bug this suite was written from. Not one of the four may read as an extension of an app
    /// the reader is already inside, and not one of them may name the socket it travelled over.
    @Test("none of them names the transport or the puzzle piece")
    func noneOfThemNamesTheTransport() {
        for tool in [CrewToolName.start, CrewToolName.say, CrewToolName.list, CrewToolName.stop] {
            let row = present(tool, ["name": .string("tests"), "to": .string("tests")])
            #expect(!row.label.contains("bridge"), "\(tool) named the transport")
            #expect(!row.label.contains("Bloom:"), "\(tool) named the app rather than the act")
            #expect(row.glyph != "puzzlepiece.extension", "\(tool) drew the extension glyph")
        }
    }

    /// A name is an address: it is the exact string `agent_say` and `agent_stop` have to be handed
    /// back, so it is set in the monospace face and a copy puts the whole of it on the pasteboard.
    @Test("an agent's name is code, so it draws in mono")
    func aNameIsALiteral() {
        #expect(present(CrewToolName.start, ["name": .string("tests")]).literal == "tests")
        #expect(present(CrewToolName.say, ["to": .string("tests")]).literal == "tests")
        #expect(present(CrewToolName.stop, ["name": .string("tests")]).literal == "tests")

        for tool in [CrewToolName.start, CrewToolName.say, CrewToolName.stop] {
            #expect(present(tool, ["name": .string("tests"), "to": .string("tests")]).detailIsCode)
        }
    }

    /// An absent name is nothing to draw and nothing to copy, which is the same answer
    /// `ToolLiteral` gives for an argument that is present and empty.
    @Test("a missing name is not an empty literal")
    func aMissingNameIsNoLiteral() {
        for tool in [CrewToolName.start, CrewToolName.say, CrewToolName.list, CrewToolName.stop] {
            let row = present(tool)
            #expect(row.literal == nil, "\(tool) claimed a literal it was never given")
            #expect(!row.detailIsCode)
        }
    }

    /// A model is free to send anything in a name, and the row is one line. `Crew.nameLimit` is
    /// what a name is cut to everywhere else, so it is what the row is cut to here.
    @Test("a name longer than a name is cut to one")
    func aRunawayNameIsCut() {
        let row = present(CrewToolName.start, ["name": .string(String(repeating: "a", count: 400))])

        #expect(row.detail.count <= Crew.nameLimit + 1)
        #expect(row.detail.hasSuffix("\u{2026}"))
    }

    /// Newlines and tabs in a name would take the row off its line, and `Crew.normalisedName`
    /// turns both into spaces before a name is ever stored, so the row that reports the call has
    /// to survive the un-normalised version the tool was actually handed.
    @Test("a name with a newline in it is still one line")
    func aNameStaysOnOneLine() {
        let row = present(CrewToolName.stop, ["name": .string("tests\nand docs")])

        #expect(row.detail == "tests and docs")
    }

    // MARK: - Everything else on the bridge is untouched

    /// The generic row is still the right answer for the rest of Bloom's own tools, and for
    /// somebody else's server.
    @Test("another bridge tool keeps the row it had")
    func anotherBridgeToolIsUnchanged() {
        let row = present("pane_open")

        #expect(row.label == "Bloom: pane open")
        #expect(row.literal == nil)
    }

    /// A tool that reads a file still gets its file chip, which is what the literal on a crew row
    /// must not have cost. See `ToolPresenter.present`.
    @Test("a file naming tool still finds its file")
    func aFileIsStillFound() {
        let row = ToolPresenter.present(
            name: "mcp__linear__attach", input: .object(["path": .string("/tmp/notes.md")])
        )

        #expect(row.literal == "/tmp/notes.md")
        #expect(row.chips == [.file(path: "/tmp/notes.md")])
    }
}
