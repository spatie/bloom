import SwiftUI
import BloomCore

/// The quick prompts panel, at the width it really opens at, in the states it is really in.
///
/// It exists because this panel shipped twice with things wrong with it that one look would have
/// caught: the popover hung off the middle of the composer footer instead of its button, a two line
/// row was padded like a one line one so the name sat against the top of its own selection, and the
/// selection ran flush into the panel's rounded corners. None of that is visible from the tests,
/// which are about ranking and insertion, and the panel is a popover, so the window probes cannot
/// open it either.
///
///     Bloom --snapshot-gallery <dir> --gallery quick-prompts
///
/// Two columns: the list on the left, the form on the right. The form is here because the icon
/// picker replaced an inline grid, and the two things worth looking at are whether an emoji sits
/// in the same column as a symbol without reading a size larger, and whether the picker hangs off
/// the well squarely. Neither is visible from the tests, and both are what the last four rounds of
/// this panel got wrong.
struct QuickPromptGallery: View {
    var app: AppModel

    /// Real prompts rather than lorem: the shipped built-in, one with a long name that has to
    /// truncate, one with no name at all, which falls back to its own first line, and two marked
    /// with emoji, which is the case the mark column has to survive.
    private var prompts: [QuickPrompt] {
        [
            QuickPrompt(
                name: "Explain changes",
                symbol: "doc.richtext",
                text: "Explain the changes made in this PR as HTML. Open it as a new tab in this workspace.",
                sortOrder: 0
            ),
            QuickPrompt(
                name: "Run the tests and fix whatever comes back failing",
                symbol: "checkmark.seal",
                text: "Run make test. If anything fails, fix it and run the failing test again on its own.",
                sortOrder: 1
            ),
            // The mark that has to hold its own beside the tinted ones on either side of it.
            QuickPrompt(
                name: "Hunt the flake",
                symbol: "\u{1F41B}",
                text: "Run the failing test twenty times and say what makes it fail.",
                sortOrder: 2
            ),
            QuickPrompt(
                name: "",
                symbol: "text.alignleft",
                text: "Walk me through the diff, file by file, and say why each change is there.",
                sortOrder: 3
            ),
            QuickPrompt(
                name: "Ship it",
                symbol: "\u{1F680}",
                text: "Push the branch, open the pull request, and wait for the checks.",
                sortOrder: 4
            ),
            // Longer than the panel by a wide margin, which is the case that has to truncate
            // gracefully rather than push the pencil off the edge or wrap into a third line.
            QuickPrompt(
                name: "Open a pull request against the release branch and write the description "
                    + "from the commits rather than from the diff",
                symbol: "arrow.triangle.pull",
                text: "Push the branch and open a pull request. Three sentences, no headings.",
                sortOrder: 5
            ),
            // One word with nowhere to break. Truncation has to cut it rather than let it push
            // everything else out of the row.
            QuickPrompt(
                name: "Regenerate\u{200B}TheSnapshotFixturesForEveryGalleryPageInOneGo",
                symbol: "camera",
                text: "Run every gallery capture and replace the fixtures under Tests.",
                sortOrder: 6
            ),
        ]
    }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.pane) {
            VStack(alignment: .leading, spacing: Metrics.pane) {
                panel("The first row, highlighted on opening", selected: 0)
                panel("Nothing written yet", selected: nil, empty: true)
                form("Name and icon, a symbol chosen", prompt: prompts[0])
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: Metrics.pane) {
                form("An emoji chosen", prompt: prompts[4])
                // Both tabs, and the tab each opens on is read off the mark the prompt already
                // carries, so these two are also the test of that.
                form("The picker, open on the well", prompt: prompts[0], picking: true)
                form("The same picker on a prompt marked with an emoji",
                     prompt: prompts[4], picking: true)
                Spacer(minLength: 0)
            }
        }
        .padding(Metrics.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface)
        .environment(app)
    }

    /// The form, in its own plate, at the width the panel opens at.
    private func form(
        _ caption: String, prompt: QuickPrompt, picking: Bool = false
    ) -> some View {
        captioned(caption) {
            QuickPromptForm(
                editing: prompt,
                startsPickingMark: picking,
                onCancel: {}, onSave: { _, _, _ in }, onDelete: {}
            )
            .frame(width: 380)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.corner + 2))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.corner + 2)
                    .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
            }
        }
    }

    /// `emphasized: false` draws the same row through the same code with the window read as
    /// inactive, which is exactly how `RowBackground` decides between the accent fill and the quiet
    /// grey. Nothing about the row is reimplemented here to get the comparison.
    private func panel(
        _ caption: String, selected: Int?, empty: Bool = false, emphasized: Bool = true
    ) -> some View {
        captioned(caption) {
            VStack(alignment: .leading, spacing: 0) {
                searchLine
                Hairline()

                if empty {
                    VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                        Text("Nothing here yet.")
                            .font(Typo.body)
                            .foregroundStyle(Palette.textSecondary)
                        Text("A quick prompt is a few lines you find yourself typing again.")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, contentInset)
                    .padding(.vertical, Metrics.gutter)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                            QuickPromptRow(
                                prompt: prompt,
                                isSelected: index == selected,
                                onPick: {}, onHover: {}, onEdit: {}, onDelete: {}
                            )
                        }
                    }
                    .padding(.horizontal, listInset)
                    .padding(.vertical, Metrics.spacingSmall)
                    .environment(\.controlActiveState, emphasized ? .key : .inactive)
                }

                Hairline()
                newLine
            }
            // The panel's own plate, since a popover's chrome is not here to draw it.
            .frame(width: 380)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.corner + 2))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.corner + 2)
                    .strokeBorder(Palette.border, lineWidth: Metrics.hairline)
            }
        }
    }

    private func captioned(_ caption: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text(caption)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            content()
        }
    }

    /// The same numbers `QuickPromptMenu` uses. Copied rather than shared because the menu keeps
    /// them private and a gallery is not a reason to publish a view's internals.
    private var listInset: CGFloat { Metrics.spacingWide }
    private var contentInset: CGFloat { Metrics.spacingWide + Metrics.spacing }

    private var searchLine: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(Palette.textTertiary)
                .frame(width: Metrics.repoIcon)
            Text("Search quick prompts")
                .font(Typo.body)
                .foregroundStyle(Palette.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, contentInset)
        .padding(.vertical, Metrics.spacingSmall)
        .frame(height: Metrics.rowHeight + Metrics.spacingWide)
    }

    private var newLine: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: "plus")
                .imageScale(.medium)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Metrics.repoIcon, height: Metrics.repoIcon)
            Text("New quick prompt")
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.spacing)
        .frame(height: Metrics.rowHeight)
        .padding(.horizontal, listInset)
        .padding(.vertical, Metrics.spacingSmall)
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// No field is being typed into, so it needs nobody's keyboard.
    static let quickPrompts = Gallery(
        name: "quick-prompts",
        title: "Quick prompts",
        size: CGSize(width: 880, height: 1400),
        needsFocus: false,
        view: { app in AnyView(QuickPromptGallery(app: app)) }
    )
}
