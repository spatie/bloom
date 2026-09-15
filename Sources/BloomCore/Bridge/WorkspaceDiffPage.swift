import Foundation

/// One page of a workspace's diff, and the cursor that finds the next.
///
/// `ChatTranscriptPage` is the model, and the ceiling is the same 32,000 characters for the same
/// reason: a tool result goes straight into a model's context, and a branch that rewrote a lock
/// file is a diff of megabytes.
///
/// ## What the cursor is bound to
///
/// A chat is append only, so a sequence number stays true between two reads. A diff is not: an
/// agent in that workspace saves a file between page one and page two, every offset after the edit
/// moves, and a reader following an offset would stitch half of one diff to half of another
/// without anything looking wrong. So the cursor carries a fingerprint of the text it was cut
/// from, and of the path that narrowed it, and a page is only served from a diff that still
/// matches. The workspace is in it as well, so a cursor cannot be carried to another workspace
/// whose diff happens to match.
///
/// ## Why a page ends on a line
///
/// Cutting at exactly the limit would leave a hunk line split across two answers, and a model
/// reading a page reads it as a diff. The cut goes back to the last line break inside the limit,
/// and only falls back to the hard limit when a single line is longer than a page, which a
/// minified file does produce. Nothing is lost either way: the next page starts where this ended.
enum WorkspaceDiffPage {
    static let characterLimit = 32_000

    struct Cursor: Equatable {
        var workspaceID: WorkspaceID
        var fingerprint: String
        var offset: Int

        init(workspaceID: WorkspaceID, fingerprint: String, offset: Int) {
            self.workspaceID = workspaceID
            self.fingerprint = fingerprint
            self.offset = offset
        }

        init?(_ raw: String, workspaceID: WorkspaceID) {
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == workspaceID.rawValue, !parts[1].isEmpty,
                  let offset = Int(parts[2]), offset >= 0 else { return nil }
            self.init(workspaceID: workspaceID, fingerprint: String(parts[1]), offset: offset)
        }

        var rawValue: String { "\(workspaceID.rawValue):\(fingerprint):\(offset)" }
    }

    struct Page: Equatable {
        var text: String
        var offset: Int
        var complete: Bool
        var nextCursor: Cursor?
    }

    /// The diff moved, or the cursor was cut for a different path.
    struct StaleCursor: Error, Equatable {}

    /// FNV-1a over the path and the text. Written out rather than taken from `Hasher`, which is
    /// seeded afresh in every process, so a cursor handed out before the app restarted would be
    /// refused for no reason the reader could see. It is not a security boundary: nothing here is
    /// secret, and a collision costs a page stitched from two diffs, which is the failure this
    /// guards against and not a worse one.
    static func fingerprint(diff: String, path: String?) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array((path ?? "").utf8) + [0] + Array(diff.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func make(
        diff: String,
        path: String?,
        workspaceID: WorkspaceID,
        cursor: Cursor?,
        limit: Int = characterLimit
    ) throws -> Page {
        let fingerprint = fingerprint(diff: diff, path: path)
        let offset = cursor?.offset ?? 0
        if let cursor {
            guard cursor.fingerprint == fingerprint, cursor.workspaceID == workspaceID,
                  offset <= diff.count else { throw StaleCursor() }
        }

        let rest = diff.dropFirst(offset)
        guard rest.count > limit else {
            return Page(text: String(rest), offset: offset, complete: true, nextCursor: nil)
        }

        var chunk = rest.prefix(limit)
        if let lineEnd = chunk.lastIndex(where: \.isNewline) {
            chunk = chunk[...lineEnd]
        }
        return Page(
            text: String(chunk),
            offset: offset,
            complete: false,
            nextCursor: Cursor(workspaceID: workspaceID, fingerprint: fingerprint, offset: offset + chunk.count)
        )
    }
}
