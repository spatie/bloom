import SwiftUI
import BloomCore

/// The composer's two described pickers, at the width they really open at, in the states they are
/// really in.
///
/// It exists because these rows replaced an `NSMenu`, and a menu was the one thing in this window
/// that could only be photographed by opening it on the owner's screen: `MenuProbe` had a `style`
/// part for exactly that and it is gone with the menu. A panel is an ordinary SwiftUI view, so the
/// same rows can be rendered offscreen in both appearances, which is the whole reason this page is
/// cheaper than what it replaces.
///
///     Bloom --snapshot-gallery <dir> --gallery composer-pickers
///
/// What has to be visible at a glance, and none of it is visible from the tests. That a two line
/// row is padded like a two line row, which `QuickPromptRow` got wrong twice. That the tick column
/// holds its width down the list whether or not a row is ticked. That the vendors' sentences wrap
/// inside 380 points rather than reaching for a fourth line. That the highlight and the tick are
/// two different things: the Codex column is drawn with the highlight one row below the tick,
/// which is the state arrowing through the list is in for all but one of its rows.
///
/// The Codex column is also the whole of the Plan question. Bloom has a Plan mode, Codex has
/// nothing that means it, and the answer is that the row is simply not there: no greyed line, no
/// footnote explaining an absence. The two permission columns side by side are how that is
/// checked, because the fault it replaced was a menu that named a mode it would not offer.
struct ComposerPickerGallery: View {
    var app: AppModel

    /// Held rather than made where it is read, because this page reads it twice and each read
    /// would otherwise be a second catalogue. Never scanned: the built in styles are what almost
    /// every machine has and are in the list before any disk walk, which is exactly what this
    /// page needs and all it needs.
    @State private var styleCatalog = ComposerOutputStyleCatalog()

    private var outputStyles: [ComposerOption] {
        styleCatalog.options(includingCurrent: "Concise")
    }

    private func permissionOptions(on kind: AgentKind) -> [ComposerOption] {
        ComposerControls(agentKind: kind).permissionModeChoices.map {
            ComposerOption(id: $0.mode.rawValue, label: $0.label, detail: $0.summary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.pane) {
            VStack(alignment: .leading, spacing: Metrics.pane) {
                panel(
                    "Claude Code, on the widest mode there is",
                    options: permissionOptions(on: .claudeCode),
                    selection: PermissionMode.bypassPermissions.rawValue,
                    heading: "Permission mode"
                )
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: Metrics.pane) {
                panel(
                    "Codex, which has no Plan row and says nothing about it",
                    options: permissionOptions(on: .codex),
                    selection: PermissionMode.auto.rawValue,
                    heading: "Permission mode"
                )
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: Metrics.pane) {
                panel(
                    "Ask Bloom, where the footnote is the one thing left in it",
                    options: permissionOptions(on: .claudeCode),
                    selection: PermissionMode.auto.rawValue,
                    heading: "Permission mode",
                    footnote: ComposerControls(hasWorktree: false).permissionModeNote
                )
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: Metrics.pane) {
                panel(
                    "Output styles, in the CLI's own words",
                    options: outputStyles,
                    selection: "Concise",
                    heading: "Output style"
                )
                captioned("The chips these hang off, in both widths") { chips }
                Spacer(minLength: 0)
            }
        }
        .padding(Metrics.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface)
        .environment(app)
    }

    /// The real `ComposerOptionList`, in a plate of its own, since a popover's chrome is not here
    /// to draw one. Nothing about the rows is reimplemented to get the picture.
    private func panel(
        _ caption: String,
        options: [ComposerOption],
        selection: String,
        heading: String,
        footnote: String? = nil
    ) -> some View {
        captioned(caption) {
            ComposerOptionList(
                options: options,
                footnote: footnote,
                selection: selection,
                heading: heading,
                onSelect: { _ in },
                onClose: {}
            )
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.corner + 2))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.corner + 2)
                    .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
            }
        }
    }

    /// The chips in the footer, both with their word and stripped to the glyph, because that is
    /// the step `ComposerFooterView` takes when the centre column is dragged narrow. The warning
    /// tint on Full access is the one colour decision in the row and is only visible here.
    private var chips: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            ForEach([false, true], id: \.self) { isCompact in
                HStack(spacing: Metrics.spacingTight) {
                    ComposerOptionPicker(
                        options: outputStyles,
                        selection: "Concise",
                        heading: "Output style",
                        systemImage: "textformat",
                        isCompact: isCompact,
                        help: "Choose the output style",
                        onSelect: { _ in }
                    )
                    ComposerOptionPicker(
                        options: permissionOptions(on: .claudeCode),
                        selection: PermissionMode.auto.rawValue,
                        heading: "Permission mode",
                        systemImage: "hand.raised",
                        isCompact: isCompact,
                        help: "Choose permission mode",
                        onSelect: { _ in }
                    )
                    ComposerOptionPicker(
                        options: permissionOptions(on: .claudeCode),
                        selection: PermissionMode.bypassPermissions.rawValue,
                        heading: "Permission mode",
                        systemImage: "exclamationmark.shield",
                        tint: Palette.warning,
                        isCompact: isCompact,
                        help: "Choose permission mode",
                        onSelect: { _ in }
                    )
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: ComposerOptionList.width)
    }

    private func captioned(_ caption: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text(caption)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            content()
        }
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// No field is being typed into: the panel takes the keyboard in the app, but nothing here is
    /// waiting on a caret and a focus ring is not what this page is about.
    static let composerPickers = Gallery(
        name: "composer-pickers",
        title: "Composer pickers",
        size: CGSize(width: 1680, height: 1000),
        needsFocus: false,
        view: { app in AnyView(ComposerPickerGallery(app: app)) }
    )
}
