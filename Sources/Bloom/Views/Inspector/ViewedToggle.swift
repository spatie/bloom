import SwiftUI
import BloomCore

/// The `Viewed` checkbox, remembered per workspace and per file.
///
/// It lives in `UserDefaults` rather than in the workspace's row or in `AppModel`. Being marked
/// as read is a property of one person's pass through one diff, not of the workspace, and it is
/// worth nothing to any other machine, so a defaults key is the honest storage for it. The key is
/// built from the workspace id and the file's path, which is also why the toggle is its own view:
/// `@AppStorage` binds its key when the property wrapper is created, so a dynamic key only tracks
/// the file if the view holding it is re-created when the file changes. The caller gives it an
/// `.id` for exactly that reason.
struct ViewedToggle: View {
    var compact: Bool

    @AppStorage private var isViewed: Bool

    init(workspaceID: WorkspaceID, path: String, compact: Bool) {
        self.compact = compact
        _isViewed = AppStorage(wrappedValue: false, Self.key(workspaceID: workspaceID, path: path))
    }

    static func key(workspaceID: WorkspaceID, path: String) -> String {
        "inspector.viewed.\(workspaceID).\(path)"
    }

    var body: some View {
        Group {
            if compact {
                toggle.labelStyle(.iconOnly)
            } else {
                toggle.labelStyle(.titleAndIcon)
            }
        }
        .toggleStyle(.button)
        .inspectorBarControl()
        .help(isViewed ? "Mark this file as not yet reviewed" : "Mark this file as reviewed")
    }

    /// A shape that still carries the meaning with its title hidden. An empty `square` icon-only
    /// is a bordered button containing a smaller square, which reads as nothing at all.
    private var toggle: some View {
        Toggle(isOn: $isViewed) {
            Label("Viewed", systemImage: isViewed ? "checkmark.circle.fill" : "checkmark.circle")
        }
    }
}
