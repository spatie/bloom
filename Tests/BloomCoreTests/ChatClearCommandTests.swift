import Testing
@testable import BloomCore

@Suite struct ChatClearCommandTests {
    @Test func acceptsTheTypedCommandAndCompletedChip() {
        #expect(ChatClearCommand.matches("/clear"))
        #expect(ChatClearCommand.matches("/clear "))
        #expect(ChatClearCommand.matches(" \n/clear\n"))
        #expect(SlashCommandIndex.builtIns.contains { $0.name == "clear" })
    }

    @Test func neverClearsForOrdinaryProseOrArguments() {
        for text in ["", "/clearance", "/clear everything", "Please add /clear", "`/clear`", "/CLEAR"] {
            #expect(!ChatClearCommand.matches(text))
        }
    }
}
