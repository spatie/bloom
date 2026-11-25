import Foundation

/// A continuation that was waiting on the allowance when Bloom quit, kept in the settings table
/// under one key per chat so the next launch can wait again.
///
/// The reset is kept as well as the hit. After a relaunch past it, the spent window has expired
/// from the quotas, and without the reset any reading stored before the quit would count as one
/// taken after it.
public struct SavedLimitResume: Sendable, Hashable, Codable {
    public static let keyPrefix = "limitResume."
    /// How many of a chat's last rows are read to check it still ends on the refused turn. The
    /// rows Claude Code stores after a result are a handful, so this is generous.
    public static let rowsToCheck = 50

    public let hitAt: Date
    public let notBefore: Date?

    public init(hitAt: Date, notBefore: Date?) {
        self.hitAt = hitAt
        self.notBefore = notBefore
    }

    public static func key(for sessionID: SessionID) -> String {
        keyPrefix + sessionID.rawValue
    }

    public var value: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Every saved wait out of the settings under `keyPrefix`. A value that does not decode is
    /// dropped, and with no wait to read the next launch cleans it up like any stale one.
    public static func all(in settings: [(key: String, value: String)]) -> [(sessionID: SessionID, saved: SavedLimitResume)] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return settings.compactMap { setting in
            guard setting.key.hasPrefix(keyPrefix),
                  let saved = try? decoder.decode(SavedLimitResume.self, from: Data(setting.value.utf8))
            else { return nil }
            return (SessionID(String(setting.key.dropFirst(keyPrefix.count))), saved)
        }
    }

    /// Whether the chat still ends on the refused turn, walking back from its newest row. Anything
    /// said since means the wait no longer applies, and sending "Continue" into it would be a
    /// message nobody asked for.
    public static func stillApplies(walkingBack rows: some Sequence<(kind: MessageKind, payload: Data)>) -> Bool {
        for row in rows {
            switch row.kind {
            case .system, .notice:
                continue
            case .result:
                guard case .result(let result)? = AgentEvent.decode(line: String(decoding: row.payload, as: UTF8.self))
                else { return false }
                return LimitResume.isLimitHit(result)
            default:
                return false
            }
        }
        return false
    }
}
