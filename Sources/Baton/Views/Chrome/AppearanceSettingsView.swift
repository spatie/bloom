import AppKit
import SwiftUI

/// The Appearance pane.
///
/// Its own tab rather than four more rows in General, for the same reason Notifications got one.
/// General is a short list of unrelated behaviours: whether archiving asks first, and where
/// workspaces are kept. Everything about how Baton *looks* is now here instead, which is where two
/// size controls belong, and a size control is the one kind that is useless without a preview: set
/// blind, it is a guess, a trip back to the window, and a trip back here. The previews are what
/// make the tab worth its own pane, and they are also what would have swamped General.
///
/// The two sizes are separate because they are different things. The conversation is prose set in
/// the system face and scales as a whole scale of rungs; a terminal is a monospaced grid at one
/// point size that the user has already chosen once, in Ghostty.
struct AppearanceSettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(ChatTextSize.defaultsKey) private var chatTextSize = ChatTextSize.standard
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
                Picker("Text size", selection: $chatTextSize) {
                    ForEach(ChatTextSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                ChatTextPreview()
                    .environment(\.fontScale, chatTextSize.scale)
            } header: {
                Text("Conversation")
            } footer: {
                Text("Applies to what an agent says and to what you type. The sidebar, the inspector and the toolbar follow the text size in System Settings.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }

            Section {
                Toggle("Use Ghostty terminal theme", isOn: $usesGhosttyTheme)
                    .help("Reads the font and colours from your Ghostty configuration. Off uses Baton's own palette.")

                LabeledContent("Text size") {
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

                Toggle("Keep terminals running after quitting", isOn: $persistsTerminals)
                    .disabled(!TerminalPersistence.isTmuxInstalled)
                    .help(
                        "Terminals run in tmux instead of inside Baton, so they survive a quit "
                        + "and come back on the next launch."
                    )

                Text(persistenceFooter)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            } header: {
                Text("Terminal")
            } footer: {
                Text(terminalFooter)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .formStyle(.grouped)
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

    /// Says which of the three states the size is in, because "14 pt" alone cannot tell somebody
    /// whether Baton is following their terminal or has quietly stopped.
    /// Said next to the switch rather than in the section footer, which already explains the text
    /// size. The archive sentence is not a detail: a shell left running in a worktree that has
    /// just been deleted is the failure this feature could otherwise cause, and the guarantee that
    /// it cannot is worth stating where the switch is thrown.
    private var persistenceFooter: String {
        guard TerminalPersistence.isTmuxInstalled else {
            return "Requires tmux, which is not installed. Install it with `brew install tmux`. "
                + "Until then terminals stop when you quit Baton."
        }
        return "Terminals keep running when you quit Baton and are restored on the next launch, "
            + "with their scrollback and anything still running in them. Archiving a workspace "
            + "always stops its terminals, whatever this is set to."
    }

    private var terminalFooter: String {
        let shortcuts = "Cmd+Plus and Cmd+Minus change this from any terminal, Cmd+0 returns to the default."
        if TerminalTextSize.override != nil {
            return "Set here, so it no longer follows Ghostty. " + shortcuts
        }
        if let ghostty = TerminalTextSize.ghosttyDefault(for: NSApp.effectiveAppearance) {
            return "Following your Ghostty configuration's font-size of \(Int(ghostty)) pt. " + shortcuts
        }
        return "No Ghostty configuration was found, so terminals use the system monospaced size. " + shortcuts
    }
}

/// A few rungs of the conversation at once, because one line of body text cannot show what a scale
/// does: what the setting changes is the distance between a heading, a sentence and a filename.
private struct ChatTextPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Text("Ran the test suite")
                .font(Typo.title)

            Text("All 443 tests pass. The failure was a stale snapshot, not the parser.")
                .font(Typo.body)
                .foregroundStyle(Palette.textPrimary)

            HStack(spacing: Metrics.spacing) {
                Chip(text: "Sources/BatonCore/Store.swift", systemImage: "doc", monospaced: true)
                DiffStatLabel(additions: 118, deletions: 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.inset)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
        }
        .accessibilityLabel("Preview of the conversation at this text size")
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
        Text(verbatim: "~/dev/baton (main) $ swift build --product Baton")
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
