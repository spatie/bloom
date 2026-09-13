import Foundation
import Testing
@testable import BloomCore

@Suite("Theme presets")
struct ThemePresetTests {
    @Test func migrationPreservesLegacySettings() throws {
        let name = "bloom-theme-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("regular", forKey: "sidebarGlassOverride")
        defaults.set("Charter", forKey: ChatFontCatalogue.defaultsKey)
        defaults.set("largest", forKey: ChatTextSize.defaultsKey)
        defaults.set("looser", forKey: ChatLineHeight.defaultsKey)
        defaults.set(18, forKey: "terminal.fontSize")
        let migrated = ThemeOverrides.migrating(from: defaults)
        let typography = TypographyOverrides.migrating(from: defaults)
        #expect(migrated.glass == .regular)
        #expect(typography.chatFont == "Charter")
        #expect(typography.chatTextSize == .largest)
        #expect(typography.chatLineHeight == .looser)
        #expect(typography.terminalTypography.fontSize == 18)
        #expect(migrated.terminalSource == .ghostty)
        defaults.set(false, forKey: "useGhosttyTerminalTheme")
        defaults.set(0, forKey: "terminal.fontSize")
        #expect(ThemeOverrides.migrating(from: defaults).terminalSource == nil)
        #expect(TypographyOverrides.migrating(from: defaults).terminalTypography.fontSize == nil)
        #expect(defaults.string(forKey: ChatFontCatalogue.defaultsKey) == "Charter")
    }

    @Test func independentSchemesAndFallbacks() {
        var changes = ThemeOverrides()
        changes.codeScheme = "bloom"
        changes.terminalSource = .builtin("charcoal")
        #expect(changes.codeScheme(for: .charcoalGlass) == .bloom)
        #expect(changes.terminalScheme(for: .bloom) == .charcoal)
        changes.codeScheme = "missing"
        changes.terminalSource = .builtin("missing")
        #expect(changes.codeScheme(for: .charcoalGlass) == .charcoal)
        #expect(changes.terminalScheme(for: .charcoalGlass) == .charcoal)
    }

    @Test func syntaxCacheIncludesPaletteAndExactBytes() {
        let first = SyntaxCacheKey(line: "café", language: .swift, carry: LexState(), scheme: .bloom)
        let otherScheme = SyntaxCacheKey(line: "café", language: .swift, carry: LexState(), scheme: .charcoal)
        let otherBytes = SyntaxCacheKey(line: "cafe\u{301}", language: .swift, carry: LexState(), scheme: .bloom)
        var edited = CodeScheme.bloom
        edited.tokens[.comment] = .init(light: 0, dark: 0xFFFFFF)
        let editedScheme = SyntaxCacheKey(line: "café", language: .swift, carry: LexState(), scheme: edited)
        #expect(!first.isEqual(otherScheme))
        #expect(!first.isEqual(otherBytes))
        #expect(!first.isEqual(editedScheme))
    }

    @Test func typographyResolvesPerField() {
        let defaults = ThemeTypography(fontFamily: "Menlo", fontSize: 13, lineHeight: 1.2)
        let changed = ThemeTypography(fontSize: 18).inheriting(defaults)
        #expect(changed.fontFamily == "Menlo")
        #expect(changed.fontSize == 18)
        #expect(changed.lineHeight == 1.2)
        #expect(ThemeTypography(fontSize: 900, lineHeight: 0.1).inheriting(defaults).fontSize == 28)
        #expect(ThemeTypography(fontSize: 900, lineHeight: 0.1).inheriting(defaults).lineHeight == 1)
    }

    @Test func archiveKeepsThemesSeparate() throws {
        var charcoal = ThemeOverrides()
        charcoal.glass = .regular
        charcoal.codeScheme = "bloom"
        var typography = TypographyOverrides()
        typography.chatTextSize = .large
        let original = ThemeOverrides.Archive(themes: ["neutral": charcoal], typography: typography)
        let restored = try ThemeOverrides.Archive.decode(JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.themes["bloom"] == nil)
        var future = original
        future.schemaVersion = 999
        let data = try JSONEncoder().encode(future)
        #expect(throws: DecodingError.self) { try ThemeOverrides.Archive.decode(data) }
    }

    @Test(arguments: CodeScheme.all)
    func codeSchemeRoundTripAndContrast(_ scheme: CodeScheme) throws {
        let data = try JSONEncoder().encode(scheme)
        #expect(try JSONDecoder().decode(CodeScheme.self, from: data) == scheme)
        for dark in [false, true] {
            let ground = scheme.background.member(dark: dark)
            for kind in TokenKind.allCases {
                #expect(Contrast.ratio(scheme.colour(for: kind).member(dark: dark), ground) >= Contrast.textFloor)
            }
        }
    }

    @Test(arguments: TerminalScheme.all)
    func terminalSchemesAreComplete(_ scheme: TerminalScheme) throws {
        let data = try JSONEncoder().encode(scheme)
        #expect(try JSONDecoder().decode(TerminalScheme.self, from: data) == scheme)
        for palette in [scheme.light, scheme.dark] {
            #expect(palette.palette.count == 16)
            #expect(palette.background != nil && palette.foreground != nil)
            #expect(palette.cursorColor != nil && palette.cursorTextColor != nil)
            #expect(palette.selectionBackground != nil && palette.selectionForeground != nil)
        }
    }
}

@Suite("Theme preference state")
@MainActor
struct ThemePreferenceStateTests {
    @Test func switchingResetAndPersistence() throws {
        let domain = "bloom-theme-state-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("neutral", forKey: ColourTheme.defaultsKey)
        let state = ColourThemePreference(defaults: defaults)
        state.overrides.codeScheme = "bloom"
        state.overrides.terminalSource = .builtin("charcoal")
        state.glassOverride = .regular
        state.chatTextSize = .largest
        state.typographyOverrides.codeTypography.fontSize = 20
        state.choice = .bloom
        #expect(state.glass == ColourTheme.bloom.glass && state.codeScheme == .bloom)
        // Typography follows the person across presets rather than resetting with the colours.
        #expect(state.chatTextSize == .largest && state.codeTypography.fontSize == 20)
        state.choice = .charcoalGlass
        #expect(state.glass == .regular && state.chatTextSize == .largest)
        #expect(state.codeScheme == .bloom && state.terminalScheme == .charcoal)
        let reloaded = ColourThemePreference(defaults: defaults)
        #expect(reloaded.overrides == state.overrides)
        #expect(reloaded.typographyOverrides == state.typographyOverrides)
        reloaded.typographyOverrides.codeTypography.fontSize = nil
        #expect(reloaded.codeTypography.fontSize == 13)
        #expect(reloaded.codeScheme == .bloom && reloaded.glass == .regular)
        reloaded.restoreDefaults()
        let reset = ColourThemePreference(defaults: defaults)
        #expect(reset.glass == .thick && reset.codeScheme == .charcoal)
        #expect(!reset.followsGhostty)
        // Restoring a preset's defaults is about its look, so the reading size survives it.
        #expect(reset.chatTextSize == .largest)
    }

    @Test func legacyDefaultsRemainInherited() throws {
        let domain = "bloom-theme-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(ChatTextSize.defaultChoice.rawValue, forKey: ChatTextSize.defaultsKey)
        defaults.set(ChatLineHeight.defaultChoice.rawValue, forKey: ChatLineHeight.defaultsKey)
        let migrated = TypographyOverrides.migrating(from: defaults)
        #expect(migrated.chatTextSize == nil && migrated.chatLineHeight == nil)
    }

    @Test func unreadableArchivePreservesLegacyChoices() throws {
        let domain = "bloom-theme-recovery-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let corrupt = Data("unreadable".utf8)
        defaults.set(corrupt, forKey: "themeOverrides")
        defaults.set("largest", forKey: ChatTextSize.defaultsKey)
        let state = ColourThemePreference(defaults: defaults)
        #expect(state.chatTextSize == .largest)
        #expect(defaults.data(forKey: "themeOverrides") == corrupt)
        #expect(defaults.data(forKey: "themeOverrides.unreadableBackup") == corrupt)
        state.glassOverride = .off
        #expect(ColourThemePreference(defaults: defaults).chatTextSize == .largest)
    }

    @Test func archiveWrittenPerPresetMigratesTypographyFromLegacySettings() throws {
        let domain = "bloom-theme-typography-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        // The shape an earlier build of this branch wrote: typography inside each preset, and no
        // top level typography at all.
        let older = Data(#"{"schemaVersion":1,"themes":{"bloom":{"glass":"thin","chatTextSize":"small"}}}"#.utf8)
        defaults.set(older, forKey: "themeOverrides")
        defaults.set("large", forKey: ChatTextSize.defaultsKey)
        let state = ColourThemePreference(defaults: defaults)
        #expect(state.glass == .thin)
        #expect(state.chatTextSize == .large)
        #expect(defaults.data(forKey: "themeOverrides.unreadableBackup") == nil)
    }

    @Test func ghosttyColourDefaultsStayTogether() {
        var partial = GhosttyTheme()
        partial.foreground = GhosttyColor(red: 0xAA, green: 0xBB, blue: 0xCC)
        let resolved = partial.resolvingColourDefaults()
        #expect(resolved.background == GhosttyColor(red: 0x28, green: 0x2C, blue: 0x34))
        #expect(resolved.cursorColor == partial.foreground)
        #expect(resolved.cursorTextColor == resolved.background)
        #expect(resolved.selectionBackground == partial.foreground)
        #expect(resolved.selectionForeground == resolved.background)
        #expect(resolved.palette.count == 16)
    }
}
