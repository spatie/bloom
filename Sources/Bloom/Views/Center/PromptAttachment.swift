import Foundation
import BloomCore

/// A file the next prompt carries.
///
/// It is deliberately not a piece of text in the draft. What the user dropped is a file, so the
/// composer keeps a file: the chip can name it, the hover card can draw it and the centre column
/// can open it, none of which is possible once the same thing has been flattened into a path
/// inside a sentence.
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

    /// The same picture under another name, which is what happens when the first one is taken.
    func named(_ name: String) -> AttachmentSource {
        guard case .image(let data, let format, _) = self else { return self }
        return .image(data, format: format, named: name)
    }

    /// What this will be called once it is a file in the worktree.
    var filename: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .image(_, _, let name): name
        }
    }
}

/// The rules about attachments that are pure: what the agent is told, where a copy goes, and what
/// an id looks like.
///
/// Split out from the views and from the file system on purpose. These are the parts worth
/// asserting on, and they are the parts that will move into `BloomCore` once the sending path is
/// free to be edited.
enum PromptAttachments {
    /// Where a copy lands inside the worktree.
    ///
    /// Inside, rather than in Bloom's application support directory, because the agent has to be
    /// able to read it. Claude Code will not read a path outside its working directory without
    /// asking, Bloom has nothing that can answer that question, and a turn that stalls on an
    /// unanswerable permission prompt is worse than no attachments at all. Inside the worktree the
    /// read is ordinary.
    ///
    /// Under `.bloom`, which is already Bloom's corner of a repository, and made invisible to git
    /// by `WorktreeScratch`. See that type for why an untracked folder here would be a bug rather
    /// than a detail.
    static let folder = WorktreeScratch.attachments

    /// The trailer the agent actually receives.
    ///
    /// The shape itself lives in `AttachmentTrailer`, in BloomCore, next to the reader that takes
    /// it back off again for the transcript. Two halves of one format, so neither can be changed
    /// without the other being in view, and so both can be asserted on.
    static func compose(text: String, attachments: [PromptAttachment]) -> String {
        AttachmentTrailer.compose(text: text, paths: attachments.map(\.path))
    }

    /// Six characters, in the alphabet a URL would accept.
    ///
    /// Short because the whole of it is read: it is a directory in the path chip above the file
    /// and in the prompt the agent is handed, and a UUID there is thirty six characters of noise
    /// in both places. Six is enough that two attachments in one worktree colliding is not
    /// something that happens.
    static func newShortID() -> String {
        let alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<6).map { _ in alphabet.randomElement() ?? "a" })
    }

    /// The name a copy is written under: the file's own, with anything that would change what the
    /// path means taken out.
    ///
    /// A slash would silently put the file somewhere else, and a leading dot would hide it from
    /// the person who came looking for it in Finder. Everything else is left alone, spaces and
    /// accents included, because the name is the one part of an attachment the user recognises.
    static func safeFilename(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Every leading dot, not just the first: `..` is a name git and Finder both refuse, and
        // one pass over a name of nothing but dots leaves another dot in front.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        guard !cleaned.isEmpty else { return "attachment" }
        return cleaned
    }

    /// Where a copy of `filename` goes, relative to the worktree.
    static func destination(filename: String, id: String) -> String {
        "\(folder)/\(id)/\(safeFilename(filename))"
    }
}
