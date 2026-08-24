import Foundation

/// Which projects are worth looking for an icon for, when the search is run over projects that
/// already exist rather than over one being added.
///
/// `RepoIconDetector` answers "what artwork does this folder have". This answers the question in
/// front of it: "is this a folder Bloom is allowed to go and look at again". They are separate
/// because the second one is entirely about what the user has already said, and the detector has
/// no opinion about that and should not grow one.
///
/// The reason this exists at all is that detection only ever ran when a project was added, so
/// every project added before that landed still draws its initials and has `.undetected` stored
/// against it forever. A sweep at launch closes that, and a sweep at launch is also the exact
/// shape of change that can quietly overrule somebody. Hence a rule that can be stated, and
/// tested, rather than a condition inside the startup path.
///
/// ## What is never touched
///
/// `.chosen` is a file the user named in an open panel. It is the last word by definition.
///
/// `.monogram` is the user asking for the initials back, and it is also where a search that found
/// nothing lands. Both of them mean the same thing to a sweep: this folder has been answered, do
/// not answer it again. Replacing initials somebody deliberately went and chose with a favicon
/// found in their `public` folder, at launch, without being asked, is the kind of change that
/// makes an app feel like it is fighting the person using it.
///
/// `.detected` is Bloom's own guess and is therefore the one that could be revisited, but a
/// project whose icon changes on a launch for no visible reason is a worse outcome than a project
/// showing artwork that is one commit out of date. A user learns the marks in their sidebar by
/// looking at them, so the bar for changing one is high. What clears that bar is the file being
/// **gone**: the badge has already fallen back to the initials by itself, because `RepoIconArt`
/// answers nil for a file it cannot read, so looking again cannot startle anybody. It can only
/// find the artwork where the project moved it to.
///
/// ## The other thing that clears it: a guess the ranking no longer stands behind
///
/// A stored guess is only as good as the ranking that made it, and a ranking that has since been
/// corrected leaves the wrong file on screen for ever. That is not hypothetical: the owner's own
/// `there-there` had `favicon-unread-1.svg` stored against it, which is the artwork the site
/// swaps into the browser tab to show an unread count, so the sidebar drew a green tile with a
/// red 1 on it. Fixing the ranking alone leaves the badge exactly where it was.
///
/// So one more case is looked at again: a stored file whose name has a word added to it, with the
/// plain one sitting beside it in the same folder under the same extension. That is a directory
/// listing and no file is read, `RepoIconDetector.hasPlainerName(than:among:)` is the whole of the
/// question, and it is deliberately not "the folder has something better in it now". A plainer
/// sibling of the same kind and format is one this project's own ranking would have preferred at
/// the time, so finding one means the pick was wrong when it was made rather than that the folder
/// moved on. Artwork simply appearing next to a mark is still not a reason to change it.
///
/// It is not a one time migration, and it does not need to be, because it settles by itself: the
/// search replaces the dressed up name with the plain one, and a plain name has no plainer sibling
/// to find. A project whose only artwork is `logo-dark.svg` is never in this case at all, since
/// there is nothing plainer beside it, so it is not walked on every launch either.
///
/// ## Why a missing folder is not a missing icon
///
/// Everything here is skipped for a project whose own directory is not there. An unmounted volume,
/// a folder being restored, a checkout on an external disk: none of those are the user changing
/// their mind, and a sweep that ran anyway would file `.monogram` against a project whose artwork
/// is perfectly intact and would never look again. `RepoIconArt` already declines to unset
/// anything for the same reason.
public enum RepoIconRefresh {
    /// Why a project is being looked at. Carried out of the rule rather than recomputed, so the
    /// caller can log which case it acted on without asking a second time.
    public enum Reason: String, Sendable, Hashable, CaseIterable {
        /// `.undetected`: nobody has ever looked in this folder. The case this feature is for.
        case neverLooked
        /// `.detected`, and the file that was found is not there any more.
        case artworkGone
        /// `.detected`, and what was found is the dressed up name with the plain one beside it.
        case plainerArtwork
    }

    /// Whether this project is one the sweep may look at, and why.
    ///
    /// `exists` and `contents` are parameters so the rule is testable without a directory tree
    /// behind every case. Nothing here reads a file's contents: that is the detector's half. The
    /// listing is only ever asked for the one directory a stored icon is already in.
    public static func reasonToSearch(
        _ repo: Repo,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        contents: (String) -> [String] = {
            (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
        }
    ) -> Reason? {
        // The folder first, so a project on a volume that is not mounted is skipped whatever its
        // stored state says. See the note above.
        guard exists((repo.path as NSString).expandingTildeInPath) else { return nil }

        switch repo.iconSource {
        case .undetected:
            return .neverLooked
        case .monogram, .chosen:
            return nil
        case .detected:
            guard let path = repo.iconPath else { return .artworkGone }
            guard exists(path) else { return .artworkGone }
            let directory = (path as NSString).deletingLastPathComponent
            let plainer = RepoIconDetector.hasPlainerName(
                than: (path as NSString).lastPathComponent,
                among: contents(directory)
            )
            return plainer ? .plainerArtwork : nil
        }
    }

    /// Every project the sweep should look at, in the order they were handed over.
    public static func toSearch(
        _ repos: [Repo],
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        contents: (String) -> [String] = {
            (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
        }
    ) -> [Repo] {
        repos.filter { reasonToSearch($0, exists: exists, contents: contents) != nil }
    }
}

/// What a search leaves behind, whether or not it found anything.
///
/// A search that finds nothing is a result and has to be stored as one, or a project with no
/// artwork in it is walked again on every launch for the rest of its life. It is stored as
/// `.monogram`, which is what adding a project already does with the same answer: the state means
/// "looked at, and the initials are the answer", and it is the state a sweep refuses to touch, so
/// one fruitless walk is the only walk.
///
/// The cost of that is real and worth writing down: `.monogram` cannot afterwards tell apart "we
/// found nothing" from "the user asked for the initials". Both are treated identically by
/// everything that reads it, and both should be, so the distinction would buy a column and pay for
/// nothing. The way back is the same for either of them and always has been: `Look again` in the
/// project's settings window runs the search on demand, from any state, and is not gated on this.
public struct RepoIconAnswer: Sendable, Hashable {
    public var iconPath: String?
    public var iconSource: RepoIconSource

    public init(found: RepoIconCandidate?) {
        iconPath = found?.path
        iconSource = found == nil ? .monogram : .detected
    }

    /// The two columns and nothing else, for `Store.update(repoID:)`. A whole `Repo` written back
    /// from before the walk would carry a name, a colour or a sort order back with it: see the
    /// note on `Store.upsert(_ repo:)` and e47a3b7.
    public func apply(to repo: inout Repo) {
        repo.iconPath = iconPath
        repo.iconSource = iconSource
    }

    /// Whether this answer is any different from what the project already has, so a sweep that
    /// re-found the same file writes nothing at all.
    public func changes(_ repo: Repo) -> Bool {
        repo.iconPath != iconPath || repo.iconSource != iconSource
    }
}
