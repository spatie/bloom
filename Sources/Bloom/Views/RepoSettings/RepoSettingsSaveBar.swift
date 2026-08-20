import SwiftUI
import BloomCore

/// The one control that writes to disk, and the sentence that says what it is about to write.
///
/// An explicit Save rather than saving as you type, because these fields are not this app's own
/// preferences: they are lines in a file that is very often committed and shared. Writing a
/// half-finished setup script into a teammate's file on every keystroke would be worse than
/// useless, and `git status` would flicker while you thought.
struct RepoSettingsSaveBar: View {
    @Bindable var model: RepoSettingsModel

    var body: some View {
        HStack(spacing: Metrics.gutter) {
            status
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Metrics.spacingSmall)

            Button("Revert", action: model.revert)
                .disabled(!model.isDirty && !model.hasExternalChange)

            Button("Save") {
                Task { await model.save() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!model.isDirty)
        }
        .padding(.horizontal, Metrics.pane)
        .padding(.vertical, Metrics.inset)
        .background(Palette.surface)
    }

    @ViewBuilder
    private var status: some View {
        if let error = model.saveError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(Typo.caption)
                .foregroundStyle(Palette.negative)
        } else if model.hasExternalChange {
            // Not resolved silently in either direction. Overwriting what arrived would lose a
            // teammate's change; discarding what is on screen would lose the user's. Both are on
            // the table and the sentence says so.
            Label(
                "These settings changed on disk while you were editing them. Save keeps what is on screen. Revert takes the new version.",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(Typo.caption)
            .foregroundStyle(Palette.warning)
        } else if model.isDirty {
            Text("Unsaved changes to \(destinations).")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
        } else if !model.savedPaths.isEmpty {
            Label("Saved to \(saved).", systemImage: "checkmark.circle.fill")
                .font(Typo.caption)
                .foregroundStyle(Palette.positive)
        }
        // Nothing when there is nothing to report. Where a setting is stored is said beside the
        // setting, on the row that writes it, which is where it can be read while it matters.
    }

    private var destinations: String {
        list(model.pendingDestinations)
    }

    private var saved: String {
        list(model.savedPaths)
    }

    private func list(_ paths: [String]) -> String {
        let names = paths.map { path -> String in
            path.hasPrefix(model.repo.path + "/")
                ? String(path.dropFirst(model.repo.path.count + 1))
                : (path as NSString).abbreviatingWithTildeInPath
        }
        return names.isEmpty ? "the repository" : names.joined(separator: " and ")
    }
}
