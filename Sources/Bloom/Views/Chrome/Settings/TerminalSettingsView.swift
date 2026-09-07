import AppKit
import SwiftUI
import BloomCore

/// Terminal appearance and lifecycle share a destination, separate from outside client access.
struct TerminalSettingsView: View {
    @AppStorage(TerminalGhostty.defaultsKey) private var usesGhosttyTheme = true
    /// Zero means "no override, follow Ghostty". Read here as well as in `TerminalTextSize` so the
    /// pane redraws when a Cmd+Plus in a terminal moves it while this window is open.
    @AppStorage(TerminalTextSize.defaultsKey) private var terminalFontSize = 0.0
    @AppStorage(TerminalPersistence.defaultsKey) private var persistsTerminals = false

    var body: some View {
        Form {
            Section {
                Toggle("Use Ghostty terminal theme", isOn: $usesGhosttyTheme)
                    .help("Reads the font and colours from your Ghostty configuration. Off uses Bloom's own palette.")

                SettingsRow("Text size") {
                    HStack(spacing: Metrics.gutter) {
                        Stepper(value: sizeBinding, in: TerminalTextSize.range, step: TerminalTextSize.step) {
                            Text("\(Int(effectiveTerminalSize)) pt")
                                .monospacedDigit()
                        }
                        .fixedSize()

                        Button("Use Default") { TerminalTextSize.override = nil }
                            .disabled(terminalFontSize == 0)
                    }
                }

                TerminalTextPreview(size: effectiveTerminalSize, usesGhosttyTheme: usesGhosttyTheme)
            } header: {
                Text("Appearance")
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
            } header: {
                Text("After quitting Bloom")
            } footer: {
                Text(TerminalSettingsCopy.persistence(isTmuxInstalled: TerminalPersistence.isTmuxInstalled))
                    .settingsFootnote()
            }
        }
        .settingsForm()
    }

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
