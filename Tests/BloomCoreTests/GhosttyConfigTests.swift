import Testing
import Foundation
@testable import BloomCore

@Suite("GhosttyConfig", .scratchDirectory)
struct GhosttyConfigTests {
    // MARK: - Syntax

    @Test("a hash is a comment only at the start of a line, never inside a value")
    func hashIsAColourInsideAValue() {
        let entries = GhosttyConfigParser.parse("""
        # this whole line is a comment
        background = #fdf6e3
          # indented comments count as comments too
        foreground = #000000
        """)

        #expect(entries == [
            .init(key: "background", value: "#fdf6e3"),
            .init(key: "foreground", value: "#000000"),
        ])
    }

    @Test(
        "whitespace around the equals is irrelevant",
        arguments: [
            "background=#fdf6e3",
            "background =#fdf6e3",
            "background= #fdf6e3",
            "background   =   #fdf6e3",
            "\tbackground = #fdf6e3\t",
        ]
    )
    func spacingVariants(line: String) {
        let theme = GhosttyConfigResolver.resolve(sources: [line], appearance: .light)
        #expect(theme.background == GhosttyColor(red: 0xFD, green: 0xF6, blue: 0xE3))
    }

    @Test("blank lines and lines without an equals are not values")
    func blankAndBareLines() {
        let theme = GhosttyConfigResolver.resolve(
            sources: ["background = #ffffff\n\n\nbackground"],
            appearance: .light
        )
        // A bare key is Ghostty's other spelling of a reset.
        #expect(theme.background == nil)
    }

    @Test("an empty value resets the key to its default")
    func emptyValueResets() {
        let theme = GhosttyConfigResolver.resolve(
            sources: [
                """
                background = #fdf6e3
                font-family = MesloLGM Nerd Font Mono
                palette = 2=#5ccd86
                """,
                """
                background =
                font-family =
                palette =
                """,
            ],
            appearance: .light
        )

        #expect(theme.background == nil)
        #expect(theme.fontFamily == nil)
        #expect(theme.palette.isEmpty)
        #expect(theme.isEmpty)
    }

    @Test("a repeated font-family declares fallbacks, so the first one is the font")
    func firstFontFamilyWins() {
        let theme = GhosttyConfigResolver.resolve(
            sources: ["font-family = MesloLGM Nerd Font Mono\nfont-family = Menlo"],
            appearance: .light
        )
        #expect(theme.fontFamily == "MesloLGM Nerd Font Mono")

        let afterReset = GhosttyConfigResolver.resolve(
            sources: ["font-family = MesloLGM Nerd Font Mono", "font-family =\nfont-family = Menlo"],
            appearance: .light
        )
        #expect(afterReset.fontFamily == "Menlo")
    }

    // MARK: - Colours

    @Test(
        "hex parses with or without a hash, in three and six digit forms",
        arguments: [
            ("#fdf6e3", GhosttyColor(red: 0xFD, green: 0xF6, blue: 0xE3)),
            ("fdf6e3", GhosttyColor(red: 0xFD, green: 0xF6, blue: 0xE3)),
            ("#FDF6E3", GhosttyColor(red: 0xFD, green: 0xF6, blue: 0xE3)),
            ("#abc", GhosttyColor(red: 0xAA, green: 0xBB, blue: 0xCC)),
            ("abc", GhosttyColor(red: 0xAA, green: 0xBB, blue: 0xCC)),
            ("#000", GhosttyColor(red: 0, green: 0, blue: 0)),
            ("#ffffff", GhosttyColor(red: 255, green: 255, blue: 255)),
        ]
    )
    func hexForms(input: String, expected: GhosttyColor) {
        #expect(GhosttyColor(hex: input) == expected)
    }

    @Test(
        "anything that is not a three or six digit hex is refused",
        arguments: ["", "#", "#12", "#12345", "#1234567", "cornflowerblue", "#gggggg", "# fdf6e3"]
    )
    func refusedHex(input: String) {
        #expect(GhosttyColor(hex: input) == nil)
    }

    @Test("an unparseable colour leaves the previous value in place")
    func unparseableColourIsIgnored() {
        let theme = GhosttyConfigResolver.resolve(
            sources: ["background = #fdf6e3\nbackground = cornflowerblue"],
            appearance: .light
        )
        #expect(theme.background == GhosttyColor(red: 0xFD, green: 0xF6, blue: 0xE3))
    }

    // MARK: - Palette

    @Test("palette entries are parsed per slot")
    func palettePerSlot() {
        let theme = GhosttyConfigResolver.resolve(
            sources: ["palette = 2=#5ccd86\npalette = 15 = eaeaea"],
            appearance: .light
        )

        #expect(theme.palette[2] == GhosttyColor(red: 0x5C, green: 0xCD, blue: 0x86))
        #expect(theme.palette[15] == GhosttyColor(red: 0xEA, green: 0xEA, blue: 0xEA))
        #expect(theme.ansiColors()[2] == GhosttyColor(red: 0x5C, green: 0xCD, blue: 0x86))
        // Untouched slots keep Ghostty's own defaults rather than borrowing Bloom's palette.
        #expect(theme.ansiColors()[1] == GhosttyTheme.defaultPalette[1])
        #expect(theme.ansiColors().count == 16)
    }

    @Test(
        "a slot outside 0...255 or an unparseable entry is dropped, not fatal",
        arguments: ["palette = 256=#5ccd86", "palette = -1=#5ccd86", "palette = 2", "palette = x=#5ccd86", "palette = 2=nope"]
    )
    func palettePoisonIsDropped(line: String) {
        let theme = GhosttyConfigResolver.resolve(
            sources: ["background = #fdf6e3\n\(line)"],
            appearance: .light
        )

        #expect(theme.palette.isEmpty)
        #expect(theme.background == GhosttyColor(red: 0xFD, green: 0xF6, blue: 0xE3))
    }

    @Test("slots above 15 are kept but never reach the sixteen ANSI colours")
    func highSlotsAreHarmless() {
        let theme = GhosttyConfigResolver.resolve(
            sources: ["palette = 200=#5ccd86"],
            appearance: .light
        )

        #expect(theme.palette[200] == GhosttyColor(red: 0x5C, green: 0xCD, blue: 0x86))
        #expect(theme.ansiColors() == GhosttyTheme.defaultPalette)
    }

    // MARK: - Themes

    private static let solarizedLight = """
    palette = 0=#073642
    palette = 2=#859900
    background = #fdf6e3
    foreground = #657b83
    cursor-color = #657b83
    selection-background = #eee8d5
    selection-foreground = #586e75
    """

    private static let solarizedDark = """
    background = #002b36
    foreground = #839496
    """

    @Test("a theme supplies colours the config never mentions")
    func themeSuppliesColours() {
        let theme = GhosttyConfigResolver.resolve(
            sources: ["theme = Solarized Light"],
            appearance: .light
        ) { name in name == "Solarized Light" ? Self.solarizedLight : nil }

        #expect(theme.background == GhosttyColor(red: 0xFD, green: 0xF6, blue: 0xE3))
        #expect(theme.selectionForeground == GhosttyColor(red: 0x58, green: 0x6E, blue: 0x75))
        #expect(theme.palette[0] == GhosttyColor(red: 0x07, green: 0x36, blue: 0x42))
    }

    @Test("a theme that does not exist leaves the explicit values alone")
    func missingThemeIsSurvivable() {
        let theme = GhosttyConfigResolver.resolve(
            sources: ["theme = Nope\nbackground = #fdf6e3"],
            appearance: .light
        )
        #expect(theme.background == GhosttyColor(red: 0xFD, green: 0xF6, blue: 0xE3))
    }

    @Test("explicit keys override the theme, whichever side of it they are written on")
    func explicitBeatsTheme() {
        let theme = GhosttyConfigResolver.resolve(
            sources: [
                """
                background = #ffffff
                theme = Solarized Light
                palette = 2=#5ccd86
                """,
            ],
            appearance: .light
        ) { _ in Self.solarizedLight }

        #expect(theme.background == GhosttyColor(red: 255, green: 255, blue: 255))
        #expect(theme.palette[2] == GhosttyColor(red: 0x5C, green: 0xCD, blue: 0x86))
        // Slots the config left alone still come from the theme.
        #expect(theme.palette[0] == GhosttyColor(red: 0x07, green: 0x36, blue: 0x42))
        #expect(theme.foreground == GhosttyColor(red: 0x65, green: 0x7B, blue: 0x83))
    }

    @Test("the light and dark pair form picks by appearance", arguments: [
        (GhosttyAppearance.light, GhosttyColor(red: 0xFD, green: 0xF6, blue: 0xE3)),
        (GhosttyAppearance.dark, GhosttyColor(red: 0x00, green: 0x2B, blue: 0x36)),
    ])
    func lightDarkPair(appearance: GhosttyAppearance, expected: GhosttyColor) {
        let theme = GhosttyConfigResolver.resolve(
            sources: ["theme = light:Solarized Light,dark:Solarized Dark"],
            appearance: appearance
        ) { name in
            name == "Solarized Light" ? Self.solarizedLight : Self.solarizedDark
        }

        #expect(theme.background == expected)
    }

    @Test("the pair form tolerates reversed order and loose spacing")
    func lightDarkPairOrdering() {
        #expect(
            GhosttyConfigResolver.themeName(" dark: Rose Pine , light: Rose Pine Dawn ", appearance: .light)
                == "Rose Pine Dawn"
        )
        #expect(
            GhosttyConfigResolver.themeName("light:Rose Pine Dawn,dark:Rose Pine", appearance: .dark)
                == "Rose Pine"
        )
    }

    @Test("a plain name is a theme name even when it contains a colon")
    func plainThemeName() {
        #expect(GhosttyConfigResolver.themeName("Solarized Light", appearance: .dark) == "Solarized Light")
        #expect(GhosttyConfigResolver.themeName("/tmp/mine.conf", appearance: .dark) == "/tmp/mine.conf")
        #expect(GhosttyConfigResolver.themeName("light:Only One", appearance: .light) == "light:Only One")
    }

    @Test("a theme file cannot pull in another theme")
    func themesDoNotNest() {
        let theme = GhosttyConfigResolver.resolve(
            sources: ["theme = Outer"],
            appearance: .light
        ) { name in
            name == "Outer" ? "theme = Inner\nbackground = #111111" : "background = #222222"
        }

        #expect(theme.background == GhosttyColor(red: 0x11, green: 0x11, blue: 0x11))
    }

    // MARK: - Merging the two config files

    @Test("the later file wins on a shared key while the earlier one still contributes")
    func mergesBothConfigFiles() {
        let xdg = """
        term = xterm-256color
        cursor-style = block
        palette = 2=#5ccd86
        unfocused-split-opacity = 0.55
        """
        let applicationSupport = """
        font-family = MesloLGM Nerd Font Mono
        font-size = 14
        background = #fdf6e3
        foreground = #000000
        unfocused-split-opacity = 0.4
        """

        let theme = GhosttyConfigResolver.resolve(
            sources: [xdg, applicationSupport],
            appearance: .light
        )

        #expect(theme.background == GhosttyColor(red: 0xFD, green: 0xF6, blue: 0xE3))
        #expect(theme.foreground == GhosttyColor(red: 0, green: 0, blue: 0))
        #expect(theme.fontFamily == "MesloLGM Nerd Font Mono")
        #expect(theme.fontSize == 14)
        #expect(theme.palette[2] == GhosttyColor(red: 0x5C, green: 0xCD, blue: 0x86))
    }

    @Test("Application Support outranks the XDG config file")
    func applicationSupportWins() {
        let theme = GhosttyConfigResolver.resolve(
            sources: ["background = #111111", "background = #fdf6e3"],
            appearance: .light
        )
        #expect(theme.background == GhosttyColor(red: 0xFD, green: 0xF6, blue: 0xE3))
    }

    @Test("the config search order runs from lowest to highest precedence")
    func configPathOrder() {
        let paths = GhosttyConfigLoader.configPaths(home: "/home/x", xdgConfigHome: nil)

        #expect(paths == [
            "/home/x/.config/ghostty/config",
            "/home/x/.config/ghostty/config.ghostty",
            "/home/x/Library/Application Support/com.mitchellh.ghostty/config",
            "/home/x/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ])
    }

    @Test("XDG_CONFIG_HOME moves the first config file")
    func xdgOverride() {
        let paths = GhosttyConfigLoader.configPaths(home: "/home/x", xdgConfigHome: "/elsewhere")
        #expect(paths.first == "/elsewhere/ghostty/config")
        #expect(GhosttyConfigLoader.themeDirectories(
            home: "/home/x",
            xdgConfigHome: "/elsewhere",
            resources: ["/bundled"]
        ) == ["/elsewhere/ghostty/themes", "/bundled"])
    }

    // MARK: - No Ghostty at all

    @Test("no config file anywhere means no opinion, so Bloom keeps its own colours")
    func absentConfigLeavesDefaults() {
        let missing = "\(TestScratch.path("absent"))/ghostty/config"
        #expect(GhosttyConfigLoader.load(
            appearance: .light,
            paths: [missing],
            themeDirectories: []
        ) == nil)
    }

    @Test("a config that says nothing about appearance is also no opinion")
    func silentConfigIsNoOpinion() throws {
        let directory = TestScratch.path("ghostty")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = (directory as NSString).appendingPathComponent("config")
        try "term = xterm-256color\nkeybind = ctrl+z=close_surface\n".write(
            toFile: path, atomically: true, encoding: .utf8
        )

        #expect(GhosttyConfigLoader.load(
            appearance: .light,
            paths: [path],
            themeDirectories: []
        ) == nil)
    }

    @Test("a real pair of files on disk resolves through the loader")
    func loadsFromDisk() throws {
        let directory = TestScratch.path("ghostty-pair")
        let themes = (directory as NSString).appendingPathComponent("themes")
        try FileManager.default.createDirectory(atPath: themes, withIntermediateDirectories: true)

        let lower = (directory as NSString).appendingPathComponent("config")
        let upper = (directory as NSString).appendingPathComponent("config.ghostty")
        try "theme = Fixture\npalette = 2=#5ccd86\n".write(toFile: lower, atomically: true, encoding: .utf8)
        try "background = #fdf6e3\n".write(toFile: upper, atomically: true, encoding: .utf8)
        try Self.solarizedDark.write(
            toFile: (themes as NSString).appendingPathComponent("Fixture"),
            atomically: true,
            encoding: .utf8
        )

        let theme = try #require(GhosttyConfigLoader.load(
            appearance: .light,
            paths: [lower, upper, "\(directory)/missing"],
            themeDirectories: [themes]
        ))

        #expect(theme.background == GhosttyColor(red: 0xFD, green: 0xF6, blue: 0xE3))
        #expect(theme.foreground == GhosttyColor(red: 0x83, green: 0x94, blue: 0x96))
        #expect(theme.palette[2] == GhosttyColor(red: 0x5C, green: 0xCD, blue: 0x86))
    }

    @Test("a theme name with a path separator is refused")
    func themeNamesCannotEscapeTheirDirectory() throws {
        let directory = TestScratch.path("ghostty-escape")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = (directory as NSString).appendingPathComponent("outside")
        try "background = #123456\n".write(toFile: path, atomically: true, encoding: .utf8)

        #expect(GhosttyConfigLoader.themeText(named: "../outside", in: [directory]) == nil)
        #expect(GhosttyConfigLoader.themeText(named: path, in: []) != nil)
    }
}
