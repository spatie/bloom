import Foundation
import BloomCore

/// What is known about a file the next prompt carries.
///
/// The draft is what says the prompt carries it. A path written into the text at the caret is the
/// whole record of that, because it is the only record that survives being edited: see
/// `AttachmentDraft`. This is what the composer knows *besides* the path, and every field is
/// either something the path cannot say or something it would cost a trip to the disk to ask.
///
/// Nothing here is required to draw a chip, open a file or send a turn. A draft restored after a
/// relaunch whose records were lost still names its files, still draws them and still sends them,
/// on the strength of the paths alone.
///
/// The path is relative to the worktree because that is where the agent is standing. Every agent
/// Bloom runs is spawned with the worktree as its working directory, so a relative path inside it
/// is the one reference that needs no special casing per agent and no permission to read a
/// directory the agent was not given.
struct PromptAttachment: Identifiable, Hashable, Codable, Sendable {
    var id: String = PromptAttachments.newShortID()
    /// Where the agent will find it, relative to the worktree.
    var path: String
    /// Where it came from on this Mac. Empty for something pasted out of the clipboard, which
    /// never had a file of its own. Kept so the same file dropped twice is recognised as the same
    /// attachment rather than copied in again under a second id.
    var source: String = ""
    /// True when Bloom made this copy under `.bloom/attachments`, which is what makes removing the
    /// chip also delete the file. A file that was already in the worktree is only ever referenced,
    /// so taking its chip off must not touch the user's work.
    var isCopy: Bool
    var byteCount: Int = 0

    var filename: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }

    func url(in worktree: String) -> URL {
        URL(filePath: (worktree as NSString).appendingPathComponent(path))
    }

    /// An attachment as it survives in a transcript, where the prompt text is all that was kept
    /// and a path is all it named.
    ///
    /// Identified by that path rather than by a fresh short id, so a row redrawn on every streamed
    /// token hands `ForEach` the same identity each time instead of a new one. The other fields
    /// are the honest answers for something Bloom is only reading back: it is not a copy this
    /// prompt is responsible for, and its size is whatever the file on disk says now.
    static func sent(path: String) -> PromptAttachment {
        PromptAttachment(id: path, path: path, isCopy: false)
    }
}

/// Where an attachment came from, before it is a file Bloom can point at.
///
/// Three doors lead here and they hand over different things: the paperclip and a drag give a
/// file that already exists, the clipboard can give bytes that never did. Naming both means the
/// copying rules are written once instead of three times.
enum AttachmentSource: Hashable, Sendable {
    case file(URL)
    /// A picture off a clipboard, which is bytes, a format and nothing else: a screenshot that
    /// was copied rather than saved has never had a file or a name. The name it earns is decided
    /// where the rest of the prompt's attachments are known, so two pastes in the same second do
    /// not arrive reading alike, and the format is carried rather than guessed back out of that
    /// name, so writing it can tell a picture worth rewriting from one that is already compressed.
    case image(Data, format: PastedImageFormat, named: String)
    /// Words Bloom generated that the agent is meant to read as a file: a CI log fetched for a
    /// failed check, and whatever follows it. A file rather than a paragraph pasted into the
    /// prompt, because the useful part of a log is thousands of lines long, and a draft that
    /// cannot be scrolled past is a draft nobody can edit before sending.
    case text(String, named: String)

    /// The same thing under another name, which is what happens when the first one is taken.
    func named(_ name: String) -> AttachmentSource {
        switch self {
        case .file: self
        case .image(let data, let format, _): .image(data, format: format, named: name)
        case .text(let body, _): .text(body, named: name)
        }
    }

    /// What this will be called once it is a file in the worktree.
    var filename: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .image(_, _, let name): name
        case .text(_, let name): name
        }
    }
}
