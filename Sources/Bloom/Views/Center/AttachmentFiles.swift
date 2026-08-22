import Foundation
import AppKit
import BloomCore

/// Everything an attachment does to the disk: deciding whether a copy is needed, making it, and
/// keeping git blind to the ones Bloom made.
///
/// Nothing here touches the main actor, so a hundred megabyte copy runs where a copy belongs.
enum AttachmentFiles {
    /// The most Bloom will copy into a worktree for one attachment.
    ///
    /// A cap rather than a progress bar. Above this the honest answer is that an attachment is the
    /// wrong tool: a file that big is already somewhere the agent can be pointed at, and copying
    /// it would spend a gigabyte of the user's disk on a chip in a text box.
    static let maxByteCount = 100 * 1024 * 1024

    /// The most Bloom will take off a clipboard before it has looked at it.
    ///
    /// The cap above is on what gets written, and a pasted picture is not always what was read:
    /// TIFF is uncompressed, so a retina screenshot arrives as eighty megabytes and is written as
    /// five. Rejecting it on the way in would refuse the ordinary case, so the size that counts is
    /// the size after rewriting. This second, much higher ceiling is only about the rewriting
    /// itself, which has to decode the whole picture into memory: past it, there is nothing worth
    /// spending a gigabyte of somebody's RAM to find out.
    static let maxPastedByteCount = 1024 * 1024 * 1024

    enum Failure: LocalizedError {
        case unreadable(String)
        case tooLarge(String, Int)
        case tooLargeToPaste(String, Int)
        case copyFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                "Bloom could not read \(name)."
            case .tooLarge(let name, let bytes):
                """
                \(name) is \(Self.size(bytes)), and an attachment is copied into the worktree. \
                Mention it with @ instead, or move it into the worktree yourself.
                """
            case .tooLargeToPaste(let name, let bytes):
                // Deliberately not the sentence above. There is no file to mention with @ and
                // nothing to move into the worktree: what is on the clipboard is bytes, and the
                // only way to make them smaller is to save them somewhere first.
                """
                That image is \(Self.size(bytes)), which is more than Bloom will write into a \
                worktree (\(Self.size(maxByteCount))). Save it to a file and attach that, or \
                paste a smaller one. It would have been written as \(name).
                """
            case .copyFailed(let name, let reason):
                "\(name) could not be copied into the worktree. \(reason)"
            }
        }

        private static func size(_ bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    // MARK: - Attaching

    /// Turns one dropped, picked or pasted thing into an attachment of `workspace`.
    ///
    /// A file already inside the worktree is referenced where it lies: the agent can read it, the
    /// review tab can already show it, and copying it would put a second stale version of the
    /// user's own work next to the first. Everything else is copied in, because a path outside the
    /// worktree is a path the agent may not be allowed to read.
    static func attach(_ source: AttachmentSource, workspace: String) throws -> PromptAttachment {
        switch source {
        case .file(let url):
            try attach(file: url, workspace: workspace)
        case .image(let data, let format, let name):
            try attach(image: data, format: format, named: name, workspace: workspace)
        case .text(let body, let name):
            try attach(bytes: Data(body.utf8), named: name, workspace: workspace)
        }
    }

    /// Bytes Bloom made itself, written straight out under the name it chose.
    ///
    /// No size ceiling of its own: everything that arrives here was trimmed to a budget before it
    /// was handed over, by whoever decided what was worth keeping. See
    /// `CheckFailureHandoff.excerpt` for the one caller there is.
    private static func attach(
        bytes: Data, named name: String, workspace: String
    ) throws -> PromptAttachment {
        let id = PromptAttachments.newShortID()
        let relative = PromptAttachments.destination(filename: name, id: id)
        let destination = URL(filePath: (workspace as NSString).appendingPathComponent(relative))

        do {
            try prepare(destination, in: workspace)
            try bytes.write(to: destination, options: .atomic)
        } catch {
            throw Failure.copyFailed(name, error.localizedDescription)
        }

        return PromptAttachment(id: id, path: relative, isCopy: true, byteCount: bytes.count)
    }

    private static func attach(file url: URL, workspace: String) throws -> PromptAttachment {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              FileManager.default.isReadableFile(atPath: path) else {
            throw Failure.unreadable(name)
        }
        // A folder is a legitimate thing to talk to an agent about and a hopeless thing to attach:
        // there is nothing to preview, nothing to open, and no honest size. Mentioning it with @
        // says the same thing without pretending it is one file.
        guard !isDirectory.boolValue else { throw Failure.unreadable(name) }

        let bytes = byteCount(of: path)

        if let relative = relativePath(of: path, in: workspace) {
            return PromptAttachment(path: relative, source: path, isCopy: false, byteCount: bytes)
        }

        guard bytes <= maxByteCount else { throw Failure.tooLarge(name, bytes) }

        let id = PromptAttachments.newShortID()
        let relative = PromptAttachments.destination(filename: name, id: id)
        let destination = URL(filePath: (workspace as NSString).appendingPathComponent(relative))

        do {
            try prepare(destination, in: workspace)
            try FileManager.default.copyItem(at: URL(filePath: path), to: destination)
        } catch {
            throw Failure.copyFailed(name, error.localizedDescription)
        }

        return PromptAttachment(
            id: id, path: relative, source: path, isCopy: true, byteCount: bytes
        )
    }

    private static func attach(
        image pasted: Data, format: PastedImageFormat, named name: String, workspace: String
    ) throws -> PromptAttachment {
        guard pasted.count <= maxPastedByteCount else {
            throw Failure.tooLargeToPaste(name, pasted.count)
        }

        let (data, filename) = readable(pasted, format: format, named: name)

        guard data.count <= maxByteCount else { throw Failure.tooLargeToPaste(filename, data.count) }

        let id = PromptAttachments.newShortID()
        let relative = PromptAttachments.destination(filename: filename, id: id)
        let destination = URL(filePath: (workspace as NSString).appendingPathComponent(relative))

        do {
            try prepare(destination, in: workspace)
            try data.write(to: destination, options: .atomic)
        } catch {
            throw Failure.copyFailed(filename, error.localizedDescription)
        }

        return PromptAttachment(path: relative, isCopy: true, byteCount: data.count)
    }

    /// A pasted picture as it is worth putting on disk, and what to call it once it is.
    ///
    /// TIFF is what the pasteboard offers when nothing better was put on it, and it is worth
    /// rewriting twice over. It is uncompressed, so the same screenshot is often ten or twenty
    /// times the size of the PNG of it, and every one of those megabytes is copied into the user's
    /// checkout. And it is the one image format an agent is unlikely to be able to open at all, so
    /// the rewrite is the difference between a screenshot the agent can look at and one it can only
    /// report as an unreadable file. What it costs is a decode and an encode of one picture, on a
    /// background task, once.
    ///
    /// PNG and JPEG are left exactly as they arrived. Both are already compressed, re-encoding a
    /// JPEG would throw away detail for nothing, and bytes that are not touched cannot be corrupted.
    ///
    /// A rewrite that does not work keeps the original bytes and takes the original extension back,
    /// because a TIFF written under a `.png` name is worse than a TIFF: everything that opens it
    /// goes by the name.
    private static func readable(
        _ data: Data, format: PastedImageFormat, named name: String
    ) -> (Data, String) {
        guard format.isWorthReencoding else { return (data, name) }

        guard let representation = NSBitmapImageRep(data: data),
              let png = representation.representation(using: .png, properties: [:]) else {
            let base = (name as NSString).deletingPathExtension
            return (data, "\(base).\(format.fileExtension)")
        }
        return (png, name)
    }

    // MARK: - Handing a staged draft over

    /// Moves attachments that were staged before the worktree existed into the worktree they were
    /// written for, and answers with the ones that arrived.
    ///
    /// A move rather than a copy, and no path is rewritten: `AttachmentStaging` lays a draft out
    /// under exactly the relative path the attachment will have in the worktree, so this only has
    /// to put the same tree in its real place. Anything that fails to move is dropped from the
    /// answer rather than reported, because the prompt is composed from what comes back: naming a
    /// path the agent cannot read is worse than sending one attachment fewer.
    static func adopt(
        _ attachments: [PromptAttachment], from staging: String, into workspace: String
    ) -> [PromptAttachment] {
        guard !attachments.isEmpty else { return [] }
        shield(workspace: workspace)

        return attachments.filter { attachment in
            let from = attachment.url(in: staging)
            let to = attachment.url(in: workspace)
            guard FileManager.default.fileExists(atPath: from.path) else { return false }
            do {
                try FileManager.default.createDirectory(
                    at: to.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: from, to: to)
                return true
            } catch {
                return false
            }
        }
    }

    /// Takes a copy back off the disk. Only ever called for a copy Bloom made and that has not
    /// been sent, so there is nothing on the other side of it that could still be reading.
    static func discard(_ attachment: PromptAttachment, workspace: String) {
        guard attachment.isCopy else { return }
        let file = attachment.url(in: workspace)
        // The whole id folder, not just the file: the folder exists for this one attachment and
        // an empty one left behind is litter that git cannot report and nobody will ever remove.
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    // MARK: - Keeping git out of it

    private static func prepare(_ destination: URL, in workspace: String) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        shield(workspace: workspace)
    }

    /// Makes the attachments folder invisible to git, which is not a nicety: Bloom's whole premise
    /// is that a workspace's diff is exactly what the agent did. An untracked folder of screenshots
    /// would show up in the changed file list, in the sidebar's counts, in anything the agent runs
    /// `git status` in, and eventually in a commit.
    ///
    /// The arrangement itself is `WorktreeScratch`, in BloomCore, because attachments are not the
    /// only thing Bloom writes into somebody else's checkout and the rule has to be one rule. See
    /// that type for why it is a `.gitignore` inside the folder rather than `.git/info/exclude`.
    static func shield(workspace: String) {
        WorktreeScratch.shield(WorktreeScratch.attachments, in: workspace)
    }

    // MARK: - Paths

    /// The path relative to the worktree, or nil when the file is somewhere else entirely.
    ///
    /// Symlinks are resolved on both sides before comparing. On this platform they have to be:
    /// `/tmp` is a link to `/private/tmp`, so a file dragged out of a temporary folder would
    /// otherwise read as being outside a worktree that contains it, or the other way round.
    static func relativePath(of path: String, in workspace: String) -> String? {
        let file = URL(filePath: path).resolvingSymlinksInPath().path
        let root = URL(filePath: workspace).resolvingSymlinksInPath().path
        guard file.hasPrefix(root + "/") else { return nil }
        return String(file.dropFirst(root.count + 1))
    }

    static func byteCount(of path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int ?? 0
    }
}
