import Foundation
import BloomCore

/// Looking for the artwork of projects that were added before Bloom knew how to look.
///
/// Detection runs when a project is added (see `WorkspaceManager.addRepo`), which leaves every
/// project added before that feature existed drawing its initials with `.undetected` stored
/// against it, and the settings window saying so out loud. Nothing was ever going to change that
/// except somebody visiting each project's settings window and pressing a button, so the launch
/// looks for them instead.
///
/// ## Nothing here is in front of anything
///
/// This starts at the very end of `bootstrap`, after the window has its data and `isLoaded` is
/// true, and it is never awaited. The walk itself is a detached task per project, so the only
/// main actor work is the two field write that follows each one. Detection measures about 15
/// milliseconds for a project on this machine, which would be unnoticeable in front of the first
/// frame and is still not worth putting there: it is a directory walk, its cost belongs to the
/// file system's cache rather than to the code, and ten projects on a cold cache is a different
/// number entirely.
///
/// Projects are searched one after another rather than all at once. There is no deadline to meet,
/// the badges can settle in as they are answered, and a burst of concurrent directory walks would
/// be the loudest thing the app does at launch for no gain at all.
///
/// ## What it is allowed to touch
///
/// `RepoIconRefresh` is the whole of that rule and is in the core with its tests. Short version:
/// a project nobody has looked at is searched, an icon the user chose and initials the user asked
/// for are never touched, and artwork Bloom found is looked at again only when the file it found
/// has gone or when the guess is one the ranking would no longer make. A search that finds nothing
/// is stored, so it happens once rather than on every launch, and `Find icon` in the project's
/// settings window is unaffected by any of it.
extension AppModel {
    func startProjectIconSearch() {
        iconSearchTask?.cancel()
        iconSearchTask = Task { [weak self] in
            await self?.searchForMissingProjectIcons()
        }
    }

    private func searchForMissingProjectIcons() async {
        guard let store else { return }
        let pending = RepoIconRefresh.toSearch(repos)
        guard !pending.isEmpty else { return }

        let started = Date()
        var found = 0
        for project in pending {
            guard !Task.isCancelled else { return }
            let path = project.path
            // Detached, because this walks directories and the sidebar is drawing.
            let candidate = await Task.detached(priority: .utility) {
                RepoIconDetector.detect(in: path)
            }.value
            guard !Task.isCancelled else { return }

            if await adopt(RepoIconAnswer(found: candidate), for: project, in: store) {
                found += candidate == nil ? 0 : 1
            }
        }
        Log.icons.info(
            """
            searched \(pending.count, privacy: .public) project(s) for artwork, \
            found \(found, privacy: .public), \
            in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms
            """
        )
    }

    /// Stores what the search answered, and puts it in front of the user.
    ///
    /// Two columns and no others. The value handed in was read before a directory walk, and
    /// `Store.upsert` writes every column of whatever it is given, so writing the whole thing back
    /// would carry a name, a colour, a sort order or a collapsed state back to what it was when
    /// the walk started. See `Store.update(repoID:)` and e47a3b7.
    ///
    /// The guard inside the closure is the same thing one level up: the row is read there, inside
    /// the store's actor, immediately before it is written, so a project whose icon somebody
    /// changed in the settings window while this was walking its folder is left exactly as they
    /// left it. A launch that overwrote a file somebody had just chosen would be the worst version
    /// of this feature.
    ///
    /// Returns whether anything was actually written.
    private func adopt(_ answer: RepoIconAnswer, for project: Repo, in store: Store) async -> Bool {
        let searchedSource = project.iconSource
        let searchedPath = project.iconPath
        let stored = try? await store.update(repoID: project.id) { row in
            guard row.iconSource == searchedSource, row.iconPath == searchedPath else { return }
            guard answer.changes(row) else { return }
            answer.apply(to: &row)
        }
        guard let row = stored ?? nil,
              row.iconPath == answer.iconPath, row.iconSource == answer.iconSource,
              answer.changes(project)
        else { return false }

        // Before the row is published, so the badge's first draw reads the new file rather than
        // whatever was cached against the old path.
        RepoIconArt.forget(searchedPath)
        RepoIconArt.forget(answer.iconPath)

        // The same two columns in memory, rather than a reload: `reload` republishes every project
        // and every workspace, which at this moment is a whole list diff to change one badge.
        adoptProjectIcon(answer.iconPath, source: answer.iconSource, forRepoID: project.id)
        return true
    }
}
