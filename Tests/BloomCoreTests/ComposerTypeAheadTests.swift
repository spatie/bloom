import Testing
@testable import BloomCore

@Suite("Composer type-ahead")
struct ComposerTypeAheadTests {
    @Test("printable characters go to the composer", arguments: ["a", "A", "é", "^", "@", "1", "😀"])
    func typed(characters: String) {
        #expect(ComposerTypeAhead.belongsToComposer(characters: characters, modifiers: []))
    }

    @Test("option and shift still type", arguments: [
        MenuShortcut.Modifiers.option, .shift, [MenuShortcut.Modifiers.option, .shift],
    ])
    func optionAndShift(modifiers: MenuShortcut.Modifiers) {
        #expect(ComposerTypeAhead.belongsToComposer(characters: "|", modifiers: modifiers))
    }

    @Test("command V pastes", arguments: ["v", "V"])
    func paste(characters: String) {
        #expect(ComposerTypeAhead.belongsToComposer(characters: characters, modifiers: .command))
    }

    @Test("only command V is a paste")
    func isPaste() {
        #expect(ComposerTypeAhead.isPaste(characters: "v", modifiers: .command))
        #expect(!ComposerTypeAhead.isPaste(characters: "v", modifiers: []))
        #expect(!ComposerTypeAhead.isPaste(characters: "r", modifiers: .command))
        #expect(!ComposerTypeAhead.isPaste(characters: "v", modifiers: [.command, .shift]))
    }

    @Test("other shortcuts keep their meaning", arguments: [
        MenuShortcut.Modifiers.control, [MenuShortcut.Modifiers.command, .shift],
        [MenuShortcut.Modifiers.command, .option],
    ])
    func shortcuts(modifiers: MenuShortcut.Modifiers) {
        #expect(!ComposerTypeAhead.belongsToComposer(characters: "v", modifiers: modifiers))
    }

    @Test("command with any other letter is a shortcut")
    func commandLetter() {
        #expect(!ComposerTypeAhead.belongsToComposer(characters: "a", modifiers: .command))
    }

    @Test("keys that type nothing stay where they are", arguments: [
        " ", "\r", "\t", "\u{1B}", "\u{7F}", "\u{F700}", "\u{F704}", "",
    ])
    func untyped(characters: String) {
        #expect(!ComposerTypeAhead.belongsToComposer(characters: characters, modifiers: []))
    }

    @Test("no characters at all")
    func missing() {
        #expect(!ComposerTypeAhead.belongsToComposer(characters: nil, modifiers: []))
    }
}
