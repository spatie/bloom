import AppKit
import SwiftUI
import BloomCore

/// The Appearance pane.
///
/// Its own tab rather than four more rows in General, for the same reason Notifications got one.
/// General is a short list of unrelated behaviours: whether archiving asks first, and where
/// workspaces are kept. Everything about how Bloom *looks* is now here instead, which is where two
/// size controls belong, and a size control is the one kind that is useless without a preview: set
/// blind, it is a guess, a trip back to the window, and a trip back here. The previews are what
/// make the tab worth its own pane, and they are also what would have swamped General.
///
/// The two sizes are separate because they are different things. The conversation is prose set in
/// a face of its own and scales as a whole scale of rungs; a terminal is a monospaced grid at one
/// point size that the user has already chosen once, in Ghostty.
///
/// Line height sits under text size rather than in a pane of its own, because they are one
/// subject: both are about how the conversation is set, both are read off the same preview, and a
/// person who finds one has found the other. It is the last of the three because it is the one
/// worth adjusting only after the size and the face are settled.
struct AppearanceSettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(ChatTextSize.defaultsKey) private var chatTextSize = ChatTextSize.standard
    @AppStorage(ChatFont.defaultsKey) private var chatFont = ChatFont.standard
    @AppStorage(ChatLineHeight.defaultsKey) private var chatLineHeight = ChatLineHeight.standard
    @AppStorage(TerminalGhostty.defaultsKey) private var usesGhosttyTheme = true
    /// Zero means "no override, follow Ghostty". Read here as well as in `TerminalTextSize` so the
    /// pane redraws when a Cmd+Plus in a terminal moves it while this window is open.
    @AppStorage(TerminalTextSize.defaultsKey) private var terminalFontSize = 0.0
    @AppStorage(TerminalPersistence.defaultsKey) private var persistsTerminals = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker("Font", selection: $chatFont) {
                    ForEach(ChatFont.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }
                .pickerStyle(.segmented)

                Text(chatFont.summary)
                    .settingsFootnote()

                Picker("Text size", selection: $chatTextSize) {
                    ForEach(ChatTextSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Line height", selection: $chatLineHeight) {
                    ForEach(ChatLineHeight.allCases) { step in
                        Text(step.title).tag(step)
                    }
                }
                .pickerStyle(.segmented)

                ChatTextPreview()
                    .environment(\.fontScale, chatTextSize.scale)
                    .environment(\.chatFont, chatFont)
                    .environment(\.chatLineHeight, chatLineHeight)
            } header: {
                Text("Conversation")
            } footer: {
                Text("Applies to what an agent says and to what you type. The rest of the window follows System Settings.")
                    .settingsFootnote()
            }

            Section {
                Toggle("Use Ghostty terminal theme", isOn: $usesGhosttyTheme)
                    .help("Reads the font and colours from your Ghostty configuration. Off uses Bloom's own palette.")

                SettingsRow("Text size") {
                    HStack(spacing: Metrics.gutter) {
                        Stepper(value: sizeBinding, in: TerminalTextSize.range, step: TerminalTextSize.step) {
                            Text("\(Int(effectiveTerminalSize)) pt")
                                .monospacedDigit()
                        }

                        Button("Use Default") { TerminalTextSize.override = nil }
                            .disabled(terminalFontSize == 0)
                    }
                }

                TerminalTextPreview(size: effectiveTerminalSize, usesGhosttyTheme: usesGhosttyTheme)
            } header: {
                Text("Terminal")
            } footer: {
                Text(terminalSizeSource)
                    .settingsFootnote()
            }

            // Its own section, because it is its own subject. Surviving a quit has nothing to do
            // with how large a terminal is set, and the two sat in one card with a loose sentence
            // between them doing the work a footer is for.
            Section {
                Toggle("Keep terminals running after quitting", isOn: $persistsTerminals)
                    .disabled(!TerminalPersistence.isTmuxInstalled)
                    .help(
                        "Terminals run in tmux instead of inside Bloom, so they survive a quit "
                        + "and come back on the next launch."
                    )
            } footer: {
                Text(TerminalSettingsCopy.persistence(isTmuxInstalled: TerminalPersistence.isTmuxInstalled))
                    .settingsFootnote()
            }
        }
        .settingsForm()
        // The picker only records the choice; this is what makes the running app take it.
        .onAppear { AppearancePreference.apply(appearance) }
        .onChange(of: appearance) { _, value in AppearancePreference.apply(value) }
    }

    /// A derived binding rather than the stored value, because the control has to show the size a
    /// terminal is actually at, and that is Ghostty's number until somebody overrides it. Writing
    /// through it is what turns "follow Ghostty" into an explicit choice, which is the moment the
    /// user asked for one.
    private var sizeBinding: Binding<CGFloat> {
        Binding(
            get: { effectiveTerminalSize },
            set: { TerminalTextSize.override = $0 }
        )
    }

    private var effectiveTerminalSize: CGFloat {
        TerminalTextSize.override ?? TerminalTextSize.fallback(for: NSApp.effectiveAppearance)
    }

    /// Which of the three states the size is in. The sentences and the choice between them are
    /// `TerminalSettingsCopy`, in the core, where a test can read them; this reads the two numbers
    /// off AppKit and hands them over.
    private var terminalSizeSource: String {
        TerminalSettingsCopy.textSizeSource(
            override: TerminalTextSize.override.map { Double($0) },
            ghostty: TerminalTextSize.ghosttyDefault(for: NSApp.effectiveAppearance).map { Double($0) }
        )
    }
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

/// The same face a shell will actually be drawn in, Ghostty's included, rather than the system
/// monospace standing in for it: the whole question here is whether that font is readable at that
/// size, and a substitute cannot answer it.
private struct TerminalTextPreview: View {
    var size: CGFloat
    var usesGhosttyTheme: Bool

    private var font: NSFont {
        let family = usesGhosttyTheme
            ? TerminalGhostty.theme(for: NSApp.effectiveAppearance)?.fontFamily
            : nil
        return TerminalGhostty.font(family: family, size: size)
    }

    var body: some View {
        Text(verbatim: "~/dev/bloom (main) $ swift build --product Bloom")
            .font(Font(font))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(Palette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.inset)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
            .accessibilityLabel("Preview of a terminal at this text size")
    }
}
