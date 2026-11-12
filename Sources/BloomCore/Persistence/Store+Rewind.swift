import Foundation

/// The store's half of a Claude chat rewind. See `ClaudeRewind`.
extension Store {
    /// Removes a chat's rows from `seq` on, which is what a rewind does to the transcript: the
    /// conversation Claude resumes no longer holds them either.
    ///
    /// **Everything keyed by a row's seq goes with the rows**, because the next message is given
    /// `seq` again (`nextSeqLocked` is the highest left plus one). A turn checkpoint starting at
    /// a removed seq would otherwise hang its file footer on whatever answer arrives next, and a
    /// read marker past the cut would mark the new answers read before anybody saw them. One
    /// transaction, so a reader never finds the rows gone and their checkpoints still there.
    ///
    /// Answers the checkpoints it dropped, whose hidden snapshot refs the caller deletes: that is
    /// git work in the worktree, which the store has no business doing.
    @discardableResult
    public func removeMessages(sessionID: SessionID, fromSeq seq: Int) throws -> [TurnCheckpoint] {
        try db.transaction {
            try db.run("DELETE FROM messages WHERE session_id = ? AND seq >= ?", [.text(sessionID), .int(Int64(seq))])
            try db.run(
                "UPDATE sessions SET last_read_seq = ? WHERE id = ? AND last_read_seq >= ?",
                [.int(Int64(seq - 1)), .text(sessionID), .int(Int64(seq))]
            )
            let records = try turnCheckpoints(sessionID: sessionID)
            let dropped = records.filter { $0.startSeq >= seq }
            if !dropped.isEmpty {
                let kept = records.filter { $0.startSeq < seq }
                try setSetting(
                    "turn.checkpoints.\(sessionID)",
                    String(decoding: JSONEncoder().encode(kept), as: UTF8.self)
                )
            }
            return dropped
        }
    }
}
