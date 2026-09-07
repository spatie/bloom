import Testing
@testable import BloomCore

@Suite("Terminal editing shortcut precedence")
struct TerminalEditingShortcutTests {
    @Test("Command-Backspace sends a line kill to ordinary shells", arguments: ["\u{7f}", "\u{8}"])
    func deletesShellInput(key: String) {
        #expect(TerminalEditingShortcut.input(
            key: key, isPlainCommand: true, usesEnhancedKeyboard: false
        ) == .text("\u{15}"))
    }

    @Test("Enhanced terminal applications keep the original Command-Backspace event")
    func preservesEnhancedKeyboard() {
        #expect(TerminalEditingShortcut.input(
            key: "\u{7f}", isPlainCommand: true, usesEnhancedKeyboard: true
        ) == .keyEvent)
    }

    @Test("Extra modifiers and non-Command editing keys are not claimed", arguments: [false, true])
    func leavesOtherModifiers(enhanced: Bool) {
        #expect(TerminalEditingShortcut.input(
            key: "\u{7f}", isPlainCommand: false, usesEnhancedKeyboard: enhanced
        ) == nil)
    }

    @Test("Other app shortcuts and forward delete keep their existing routing",
          arguments: ["k", "c", "v", "w", "d", "+", "-", "0", "\u{f728}", ""])
    func leavesOtherKeys(key: String) {
        #expect(TerminalEditingShortcut.input(
            key: key, isPlainCommand: true, usesEnhancedKeyboard: false
        ) == nil)
    }
}
