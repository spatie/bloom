import SwiftUI
import BloomCore

/// The project settings window.
///
/// A window rather than a sheet on the main window. Two of the three things this screen is for
/// need the project itself to be readable while they are being edited: a glob is checked against
/// the folder, and a setup script is usually written next to the terminal that proved it works. A
/// sheet would block the window the workspaces are in for as long as that takes. It is also one
/// window per project rather than a single shared one, so two projects' scripts can be compared.
///
/// Keyed by the project's id rather than by the whole `Repo`, so a window that macOS restores
/// after a relaunch resolves against the database as it is now rather than against a snapshot of
/// a project that may since have been renamed or removed.
struct RepoSettingsWindow: Scene {
    let model: AppModel

    /// The scene id. Opening this window from anywhere is `openWindow(id:value:)` with it.
    static let id = "repo-settings"

    var body: some Scene {
        WindowGroup(id: Self.id, for: Repo.ID.self) { $repoID in
            RepoSettingsWindowContent(repoID: repoID)
                .environment(model)
        }
        .defaultSize(width: RepoSettingsView.idealSize.width, height: RepoSettingsView.idealSize.height)
    }
}

/// The menu item that opens it.
///
/// Declared apart from the scene above and attached to the MAIN window instead, because SwiftUI
/// only realizes a scene's commands while one of that scene's own windows is key. Left on the
/// window group, the item that opens the window would only appear once it was already open.
@MainActor
struct RepoSettingsCommands: Commands {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    /// The project of the selected workspace, or the only sensible fallback: the first one.
    private var repo: Repo? {
        model.selectedWorkspace.flatMap(model.repo(for:)) ?? model.repos.first
    }

    var body: some Commands {
        // In File, under the block that adds a project, because that block is where a project is
        // already dealt with. An item added after `.appSettings` lands in the app menu beside
        // Settings, which reads better and is where a Mac user looks, but it is also where a
        // second Settings item invites the wrong click.
        CommandGroup(after: .newItem) {
            Button("Project Settings…") {
                guard let repo else { return }
                openWindow(id: RepoSettingsWindow.id, value: repo.id)
            }
            .keyboardShortcut(",", modifiers: [.command, .shift])
            .disabled(repo == nil)
        }
    }
}

/// Resolves the id to a project every time the database changes, so a project renamed or removed
/// in the main window does not leave a stale copy of itself sitting in this one.
private struct RepoSettingsWindowContent: View {
    let repoID: Repo.ID?

    @Environment(AppModel.self) private var app

    var body: some View {
        if let repo = app.repos.first(where: { $0.id == repoID }) {
            // Identified by the project, so switching to another one builds a fresh editor rather
            // than pouring a new project's settings into the state of the last.
            RepoSettingsView(repo: repo)
                .id(repo.id)
        } else {
            ContentUnavailableView(
                "This project is no longer in Bloom",
                systemImage: "folder.badge.questionmark",
                description: Text("It was removed, or this window was restored from a launch before it was.")
            )
            .frame(
                minWidth: RepoSettingsView.minimumSize.width,
                minHeight: RepoSettingsView.minimumSize.height
            )
            .background(Palette.windowBackground)
        }
    }
}

/// The gear on a project's row.
///
/// Lives here rather than in the sidebar so that mounting it anywhere is one line and needs no
/// `openWindow` of its own. It is drawn to match the `+` beside it: the same box, the same hover
/// treatment, lit rather than revealed, so a project header has one hover behaviour and not two.
struct RepoSettingsButton: View {
    let repo: Repo
    /// Passed by the row that owns the hover, so both controls light at the same moment.
    var isHighlighted: Bool = false

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: RepoSettingsWindow.id, value: repo.id)
        } label: {
            Label("Settings for \(repo.name)", systemImage: "gearshape")
                .labelStyle(.iconOnly)
                .font(Typo.label)
                .frame(
                    width: Metrics.headerButton.width,
                    height: Metrics.headerButton.height
                )
                .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
                .background(
                    isHighlighted ? Palette.hover : .clear,
                    in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHighlighted ? Palette.textPrimary : Palette.textSecondary)
        .help("Settings for \(repo.name)")
    }
}
