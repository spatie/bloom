import Foundation

/// One frame off Mailpit's `api/events` websocket.
///
/// Every frame is `{"Type": "...", "Data": ...}`, and these are the types Mailpit v1.31 sends, read
/// off its `websockets.Broadcast` calls. Anything else (a client error notice, a type a later
/// Mailpit adds) is `.other` and changes nothing, so a new kind of frame costs a missed update
/// rather than a dropped connection.
public enum MailpitEvent: Equatable, Sendable {
    /// A message arrived, with the same summary a list page carries.
    case new(MailpitSummary)
    /// A message was marked read or unread, or retagged. `isRead` is nil for a retag, which says
    /// nothing about reading.
    case update(MailpitMessageID, isRead: Bool?)
    case delete(MailpitMessageID)
    /// The whole mailbox was emptied.
    case truncate
    /// Messages went in bulk, by age or by a search, with no list of which. The only answer is to
    /// read the list again.
    case prune
    /// The mailbox's own counts, sent after every change.
    case stats(total: Int, unread: Int)
    case other

    public static func parse(_ text: String) -> MailpitEvent? {
        parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) -> MailpitEvent? {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope<Ignored>.self, from: data) else { return nil }
        switch envelope.type {
        case "new":
            guard let summary = try? decoder.decode(Envelope<MailpitSummary>.self, from: data).data else { return nil }
            return .new(summary)
        case "update":
            guard let change = try? decoder.decode(Envelope<Change>.self, from: data).data else { return nil }
            return .update(change.id, isRead: change.read)
        case "delete":
            guard let change = try? decoder.decode(Envelope<Change>.self, from: data).data else { return nil }
            return .delete(change.id)
        case "truncate":
            return .truncate
        case "prune":
            return .prune
        case "stats":
            guard let stats = try? decoder.decode(Envelope<Stats>.self, from: data).data else { return nil }
            return .stats(total: stats.total, unread: stats.unread)
        default:
            return .other
        }
    }

    private struct Envelope<Payload: Decodable>: Decodable {
        var type: String
        var data: Payload?
        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case data = "Data"
        }
    }

    private struct Ignored: Decodable {
        init(from decoder: any Decoder) throws {
            // The first pass reads the type and nothing else, whatever shape the data has.
        }
    }

    private struct Change: Decodable {
        var id: MailpitMessageID
        var read: Bool?
        enum CodingKeys: String, CodingKey {
            case id = "ID"
            case read = "Read"
        }
    }

    private struct Stats: Decodable {
        var total: Int
        var unread: Int
        enum CodingKeys: String, CodingKey {
            case total = "Total"
            case unread = "Unread"
        }
    }
}
