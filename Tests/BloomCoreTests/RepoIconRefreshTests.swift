import Testing
import Foundation
@testable import BloomCore

/// Which projects a launch is allowed to go looking for artwork for.
///
/// Detection used to run only when a project was added, so every project added before it existed
/// draws its initials forever. A sweep at launch fixes that and is also the one shape of change
/// that can overrule somebody silently, which is why the rule is here rather than inside the
/// startup path: the interesting cases are all about what the user has already said, and none of
/// them are visible in a screenshot.
///
/// No directories are created. The rule's only question about the file system is "is this there",
/// which is a parameter, so every case below is stated rather than arranged.
@Suite("Looking again for a project's icon")
struct RepoIconRefreshTests {
    /// A project at a path that the `exists` closures below all agree is present.
    private func project(
        _ source: RepoIconSource,
        icon: String? = nil,
        path: String = "/projects/bloom"
    ) -> Repo {
        Repo(name: "bloom", path: path, iconPath: icon, iconSource: source)
    }

    /// Everything is where it says it is.
    private let everything: (String) -> Bool = { _ in true }
    /// The folder is there and nothing inside it is.
    private let folderOnly: (String) -> Bool = { $0 == "/projects/bloom" }

    // MARK: - The case this is for

    @Test("a project nobody has ever looked at is searched")
    func neverLooked() {
        #expect(RepoIconRefresh.reasonToSearch(project(.undetected), exists: everything) == .neverLooked)
    }

    @Test("a project added before Bloom looked for icons is searched even with a stale path on it")
    func neverLookedWithAPath() {
        let stale = project(.undetected, icon: "/projects/bloom/public/favicon.svg")
        #expect(RepoIconRefresh.reasonToSearch(stale, exists: everything) == .neverLooked)
    }

    @Test("a guess the ranking would no longer make is looked at again, once")
    func plainerArtwork() {
        // The owner's own case: `favicon-unread-1.svg` stored against a folder that has had
        // `favicon.svg` in it all along. Fixing the ranking leaves the badge where it is, so the
        // stored guess has to be one the sweep is allowed to look past.
        let badged = project(.detected, icon: "/projects/bloom/public/favicon-unread-1.svg")
        let publicFolder = [
            "favicon.svg", "favicon.ico", "favicon-unread-1.svg", "favicon-unread-1.ico",
            "site.webmanifest", "index.php",
        ]
        #expect(
            RepoIconRefresh.reasonToSearch(badged, exists: everything, contents: { _ in publicFolder })
                == .plainerArtwork
        )

        // And it settles by itself. Once the search has stored the plain one, there is nothing
        // plainer beside it, so the next launch leaves the project alone.
        let plain = project(.detected, icon: "/projects/bloom/public/favicon.svg")
        #expect(
            RepoIconRefresh.reasonToSearch(plain, exists: everything, contents: { _ in publicFolder })
                == nil
        )

        // A project whose only artwork is the dressed up file is not in this case at all, so it is
        // not walked on every launch to be told the same thing.
        let onlyDark = project(.detected, icon: "/projects/bloom/assets/logo-dark.svg")
        #expect(
            RepoIconRefresh.reasonToSearch(onlyDark, exists: everything, contents: { _ in ["logo-dark.svg"] })
                == nil
        )

        // Nor is a plain sibling in a better format a reason. That is artwork that has appeared
        // since, which is the thing this rule exists to not react to.
        #expect(
            RepoIconRefresh.reasonToSearch(
                project(.detected, icon: "/projects/bloom/public/favicon-unread.png"),
                exists: everything,
                contents: { _ in ["favicon-unread.png", "favicon.svg"] }
            ) == nil
        )
    }

    // MARK: - What must survive a launch untouched

    @Test("a file the user chose is never looked past")
    func chosenIsTheLastWord() {
        let chosen = project(.chosen, icon: "/pictures/mark.svg")
        #expect(RepoIconRefresh.reasonToSearch(chosen, exists: everything) == nil)
        // Not even when the picture they named has gone. Unsetting it would be Bloom deciding
        // something about a file it was told to use, and the badge already falls back on its own.
        #expect(RepoIconRefresh.reasonToSearch(chosen, exists: folderOnly) == nil)
    }

    @Test("initials the user asked for are never replaced with a favicon")
    func monogramIsNeverOverruled() {
        #expect(RepoIconRefresh.reasonToSearch(project(.monogram), exists: everything) == nil)
    }

    @Test("artwork Bloom found and can still read is left exactly as it is")
    func detectedAndPresentIsLeftAlone() {
        let detected = project(.detected, icon: "/projects/bloom/public/favicon.svg")
        #expect(RepoIconRefresh.reasonToSearch(detected, exists: everything) == nil)
    }

    // MARK: - The one case worth a second look

    @Test("artwork that has gone is looked for again")
    func detectedAndGoneIsSearched() {
        let detected = project(.detected, icon: "/projects/bloom/public/favicon.svg")
        #expect(RepoIconRefresh.reasonToSearch(detected, exists: folderOnly) == .artworkGone)
    }

    @Test("a project marked as having artwork with no path to it is looked for again")
    func detectedWithNoPathIsSearched() {
        #expect(RepoIconRefresh.reasonToSearch(project(.detected), exists: everything) == .artworkGone)
    }

    // MARK: - A folder that is not there

    /// An unmounted volume is not the user changing their mind. Searching anyway would file
    /// `.monogram` against a project whose artwork is intact, and `.monogram` is never searched
    /// again, so one launch with an external disk asleep would cost the icon permanently.
    @Test("nothing is searched in a folder that is not there", arguments: RepoIconSource.allCases)
    func aMissingFolderIsSkipped(source: RepoIconSource) {
        let away = project(source, icon: "/volumes/work/bloom/favicon.svg", path: "/volumes/work/bloom")
        #expect(RepoIconRefresh.reasonToSearch(away, exists: { _ in false }) == nil)
    }

    @Test("a path written with a tilde is asked about as the folder it means")
    func homeRelativePathsAreExpanded() {
        let repo = Repo(name: "bloom", path: "~/dev/bloom", iconSource: .undetected)
        var asked: [String] = []
        let reason = RepoIconRefresh.reasonToSearch(repo) { path in
            asked.append(path)
            return true
        }
        #expect(reason == .neverLooked)
        #expect(asked == [(("~/dev/bloom") as NSString).expandingTildeInPath])
        #expect(!asked[0].contains("~"))
    }

    // MARK: - A list of them

    @Test("a sweep takes the two that need it and leaves the two that do not")
    func theListIsFiltered() {
        let repos = [
            project(.undetected, path: "/projects/a"),
            project(.chosen, icon: "/pictures/mark.svg", path: "/projects/b"),
            project(.monogram, path: "/projects/c"),
            project(.detected, icon: "/projects/d/gone.png", path: "/projects/d"),
            project(.detected, icon: "/projects/e/favicon.svg", path: "/projects/e"),
        ]
        let searched = RepoIconRefresh.toSearch(repos) { path in
            !path.hasSuffix("gone.png")
        }
        #expect(searched.map(\.path) == ["/projects/a", "/projects/d"])
    }

    // MARK: - What a search leaves behind

    /// The whole point of storing something for a search that found nothing: a project with no
    /// artwork in it must not be walked again on every launch for the rest of its life.
    @Test("a search that finds nothing is remembered, and is not searched a second time")
    func nothingFoundIsAnAnswer() {
        var repo = project(.undetected)
        let answer = RepoIconAnswer(found: nil)
        #expect(answer.iconPath == nil)
        #expect(answer.iconSource == .monogram)

        answer.apply(to: &repo)
        #expect(!repo.hasIcon)
        #expect(RepoIconRefresh.reasonToSearch(repo, exists: everything) == nil)
    }

    @Test("a search that finds something stores it as Bloom's own guess rather than as a choice")
    func somethingFoundIsStoredAsDetected() {
        var repo = project(.undetected)
        let found = RepoIconCandidate(
            path: "/projects/bloom/public/favicon.svg", format: .svg, origin: .favicon, pixels: 0
        )
        let answer = RepoIconAnswer(found: found)
        answer.apply(to: &repo)

        #expect(repo.iconPath == "/projects/bloom/public/favicon.svg")
        #expect(repo.iconSource == .detected)
        #expect(repo.hasIcon)
        // Still Bloom's guess, so the file going missing is grounds for looking again, and a file
        // that is there is not.
        #expect(RepoIconRefresh.reasonToSearch(repo, exists: everything) == nil)
        #expect(RepoIconRefresh.reasonToSearch(repo, exists: folderOnly) == .artworkGone)
    }

    @Test("an answer only writes when it is different from what the project already has")
    func anUnchangedAnswerWritesNothing() {
        let found = RepoIconCandidate(
            path: "/projects/bloom/public/favicon.svg", format: .svg, origin: .favicon, pixels: 0
        )
        let same = project(.detected, icon: "/projects/bloom/public/favicon.svg")
        #expect(!RepoIconAnswer(found: found).changes(same))
        #expect(RepoIconAnswer(found: nil).changes(same))
        #expect(RepoIconAnswer(found: found).changes(project(.undetected)))
    }

    /// Only the two columns, because the value being written back was read before a directory
    /// walk that anything else could have written during. See `Store.update(repoID:)`.
    @Test("applying an answer changes nothing else about the project")
    func applyingTouchesOnlyTheIcon() {
        var repo = Repo(
            id: RepoID("repo-1"),
            name: "Bloom",
            path: "/projects/bloom",
            defaultBranch: "trunk",
            accent: "FF3B30",
            sortOrder: 4,
            collapsed: true,
            iconSource: .undetected
        )
        let before = repo
        RepoIconAnswer(found: nil).apply(to: &repo)

        #expect(repo.id == before.id)
        #expect(repo.name == before.name)
        #expect(repo.path == before.path)
        #expect(repo.defaultBranch == before.defaultBranch)
        #expect(repo.accent == before.accent)
        #expect(repo.sortOrder == before.sortOrder)
        #expect(repo.collapsed == before.collapsed)
        #expect(repo.createdAt == before.createdAt)
    }
}
