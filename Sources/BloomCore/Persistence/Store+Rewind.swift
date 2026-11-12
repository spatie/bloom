import Foundation

/// The store's half of a Claude chat rewind. See `ClaudeRewind`.
extension Store {
    /// Removes a chat's rows from `seq` on, which is what a rewind does to the transcript: the
    /// conversation Claude resumes no longer holds them either. Returns how many went.
    @discardableResult
    public func removeMessages(sessionID: SessionID, fromSeq seq: Int) throws -> Int {
        try db.run("DELETE FROM messages WHERE session_id = ? AND seq >= ?", [.text(sessionID), .int(Int64(seq))])
        return db.changedRowCount
    }
}
