import SwiftUI
import BloomCore

/// What this project has to say to the agent, on top of what Bloom says, when Bloom sends a turn
/// of its own.
///
/// Bloom's own words are not here and cannot be edited here, which is the whole shape of the pane.
/// The steps for merging are a constant in the app: they are the same in every repository, they
/// are what stops an agent reaching for `--admin` when GitHub says no, and a field that could
/// empty them would be a field that could turn the guard off by being left blank. The steps for
/// resolving a conflict are a file Bloom attaches, `ConflictInstructions`, and they are not
/// editable here either. What varies is the sentence a particular project wants adding, and that
/// is the only thing typed here.
///
/// Empty is the ordinary answer, and the one every project starts on. The turn then carries
/// nothing at all: no attachment, no file named, no paragraph about instructions that do not
/// exist. See `ProjectInstructions`.
///
/// A project that would rather keep this in a file it can review beside the work it governs
/// writes `.bloom/merge-instructions.md` instead, and that file beats this field. The field says
/// so, above the box, on the projects that have one: a field silently outranked is worse than no
/// field at all.
struct RepoInstructionsSection: View {
    @Bindable var model: RepoSettingsModel

    var body: some View {
        Section {
            RepoInstructionsField(
                model: model,
                subject: .merge,
                title: "Merging",
                summary: "Added to the turn Bloom sends when you confirm Merge, under Bloom's own steps and outranking them. Bloom already says which flags are forbidden, to stop rather than force when GitHub refuses, to delete the branch on the server only once the merge succeeded, and to change nothing on this machine.",
                placeholder: "Squash unless the branch is a stack.",
                text: $model.draft.mergeInstructions
            )

            RepoInstructionsField(
                model: model,
                subject: .fixConflicts,
                title: "Merge conflicts",
                summary: "Added to the turn Bloom sends when you press Fix merge conflicts. That turn already brings the base branch in, resolves, commits and pushes, and stops rather than pushing a resolution it is unsure of.",
                placeholder: "Regenerate the lock file rather than resolving it by hand.",
                text: $model.draft.conflictInstructions
            )
        } header: {
            Text("Instructions")
        } footer: {
            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text("Sent as an attachment on the turn, so an agent reads them as a file rather than as one more paragraph of a long message. Nothing is attached when both boxes are empty.")
                Text("Read from the project's settings files rather than from a workspace, so a sentence typed here reaches every workspace as soon as it is saved, including the ones cut before it existed. It travels with the project once the file is committed.")
            }
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One subject's extra instructions: what they are added to, the words, and where they will be
/// written.
///
/// The same order `RepoScriptField` uses, and for the same reason: the destination sits on the
/// title's line so the file this lands in is known before a character is typed, and the sentence
/// saying when it is sent goes underneath, where it can be read once and then ignored.
struct RepoInstructionsField: View {
    let model: RepoSettingsModel
    let subject: ProjectInstructions.Subject
    let title: String
    let summary: String
    var placeholder = ""
    @Binding var text: String

    /// Four or five lines without scrolling, which is longer than anything anybody has typed here
    /// and short enough that two of these fit in one pane.
    private static let editorHeight: CGFloat = 96

    /// Drawn inside the box's own edge rather than outside it, so nothing around it has to give
    /// the ring clearance. See `HomeBar.focusRingWidth`.
    private static let focusRingWidth: CGFloat = 2

    @FocusState private var isFocused: Bool

    /// See `ControlActiveState.showsFocusRing`: a ring belongs in the key window only.
    @Environment(\.controlActiveState) private var activeState

    private var isRingVisible: Bool { isFocused && activeState.showsFocusRing }

    /// The project's own file for this subject, which outranks the field above it whenever it is
    /// there. Only worth a line when it exists: saying "you could also write a file" to somebody
    /// who has not written one is an instruction, and this pane is not the place for one.
    private var overridingFile: String? { model.instructionFiles[subject] }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gutter) {
                Text(title)
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)

                Spacer(minLength: Metrics.spacingSmall)

                // Asked of the core rather than passed in beside the subject, so the file this
                // is saved to and the key the turn reads can never be told two different things.
                SettingsDestinationLabel(
                    model: model, key: ProjectInstructions.settingsKey(for: subject)
                )
            }

            if let overridingFile {
                Label(
                    "\(overridingFile) is in this project, and it wins. What is typed here is not sent while that file has anything in it.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(Typo.caption)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            }

            editor

            Text(summary)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Metrics.spacingSmall)
    }

    /// Prose rather than code, so the ordinary editor rather than `ScriptEditor`: a gutter and
    /// syntax colours down the side of an English sentence say it is a program, and the agent
    /// reads it as neither.
    private var editor: some View {
        TextEditor(text: $text)
            .font(Typo.body)
            .scrollContentBackground(.hidden)
            .padding(Metrics.spacingSmall)
            .frame(minHeight: Self.editorHeight)
            .focused($isFocused)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
            // A hand-built box gets no focus ring from AppKit, and a field that looks identical
            // whether or not it has the keyboard is the single most reliable way to make a Mac
            // window feel like a web page. The same overlay the files-to-copy field uses.
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                    .strokeBorder(
                        isRingVisible ? Palette.focusRing : Palette.border,
                        lineWidth: isRingVisible ? Self.focusRingWidth : Metrics.outline
                    )
            }
            .overlay(alignment: .topLeading) {
                // `TextEditor` has no prompt of its own, and an empty box in a pane of empty boxes
                // says nothing about what belongs in it.
                if text.isEmpty {
                    Text(placeholder)
                        .font(Typo.body)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(Metrics.spacingSmall)
                        .padding(.leading, Metrics.spacingTight)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Instructions for \(title.lowercased())")
    }
}
