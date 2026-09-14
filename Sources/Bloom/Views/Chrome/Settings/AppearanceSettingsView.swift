import AppKit
import SwiftUI
import BloomCore

struct AppearanceSettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @Bindable private var colourTheme = ColourThemePreference.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Theme", selection: $colourTheme.choice) {
                    ForEach(ColourTheme.allCases) { theme in Text(theme.title).tag(theme) }
                }
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                Text("Glass and colour schemes are saved for \(colourTheme.choice.title). Fonts, sizes and line heights apply to every theme.")
                    .settingsFootnote()
                Button("Restore Theme Defaults") { colourTheme.restoreDefaults() }
            }

            Section("Window") {
                Picker("Sidebar glass", selection: $colourTheme.glassOverride) {
                    Text("Theme default (\(colourTheme.choice.glass.title))").tag(nil as ThemeGlass?)
                    ForEach(ThemeGlass.allCases) { glass in Text(glass.title).tag(glass as ThemeGlass?) }
                }
            }

            Section("Code") {
                Picker("Colour scheme", selection: $colourTheme.overrides.codeScheme) {
                    Text("Theme default (\(CodeScheme.find(colourTheme.choice.codeScheme).title))").tag(nil as String?)
                    ForEach(CodeScheme.all) { scheme in Text(scheme.title).tag(scheme.id as String?) }
                }
                typographyControls(terminal: false)
                CodeBlockView(code: "// Read a file\nlet name = \"Bloom\"\nprint(name)", language: .swift)
            }

            Section("Terminal") {
                Toggle("Use my Ghostty configuration", isOn: $colourTheme.followsGhostty)
                Text(colourTheme.followsGhostty
                    ? "Colours and fonts your Ghostty config sets are used in every theme. Anything it leaves out comes from the colour scheme below."
                    : "Terminals use the colour scheme below.")
                    .settingsFootnote()
                Picker("Colour scheme", selection: $colourTheme.overrides.terminalSource) {
                    Text("Theme default (\(TerminalScheme.find(colourTheme.choice.terminalScheme).title))")
                        .tag(nil as TerminalSource?)
                    ForEach(TerminalScheme.all) { scheme in
                        Text(scheme.title).tag(TerminalSource.builtin(scheme.id) as TerminalSource?)
                    }
                }
                typographyControls(terminal: true)
                Text(verbatim: "~/dev/bloom $ swift build")
                    .font(Font(TerminalGhostty.font(family: terminalFamily, size: CGFloat(terminalSize))))
                    .foregroundStyle(terminalPalette.foreground.map { Color(nsColor: NSColor($0)) } ?? Palette.codeForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.inset)
                    .background(terminalPalette.background.map { Color(nsColor: NSColor($0)) } ?? Palette.codeBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
            }

            Section {
                Picker("Font", selection: $colourTheme.chatFont) {
                    Section {
                        ForEach(ChatFontCatalogue.curated) { face in
                            Text(face.title).tag(face.id)
                        }
                    }

                    Section("Installed on this Mac") {
                        ForEach(ChatFont.familyChoices(keeping: colourTheme.chatFont), id: \.self) { family in
                            // Each name set in its own face, which is what a font menu is for:
                            // three hundred names in one face is a list to read, and the same
                            // three hundred in their own faces is a list to look at.
                            Text(family)
                                .font(.custom(family, fixedSize: NSFont.systemFontSize))
                                .tag(family)
                        }
                    }
                }

                Text(ChatFont.summary(for: colourTheme.chatFont))
                    .settingsFootnote()

                Picker("Text size", selection: $colourTheme.chatTextSize) {
                    ForEach(ChatTextSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Line height", selection: $colourTheme.chatLineHeight) {
                    ForEach(ChatLineHeight.allCases) { step in
                        Text(step.title).tag(step)
                    }
                }
                .pickerStyle(.segmented)

                ChatTextPreview()
                    .environment(\.fontScale, colourTheme.chatTextSize.scale)
                    .environment(\.chatFont, ChatFont(rawValue: colourTheme.chatFont))
                    .environment(\.chatLineHeight, colourTheme.chatLineHeight)
            } header: {
                Text("Conversation")
            } footer: {
                Text("Applies to what an agent says and to what you type, whichever theme is selected.")
                    .settingsFootnote()
            }
        }
        .settingsForm()
        // The picker only records the choice; this is what makes the running app take it.
        .onAppear { AppearancePreference.apply(appearance) }
        .onChange(of: appearance) { _, value in AppearancePreference.apply(value) }
    }

    @ViewBuilder private func typographyControls(terminal: Bool) -> some View {
        let typography = terminal ? colourTheme.terminalTypography : colourTheme.codeTypography
        let family = terminal ? terminalFamily : typography.fontFamily
        let defaults = terminal ? colourTheme.choice.terminalTypography : colourTheme.choice.codeTypography
        let defaultFamily = defaults.fontFamily ?? (terminal ? ghostty?.fontFamily : nil)
        Picker("Font", selection: typographyBinding(\.fontFamily, terminal: terminal)) {
            Text("Default (\(defaultFamily.flatMap { $0.isEmpty ? nil : $0 } ?? "System monospace"))").tag(nil as String?)
            Text("System monospace").tag("" as String?)
            ForEach(Self.monospaceFamilies.union(family.map { [$0] } ?? []).filter { !$0.isEmpty }.sorted(), id: \.self) { name in
                Text(name).tag(name as String?)
            }
        }
        SettingsRow("Text size") {
            HStack {
                Stepper(value: Binding(
                    get: { terminal ? terminalSize : (typography.fontSize ?? 13) },
                    set: { typographyBinding(\.fontSize, terminal: terminal).wrappedValue = $0 }
                ), in: 9...28, step: 1) {
                    Text("\(Int(terminal ? terminalSize : (typography.fontSize ?? 13))) pt").monospacedDigit()
                }
                .fixedSize()
                Button("Use Default") { typographyBinding(\.fontSize, terminal: terminal).wrappedValue = nil }
                    .disabled(typographyBinding(\.fontSize, terminal: terminal).wrappedValue == nil)
            }
        }
        SettingsRow("Line height") {
            HStack {
                Stepper(value: Binding(
                    get: { typography.lineHeight ?? 1 },
                    set: { typographyBinding(\.lineHeight, terminal: terminal).wrappedValue = $0 }
                ), in: 1...2, step: 0.1) {
                    Text("\(Int(((typography.lineHeight ?? 1) * 100).rounded()))%").monospacedDigit()
                }
                .fixedSize()
                Button("Use Default") { typographyBinding(\.lineHeight, terminal: terminal).wrappedValue = nil }
                    .disabled(typographyBinding(\.lineHeight, terminal: terminal).wrappedValue == nil)
            }
        }
    }

    private func typographyBinding<Value>(_ key: WritableKeyPath<ThemeTypography, Value>, terminal: Bool) -> Binding<Value> {
        Binding(
            get: {
                let overrides = colourTheme.typographyOverrides
                return (terminal ? overrides.terminalTypography : overrides.codeTypography)[keyPath: key]
            },
            set: {
                if terminal {
                    colourTheme.typographyOverrides.terminalTypography[keyPath: key] = $0
                } else {
                    colourTheme.typographyOverrides.codeTypography[keyPath: key] = $0
                }
            }
        )
    }

    private var ghostty: GhosttyTheme? {
        guard colourTheme.followsGhostty, let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        else { return nil }
        return TerminalGhostty.theme(for: appearance)
    }
    private var terminalPalette: GhosttyTheme {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua).map { TerminalGhostty.colours(for: $0) }
            ?? (colorScheme == .dark ? colourTheme.terminalScheme.dark : colourTheme.terminalScheme.light)
    }
    private var terminalFamily: String? { colourTheme.terminalTypography.fontFamily ?? ghostty?.fontFamily }
    private var terminalSize: Double {
        colourTheme.terminalTypography.fontSize ?? ghostty?.fontSize ?? Double(TerminalTextSize.systemDefault)
    }
    private static let monospaceFamilies = Set(NSFontManager.shared.availableFontFamilies.filter {
        NSFont(name: $0, size: 13)?.isFixedPitch == true
    })
}

/// A few rungs of the conversation at once, because one line of body text cannot show what a scale
/// does: what the setting changes is the distance between a heading, a sentence and a filename.
///
/// Drawn by the transcript's own renderer rather than by a hand-built stack of `Text`, because the
/// two questions a face has to answer here are how a paragraph reads and how a span of inline code
/// sits inside it, and only the real renderer pairs the two the way the transcript will. Written
/// as markdown for the same reason: this is the shape an agent actually replies in.
private struct ChatTextPreview: View {
    private static let sample = """
    ## Ran the test suite

    All 443 tests pass. **Cause:** a stale snapshot in `DiffParserTests.swift`, not the parser. \
    **Fix:** regenerated it with `swift test --update-snapshots` and left `parse(hunk:)` alone.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            // Led the way the transcript leads it, off the same environment the pickers above
            // write. This is the only control in the pane whose effect is invisible without the
            // preview: a step is a couple of points between lines, which nobody can picture from
            // the word "Looser" and everybody can see in a paragraph.
            MarkdownView(Self.sample)
                .proseLeading()

            HStack(spacing: Metrics.spacing) {
                Chip(text: "Sources/BloomCore/Store.swift", systemImage: "doc", monospaced: true)
                DiffStatLabel(additions: 118, deletions: 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.inset)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(Palette.border, lineWidth: Metrics.outline)
        }
        .accessibilityLabel("Preview of the conversation in this font, text size and line height")
    }
}
