import Foundation

/// Whether a page may put a file on this Mac, and how many.
///
/// **A download is a file arriving on the owner's disk, and a page can start one without a
/// click.** A link with a `download` attribute needs a press, but a response carrying
/// `Content-Disposition: attachment` does not: one line of script pointing an iframe at one is
/// enough, and a loop around that line is a folder full of rubbish or a disk with nothing left on
/// it. Safari answers this by asking the reader the first time a site wants to download anything;
/// Chrome answers it by blocking a page that starts several without a gesture.
///
/// Bloom answers it with `BrowserBurst`, the same counter that holds `window.open`, because it is
/// the same shape of problem and the same reasoning: a reader pressing a download button twice is
/// not to be asked about it, and a loop is to be stopped inside a second. Three in five seconds,
/// which is lower than the window limit because a person starts far fewer downloads than they
/// click links.
///
/// What that leaves is stated rather than glossed: a page can still put three files in the
/// reader's Downloads folder with no click at all. What stops those being dangerous is the rest of
/// the design and not this counter: they land in Downloads and never in a worktree, so a download
/// cannot dirty a diff or be committed; they never write over a file that is already there,
/// because `BrowserDownloadFile.filename` numbers around it; they carry the quarantine flag, so
/// Gatekeeper treats them as what they are; and the pane says what arrived rather than letting it
/// land in silence.
public struct BrowserDownloads: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case save
        /// Refused, and the reader has already been told about this run.
        case refuse
        /// Refused, and this is the one that says why.
        case refuseAndSay(BrowserNotice)
    }

    private var burst: BrowserBurst

    public init(limit: Int = 3, window: TimeInterval = 5) {
        burst = BrowserBurst(limit: limit, window: window)
    }

    /// `name` is the page, as `BrowserPageOrigin.name` gives it, and is only used in the sentence.
    public mutating func request(from name: String?, at now: Date = Date()) -> Decision {
        switch burst.take(at: now) {
        case .allowed: return .save
        case .refused: return .refuse
        case .refusedAndUnsaid: return .refuseAndSay(Self.notice(from: name))
        }
    }

    private static func notice(from name: String?) -> BrowserNotice {
        let who = name ?? "That page"
        return BrowserNotice(
            title: "Bloom stopped \(who) downloading more files",
            message: """
                This page started several downloads at once, which is what a page in a loop does. \
                Bloom kept the first few and refused the rest. What did arrive is in your \
                Downloads folder.
                """
        )
    }
}
