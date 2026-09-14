import Foundation
import Testing
@testable import BloomCore

@Suite("Colour themes")
struct ColourThemeTests {
    @Test func unknownPreferenceUsesBloom() {
        #expect(ColourTheme(storedValue: nil) == .bloom)
        #expect(ColourTheme(storedValue: "removed") == .bloom)
        #expect(ColourTheme(storedValue: "neutral") == .charcoalGlass)
    }

    @Test(arguments: ColourTheme.allCases)
    func jsonRoundTrip(theme: ColourTheme) throws {
        let data = try JSONEncoder().encode(theme)
        let decoded = try JSONDecoder().decode(ColourTheme.self, from: data)
        #expect(decoded == theme)
    }

    @Test func charcoalKeepsApprovedGlass() {
        let theme = ColourTheme.charcoalGlass
        #expect(theme.glass == .thick)
        #expect(theme.surfaces.glassTint?.dark == 0x212938)
        #expect(theme.glass.tintOpacity(maximum: theme.surfaces.glassTintOpacity ?? 0.4) == 0.4)
    }

    @Test func customThemeDefinition() throws {
        let json = """
        {
            "schemaVersion": 1,
            "id": "custom", "title": "Custom", "glass": "off",
            "codeScheme": "bloom", "terminalScheme": "bloom",
            "codeTypography": {}, "terminalTypography": {},
            "chatFont": "system", "chatTextSize": "large", "chatLineHeight": "standard",
            "surfaces": {
                "surface": {"light": 16777215, "dark": 2698291},
                "raised": {"light": 16777215, "dark": 2764084},
                "sunken": {"light": 16448250, "dark": 2435119},
                "sidebar": {"light": 16119285, "dark": 3159099},
                "border": {"light": 14606046, "dark": 5198684},
                "selected": {"light": 15066597, "dark": 4343115}
            }
        }
        """
        let theme = try JSONDecoder().decode(ColourTheme.self, from: Data(json.utf8))
        #expect(theme.id == "custom")
        #expect(theme.glass == .off)
        #expect(theme.surfaces.surface.dark == 0x292C33)
    }

    @Test(arguments: ColourTheme.allCases, [false, true])
    func readableInk(theme: ColourTheme, dark: Bool) {
        let surfaces = theme.surfaces
        let grounds = [surfaces.surface, surfaces.raised, surfaces.sunken]
        let inks = [
            PaletteInk.textTertiary, PaletteInk.accent, PaletteInk.negative,
            PaletteInk.stop, PaletteInk.warning, PaletteInk.running, PaletteInk.merged,
        ]
        for ground in grounds {
            for ink in inks {
                #expect(Contrast.ratio(ink.member(dark: dark), ground.member(dark: dark)) >= Contrast.textFloor)
            }
            #expect(Contrast.ratio(surfaces.border.member(dark: dark), ground.member(dark: dark)) >= 1.2)
        }
    }

    @Test(arguments: ColourTheme.allCases, [false, true])
    func readableSyntax(theme: ColourTheme, dark: Bool) {
        let inks = [
            PaletteInk.synKeyword, PaletteInk.synType, PaletteInk.synString,
            PaletteInk.synNumber, PaletteInk.synComment, PaletteInk.synFunction,
            PaletteInk.synVariable, PaletteInk.synAttribute, PaletteInk.synOperator,
        ]
        for ink in inks {
            #expect(Contrast.ratio(
                ink.member(dark: dark), theme.surfaces.surface.member(dark: dark)
            ) >= Contrast.textFloor)
        }
    }
}
