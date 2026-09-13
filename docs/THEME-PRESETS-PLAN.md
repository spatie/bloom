# Theme presets proposal

Status: reviewed with Claude Code and implemented. See THEMES.md for the current model.

## Behaviour

A selected theme supplies window colours, glass material, a code scheme, a terminal scheme,
and typography defaults. Changes made while that theme is selected belong to that theme.
Switching themes restores the other theme's defaults and saved changes. Returning restores
what the user changed. Built-in definitions remain unchanged on disk.

Appearance settings uses existing native controls under the selected theme:

- Window: glass material and the existing System, Light or Dark appearance choice.
- Code: independent colour scheme, font, size and line height.
- Terminal: independent colour scheme, font, size and line height.
- Conversation: the existing font, size and line height controls.
- Restore theme defaults: removes only the selected theme's saved changes.

Keep System, Light or Dark as the global appearance policy. It chooses the light or dark
variant of the selected preset; it does not copy or erase saved changes.
Each configurable value offers a way to return to its theme default.
Show the effective value when following a default, for example "Theme default (Thick)".

Code means the editor, file reader, diff views and fenced code blocks. Inline code within
conversation prose keeps its surrounding text sizing. Diff additions, removals and selections
must remain readable against the selected code background.
Terminal appearance settings move here; terminal process and session settings remain in Terminal.

Example: select Charcoal Glass, select a different code scheme and set glass to Regular.
Bloom keeps its own code scheme and glass when selected. Returning to Charcoal Glass restores
both changes. Changing its terminal scheme does not change its code scheme.

## What PhpStorm actually does

The UI theme and editor scheme are separate. A theme can name a bundled editor scheme using
`editorScheme` in its theme JSON. The user can select a different editor scheme. Editor and
console fonts have defaults with optional overrides. Terminal colours use the console colours
in the editor scheme, with terminal engine differences in where font settings are shown.

This supports Bloom's preset model, but does not imply that PhpStorm supports macOS material
thickness in its theme files. Native glass remains a Bloom setting.

Sources:

- https://www.jetbrains.com/help/phpstorm/user-interface-themes.html
- https://plugins.jetbrains.com/docs/intellij/themes-extras.html
- https://www.jetbrains.com/help/phpstorm/configuring-colors-and-fonts.html
- https://www.jetbrains.com/help/phpstorm/settings-tools-terminal.html

## External formats

| Part | Recommendation | Reason |
| --- | --- | --- |
| Complete Bloom preset | A small, versioned Bloom JSON definition | Existing formats do not describe Bloom's window surfaces, native material and conversation settings together. Reference code and terminal schemes by stable key. |
| Code colours | Target VS Code colour-theme JSON for future imports | It defines editor colours and TextMate token rules, and can also provide terminal ANSI colours. Keep a documented supported subset. |
| Terminal colours | Reuse the existing Ghostty parser first | Bloom already reads the relevant colours and fonts and handles light/dark variants. No second parser is needed now. |
| Additional terminal files | Add `.itermcolors` later | It is a dedicated colour preset format. Font and line-height defaults belong in the containing Bloom preset, not in this colour file. |
| Other editor formats | Consider `.tmTheme` later | VS Code already supports TextMate themes. It has the same scope-matching limitation in Bloom, so it does not remove that work. |

Bloom's highlighter emits a small set of token kinds, not full TextMate scopes or semantic
language-service tokens. A VS Code importer would map supported rules to these token kinds.
It must report unsupported rules; full VS Code rendering compatibility is not a promise.
Changing the highlighter or embedding VS Code is outside this proposal.

Keep external formats at the loading boundary. Renderers consume resolved palettes, not
VS Code keys or Ghostty configuration entries. When import is added, preserve the original
file and identify its format so unsupported settings are not silently lost on export.
A VS Code file with both editor and terminal colours can produce two independently selectable
schemes. Sharing one source file must not couple their selections.

No file importer, file watcher, downloads or theme plugins in this implementation.
Built-in schemes remain data definitions in source files, with serialisation tests.

Sources:

- https://code.visualstudio.com/api/extension-guides/color-theme
- https://code.visualstudio.com/api/references/theme-color#integrated-terminal-colors
- https://ghostty.org/docs/config/reference
- https://iterm2.com/documentation-preferences-profiles-colors.html

## Data changes proposed for approval

Extend `ColourTheme` to reference code and terminal schemes and supply typography defaults.
Keep `neutral` as Charcoal Glass's stable key. Keep `ThemeSurfaces` and `ThemeGlass`.
Move `ColourThemePreference` into BloomCore so its state can be tested directly, and store optional changes by theme key and resolve values in
one place. Do not scatter preference fallbacks through individual views.

New custom data types, each a separate item:

1. `CodeScheme`: stable key, title, light/dark editor colours and token styles. Contains the
   code background, foreground, gutter, caret, selection and diff colours used by code views.
2. `TerminalScheme`: stable key, title and light/dark terminal data. Reuses the existing
   `GhosttyTheme` payload and resolver instead of adding another terminal colour model.
3. `ThemeTypography`: font, size and line-height values used for code and terminal. Conversation retains its existing enums.
   Font fallback uses existing native font lookup. No new font renderer.
4. `ThemeOverrides`: optional code/terminal selections, glass and typography changes saved for
   one theme. An absent value means inherit; explicit values remain stable across theme updates.

New custom flow:

5. One-time settings migration and preset resolution, implemented as pure functions beside the
   existing preference state. Existing saved glass, chat settings and terminal settings become
   overrides of the selected theme. Untouched themes start from their own defaults. Read old
   keys without deleting them until the new settings have been saved successfully.

The migration must preserve existing Ghostty-following behaviour, including the former default
of following Ghostty when no boolean preference was written. Expose "My Ghostty configuration"
as an explicit terminal source. Use theme-owned terminal defaults for new presets, with the
migrated current theme retaining the user's current terminal appearance.

Resolution is per field: saved change, then selected preset default, then Bloom's fallback.
Resolve light/dark variants afterwards. Keep scheme colours separate from typography overrides,
so switching the terminal palette does not unexpectedly reset a chosen font.
Missing scheme keys fall back deterministically. Serialised definitions carry a schema version.
No generic inheritance graph or arbitrary property names.

Claude review also added a typed `TerminalSource` choice to distinguish built-in schemes from
the lazy Ghostty source. Code metrics resolve on the main actor; detached syntax work receives
an immutable colour map. SwiftTerm source confirms spacing is a multiplier.

## Integration and verification

1. Add the data definitions, resolution and migration tests first. Provide at least two
   selectable code and terminal schemes by separating the existing Bloom and charcoal
   appearances, without adding an unrelated third-party theme collection.
2. Change the existing settings form to edit the selected theme's saved changes. Remove the
   global glass setting and route existing text-size commands through the same resolved state.
3. Pass an immutable resolved code scheme into highlighting. Include its palette in the
   attributed-string cache key; retain exact UTF-8 source matching. Background work must not
   read mutable UI preferences. Refresh existing editor attributes without replacing text,
   clearing undo, moving the selection or losing the scroll position.
4. Update `CodeMetrics` so fonts, line heights, wrapping and gutter measurements use the same
   resolved typography. Existing values are static today and cannot simply be left behind.
5. Apply terminal palettes through SwiftTerm's existing APIs. Assign font and `lineSpacing`
   only when changed; its spacing setter resets font metrics and resizes the terminal.
   Apply every cursor and selection colour on each switch so values from a previous theme
   cannot leak through. Preserve live shell sessions and terminal contents.
6. Test independent selections, theme switching and return, field resets, full preset reset,
   persistence, migration, missing scheme/font fallbacks and serialisation. Exercise code
   background/foreground together in both appearances and keep the existing contrast tests.
7. Verify live changes in editor, reader, wrapped/unwrapped diff, code blocks and existing
   terminals. Check gutter alignment, editor undo/selection and terminal resize behaviour.
   Build Bloom Dev, run targeted tests and both linters, then reopen the dev copy.

SwiftTerm 1.19.0 in the current checkout exposes `font`, `installColors`, native foreground,
background, caret and selection colours, and a public `lineSpacing` multiplier. No terminal
subclass or dependency fork is needed for these settings. The existing BloomTerminalSession
remains the application path.
