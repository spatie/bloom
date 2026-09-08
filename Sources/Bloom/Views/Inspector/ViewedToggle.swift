import SwiftUI
import BloomCore

/// The `Viewed` tick in the file bar: whether this file has been read, in this pass, at the diff
/// it has now.
///
/// **This existed once before as an `@AppStorage` bool and was taken out for being a dead end**
/// ("Take Viewed out of the file bar"): nothing but the tick itself ever read it, so a file could
/// be marked and the mark was invisible from anywhere else. What is different now is where the
/// answer goes rather than how the control looks: the changed file list dims and ticks the row,
/// it counts how many of the diff has been read, and the mark is a row in the store keyed by
/// workspace and path, so it survives a relaunch and dies with the worktree.
///
/// The wording is `ReviewedMarkAction`, in the core, shared with the row's context menu, so the
/// bar and the menu cannot come to two accounts of what the control does.
struct ViewedToggle: View {
    var model: WorkspaceModel
    var file: ChangedFile

    private var isViewed: Bool { model.isViewed(file) }
    private var action: ReviewedMarkAction { ReviewedMarkAction(isViewed: isViewed) }

    var body: some View {
        Toggle(isOn: Binding(get: { isViewed }, set: { mark($0) })) {
            // A shape that still carries the meaning with its title hidden. An empty `square`
            // icon-only is a bordered button holding a smaller square, which reads as nothing at
            // all.
            Label("Viewed", systemImage: isViewed ? "checkmark.circle.fill" : "checkmark.circle")
        }
        .labelStyle(.iconOnly)
        .toggleStyle(.button)
        .inspectorBarControl()
        .help(action.help(for: file.filename))
        .accessibilityLabel(action.title)
    }

    private func mark(_ isViewed: Bool) {
        let model = model
        let file = file
        Task { await model.setViewed(isViewed, file: file) }
    }
}
