# Theme presets

A theme supplies window colours, glass, independent code and terminal schemes, and typography
defaults. Glass and scheme changes are saved for the selected theme, so switching away and back
restores them, and Restore Theme Defaults clears only those. Fonts, sizes and line heights are
saved once and apply under every theme: a reading size belongs to the person, and held per theme
it reset whenever the theme changed. System, Light or Dark remains a global appearance policy.

## Definitions

The definitions are plain Swift data with Foundation `Codable` support:

| File under `Sources/BloomCore/Presentation` | Purpose |
| --- | --- |
| `ColourTheme+Builtins.swift` | Bloom and Charcoal Glass presets, including scheme references and font defaults |
| `CodeScheme+Builtins.swift` | Code backgrounds, text, gutter, selection, caret, diff tints and token colours |
| `TerminalScheme+Builtins.swift` | Complete light/dark terminal palettes using the existing `GhosttyTheme` data |
| `ThemeTypography.swift` | Optional font family, point size and line-height multiplier for code and terminal |
| `ThemeOverrides.swift` | Per theme glass and scheme changes, and the versioned settings archive |
| `TypographyOverrides.swift` | Code, terminal and conversation typography changes shared by every theme |

Charcoal Glass keeps the stable key `neutral`, so previous selections still work.
Colour pairs contain light and dark RGB integers. Swift definitions use `0xRRGGBB`; JSON
uses decimal integers. Glass is `off`, `thin`, `regular` or `thick`, mapped to a tint over native AppKit
sidebar material. Conversation typography retains its existing font names and size/spacing enums.

`ColourThemePreference` in BloomCore is the single preference owner and is tested with isolated defaults. It saves one versioned archive
under `themeOverrides`: glass and scheme changes keyed by preset, and one typography record,
instead of writing to the old global preferences. The first read migrates glass and the Ghostty
choice to the selected theme and typography to the shared record. Old values remain available
on disk but no longer drive the views. An unreadable archive is backed up and logged; legacy settings supply the fallback.

Each value resolves from its saved override, then the selected preset's default. Missing scheme keys
fall back to the preset's scheme. Missing fonts use the system monospaced font for code and
terminal, and the existing conversation font fallback. Sizes are bounded to 9...28 points;
code and terminal spacing uses a 1...2 multiplier. An empty code/terminal font name explicitly
selects system monospace; an absent name inherits the default.

Use my Ghostty configuration is one setting for every theme, like typography. Terminals then
draw with the user's Ghostty configuration laid over the selected terminal scheme, through
`GhosttyTheme.layered(over:)`. A config that sets its own background or foreground is a whole
terminal and gets Ghostty's defaults for everything it leaves out. A config that sets neither,
typically a palette slot or two, keeps the scheme's background, foreground, cursor and selection
and takes Ghostty's sixteen ANSI colours. Ghostty's font defaults still apply unless a font is
chosen here. Archives written while Ghostty was a per theme scheme follow Ghostty if any theme
did; with no archive, the setting from before presets decides, and it defaulted to on. The
built-in Charcoal terminal uses the preset's sunken panel colour. Terminal padding follows the
drawn terminal background. Native scrollbar knobs use a light or dark style to suit it.

## Rendering

The title bar and tab tracks share the opaque chrome colour. The sidebar uses native
AppKit sidebar material with explicit behind-window blending, tinted with the theme's optional `glassTint` colour (falling back to its sunken panel colour). The preset sets its strongest tint opacity with `glassTintOpacity`; thinner settings reduce it. Stronger glass settings increase that
tint to reduce background colour bleed and transparency. The tint is an AppKit overlay above
the visual effect, so the native material cannot draw over the theme colour.

The code scheme applies to the editor, reader, diff views and fenced code blocks. Inline code
in conversation prose keeps the surrounding text sizing. Code metrics are a cached value on
the main actor. Wrapped layout caches include typography; attributed text caches include the
full code scheme and exact source bytes. Background syntax preparation receives immutable
colours and never reads mutable preferences.

Theme changes update editor attributes without replacing its text or undo stack. Terminal
changes update existing sessions with SwiftTerm's colour, font and spacing APIs. All cursor
and selection colours are assigned on each switch. Font and spacing setters run only when
the value changes. Zoom commands write the shared typography for the focused code editor or
terminal, with the conversation as the fallback.

## Future file support

File importing is not implemented. The definitions are `Codable` and versioned so that a Bloom
preset file, VS Code colour themes for code and Ghostty or `.itermcolors` files for the terminal
can be adapted later without renderers knowing about external formats.

Charcoal Glass keeps its approved dark glass tint `#212938` at 40% opacity. Bloom uses its
blue sidebar colour at 80% opacity, leaving a subtler native glass effect.
