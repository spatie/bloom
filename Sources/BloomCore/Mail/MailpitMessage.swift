import Foundation

/// What Mailpit says about mail, decoded from its v1 API.
///
/// Mailpit's JSON uses Go's field names, capitalised, so every type here spells its keys out. The
/// shapes were read off Mailpit v1.31's `internal/storage/structs.go` and checked against a running
/// copy. Fields Bloom does not draw are left out, and anything Mailpit leaves null (an empty
/// `Cc` arrives as `null`, not `[]`) decodes as empty rather than failing the whole page.

/// A name and an address, as one header names a person.
public struct MailpitAddressee: Equatable, Hashable, Sendable, Decodable {
    public var name: String
    public var address: String

    public init(name: String = "", address: String) {
        self.name = name
        self.address = address
    }

    /// The name when the message gave one, and the address when it did not.
    public var display: String { name.isEmpty ? address : name }

    /// `Name <address>`, or the bare address, which is how a header line reads.
    public var full: String { name.isEmpty ? address : "\(name) <\(address)>" }

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case address = "Address"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
    }
}

/// One row of the list: enough to draw it, and nothing that needs the body.
public struct MailpitSummary: Equatable, Identifiable, Sendable, Decodable {
    public var id: MailpitMessageID
    public var isRead: Bool
    public var from: MailpitAddressee?
    public var to: [MailpitAddressee]
    public var subject: String
    public var created: Date
    /// How many attachments, which is all the list needs to decide on a paperclip.
    public var attachments: Int
    public var snippet: String

    public init(
        id: MailpitMessageID, isRead: Bool = false, from: MailpitAddressee? = nil,
        to: [MailpitAddressee] = [], subject: String = "", created: Date = .distantPast,
        attachments: Int = 0, snippet: String = ""
    ) {
        self.id = id
        self.isRead = isRead
        self.from = from
        self.to = to
        self.subject = subject
        self.created = created
        self.attachments = attachments
        self.snippet = snippet
    }

    private enum CodingKeys: String, CodingKey {
        case id = "ID"
        case isRead = "Read"
        case from = "From"
        case to = "To"
        case subject = "Subject"
        case created = "Created"
        case attachments = "Attachments"
        case snippet = "Snippet"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(MailpitMessageID.self, forKey: .id)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        from = try container.decodeIfPresent(MailpitAddressee.self, forKey: .from)
        to = try container.decodeIfPresent([MailpitAddressee].self, forKey: .to) ?? []
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        created = MailpitDate.parse(try container.decodeIfPresent(String.self, forKey: .created))
        attachments = try container.decodeIfPresent(Int.self, forKey: .attachments) ?? 0
        snippet = try container.decodeIfPresent(String.self, forKey: .snippet) ?? ""
    }
}

/// One file carried by a message.
public struct MailpitAttachment: Equatable, Identifiable, Sendable, Decodable {
    /// The MIME part, which is what Mailpit's download route takes.
    public var part: String
    public var fileName: String
    public var contentType: String
    public var size: Int

    public var id: String { part }

    public init(part: String, fileName: String, contentType: String = "", size: Int = 0) {
        self.part = part
        self.fileName = fileName
        self.contentType = contentType
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case part = "PartID"
        case fileName = "FileName"
        case contentType = "ContentType"
        case size = "Size"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        part = try container.decode(String.self, forKey: .part)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType) ?? ""
        size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
    }

    /// What a file is called on disk: its own name, or one made from the part when the message
    /// gave it none, which a calendar invite or an inline image often does not.
    public var savedName: String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name with a slash in it would be a path, and a message is not allowed to choose where
        // on this Mac a file lands.
        let safe = trimmed.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return safe.isEmpty || safe == "." || safe == ".." ? "attachment-\(part)" : safe
    }

    /// `savedName`, or the first of `name 2.ext`, `name 3.ext` and on that `isTaken` turns down,
    /// which is how Finder names a second copy in Downloads rather than writing over the first.
    public func savedName(avoiding isTaken: (String) -> Bool) -> String {
        let name = savedName
        guard isTaken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }
}

/// One message in full, as Mail's reader draws it.
public struct MailpitMessage: Equatable, Identifiable, Sendable, Decodable {
    public var id: MailpitMessageID
    public var from: MailpitAddressee?
    public var to: [MailpitAddressee]
    public var cc: [MailpitAddressee]
    public var bcc: [MailpitAddressee]
    public var replyTo: [MailpitAddressee]
    public var subject: String
    public var date: Date
    public var text: String
    public var html: String
    /// What a reader would call attachments. Inline parts, the images an HTML body draws, are left
    /// out: they are already on screen in the body, and listing them again reads as extra files.
    public var attachments: [MailpitAttachment]

    public init(
        id: MailpitMessageID, from: MailpitAddressee? = nil, to: [MailpitAddressee] = [],
        cc: [MailpitAddressee] = [], bcc: [MailpitAddressee] = [], replyTo: [MailpitAddressee] = [],
        subject: String = "", date: Date = .distantPast, text: String = "", html: String = "",
        attachments: [MailpitAttachment] = []
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.date = date
        self.text = text
        self.html = html
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id = "ID"
        case from = "From"
        case to = "To"
        case cc = "Cc"
        case bcc = "Bcc"
        case replyTo = "ReplyTo"
        case subject = "Subject"
        case date = "Date"
        case text = "Text"
        case html = "HTML"
        case attachments = "Attachments"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(MailpitMessageID.self, forKey: .id)
        from = try container.decodeIfPresent(MailpitAddressee.self, forKey: .from)
        to = try container.decodeIfPresent([MailpitAddressee].self, forKey: .to) ?? []
        cc = try container.decodeIfPresent([MailpitAddressee].self, forKey: .cc) ?? []
        bcc = try container.decodeIfPresent([MailpitAddressee].self, forKey: .bcc) ?? []
        replyTo = try container.decodeIfPresent([MailpitAddressee].self, forKey: .replyTo) ?? []
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        date = MailpitDate.parse(try container.decodeIfPresent(String.self, forKey: .date))
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        html = try container.decodeIfPresent(String.self, forKey: .html) ?? ""
        attachments = try container.decodeIfPresent([MailpitAttachment].self, forKey: .attachments) ?? []
    }
}

/// One page of the list, from `messages` or from `search`.
public struct MailpitPage: Equatable, Sendable, Decodable {
    /// Every message in the mailbox, whatever the query.
    public var total: Int
    /// Unread messages in the whole mailbox. Measured on v1.31, a search page carries the
    /// mailbox's count here too and puts the matches' count in `messages_unread`, which nothing
    /// here reads. `MailboxList.adopt` still takes it only from an unfiltered page, so a Mailpit
    /// that ever answers the other way cannot put a search's count in the sidebar.
    public var unread: Int
    /// How many messages the query matches, which is the count paging runs up to.
    public var matching: Int
    public var start: Int
    public var messages: [MailpitSummary]

    public init(total: Int, unread: Int, matching: Int, start: Int, messages: [MailpitSummary]) {
        self.total = total
        self.unread = unread
        self.matching = matching
        self.start = start
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case total
        case unread
        case matching = "messages_count"
        case start
        case messages
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        unread = try container.decodeIfPresent(Int.self, forKey: .unread) ?? 0
        start = try container.decodeIfPresent(Int.self, forKey: .start) ?? 0
        messages = try container.decodeIfPresent([MailpitSummary].self, forKey: .messages) ?? []
        // Older Mailpits answer without `messages_count`, and for them `total` is the count of the
        // query too.
        matching = try container.decodeIfPresent(Int.self, forKey: .matching) ?? total
    }
}

/// What `api/v1/info` says, which is how Bloom tells that a Mailpit is there at all.
public struct MailpitInfo: Equatable, Sendable, Decodable {
    public var version: String
    public var messages: Int
    public var unread: Int

    public init(version: String, messages: Int, unread: Int) {
        self.version = version
        self.messages = messages
        self.unread = unread
    }

    private enum CodingKeys: String, CodingKey {
        case version = "Version"
        case messages = "Messages"
        case unread = "Unread"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        messages = try container.decodeIfPresent(Int.self, forKey: .messages) ?? 0
        unread = try container.decodeIfPresent(Int.self, forKey: .unread) ?? 0
    }
}

/// Mailpit's timestamps, which are Go's RFC 3339 with or without a fraction of a second, and with
/// an offset such as `+01:00` rather than always `Z`.
enum MailpitDate {
    static func parse(_ text: String?) -> Date {
        guard let text, !text.isEmpty else { return .distantPast }
        // A formatter per call rather than a shared one: `ISO8601DateFormatter` is not `Sendable`,
        // and a page is fifty rows, so the cost is not worth a lock.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text) ?? .distantPast
    }
}
