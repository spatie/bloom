import Foundation

extension Store {
    public func retiredRewindCheckpoints(sessionID: SessionID) throws -> [TurnCheckpoint] {
        guard let value = try setting("turn.rewind.retired.\(sessionID)") else { return [] }
        return try JSONDecoder().decode([TurnCheckpoint].self, from: Data(value.utf8))
    }

    public func queueRetiredCheckpoints(_ records: [TurnCheckpoint], sessionID: SessionID) throws {
        var current = try retiredRewindCheckpoints(sessionID: sessionID)
        let known = Set(current.map(\.id))
        current += records.filter { !known.contains($0.id) }
        try setSetting("turn.rewind.retired.\(sessionID)", String(decoding: JSONEncoder().encode(current), as: UTF8.self))
    }

    public func acknowledgeRetiredCheckpoints(_ ids: Set<GitSnapshotID>, sessionID: SessionID) throws {
        let retained = try retiredRewindCheckpoints(sessionID: sessionID).filter { !ids.contains($0.id) }
        try setSetting("turn.rewind.retired.\(sessionID)",
                       retained.isEmpty ? nil : String(decoding: JSONEncoder().encode(retained), as: UTF8.self))
    }
}
