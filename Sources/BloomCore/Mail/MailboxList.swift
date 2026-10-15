import Foundation

/// The list the app-wide Mail destination draws, and every rule about how it changes.
///
/// A value rather than state on the app's `Mailbox`, because each of these is a decision with a
/// wrong answer that is easy to write: a page that arrives for a search somebody has since changed,
/// a websocket "new" frame for a message the list already holds, the row the selection moves to
/// when the one under it is deleted. The app owns one of these and does the networking; this owns
/// the arithmetic, and the tests hold it.
public struct MailboxList: Equatable, Sendable {
    public private(set) var messages: [MailpitSummary] = []
    /// The search the rows answer. Empty is the whole mailbox.
    public private(set) var query = ""
    /// How many messages the query matches, which is how far paging can go.
    public private(set) var matching = 0
    /// The whole mailbox's unread count, whatever the query. It is the number in the sidebar, and a
    /// search narrowing the rows does not make the mailbox have less unread mail.
    public private(set) var unread = 0
    /// Every message in the mailbox, whatever the query.
    public private(set) var total = 0

    public init() {}

    /// Whether the server holds more rows than the list does, which is what loading the next page
    /// on scroll asks.
    public var hasMore: Bool { messages.count < matching }

    /// Where the next page starts.
    public var nextStart: Int { messages.count }

    public func contains(_ id: MailpitMessageID) -> Bool {
        messages.contains { $0.id == id }
    }

    public func summary(_ id: MailpitMessageID) -> MailpitSummary? {
        messages.first { $0.id == id }
    }

    /// The band over the list: how much mail there is, and how much of it a search kept.
    ///
    /// The whole mailbox's numbers, because the button beside this sentence deletes the whole
    /// mailbox whatever the search says, and the count is what tells the reader how much that is.
    public var countLine: String {
        let all = Self.count(total, "message")
        let mailbox = unread > 0 ? "\(all), \(unread) unread" : all
        guard !query.isEmpty else { return mailbox }
        return "\(matching) matching, of \(all)"
    }

    /// What the delete-all confirmation asks, naming the number it is about to remove.
    public var deleteAllQuestion: String {
        total == 1 ? "Delete the only message?" : "Delete all \(total) messages?"
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }

    // MARK: - Pages

    /// Takes in a page that was asked for `query`.
    ///
    /// A first page replaces the list and a later one is appended to it. A page for a query that is
    /// no longer the list's own is still adopted when it is a first page, because that is how a new
    /// search starts; a later page for a different query is dropped, because it continues a list
    /// that is no longer on screen.
    ///
    /// Rows already held are not added twice. Mail arriving between two pages pushes everything one
    /// row down, so the second page starts with the last row of the first, and the websocket may
    /// have put a new message at the top before the page that also carries it came back.
    ///
    /// - Returns: false when the page was dropped.
    @discardableResult
    public mutating func adopt(_ page: MailpitPage, query: String) -> Bool {
        let query = Self.normalised(query)
        if page.start == 0 {
            self.query = query
            messages = Self.unique(page.messages)
        } else {
            guard query == self.query else { return false }
            let held = Set(messages.map(\.id))
            messages += page.messages.filter { !held.contains($0.id) }
        }
        matching = max(page.matching, messages.count)
        total = page.total
        // Mailpit v1.31 sends the mailbox's unread on a search page too, but taken from an
        // unfiltered page only, so a Mailpit that ever sends the matches' count instead cannot put
        // a search's number in the sidebar.
        if query.isEmpty { unread = page.unread }
        return true
    }

    /// The query as the list compares it, so that a trailing space typed into the field is not a
    /// different search.
    public static func normalised(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unique(_ rows: [MailpitSummary]) -> [MailpitSummary] {
        var seen = Set<MailpitMessageID>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Events

    /// What the app should do after a websocket frame.
    public enum EventOutcome: Equatable, Sendable {
        /// The list has taken the change in itself.
        case applied
        /// The list cannot tell what changed, and the first page has to be read again.
        case reload
    }

    public mutating func apply(_ event: MailpitEvent) -> EventOutcome {
        switch event {
        case .new(let summary):
            // A search cannot tell from here whether the new message matches it, and Mailpit's
            // query language is not something to reimplement in order to guess. Asking again is
            // one request, at the moment somebody's app sent mail.
            guard query.isEmpty else { return .reload }
            guard !contains(summary.id) else { return .applied }
            messages.insert(summary, at: 0)
            matching += 1
            total += 1
            return .applied

        case .update(let id, let isRead):
            guard let isRead, let index = messages.firstIndex(where: { $0.id == id }) else { return .applied }
            messages[index].isRead = isRead
            return .applied

        case .delete(let id):
            remove([id])
            return .applied

        case .truncate:
            messages = []
            matching = 0
            total = 0
            unread = 0
            return .applied

        case .prune:
            return .reload

        case .stats(let total, let unread):
            self.total = total
            self.unread = unread
            return .applied

        case .other:
            return .applied
        }
    }

    // MARK: - Local changes

    /// Marks rows read ahead of Mailpit saying so, so the dot goes the moment a message is opened
    /// rather than a round trip later. Mailpit's own `stats` frame corrects the count after.
    public mutating func markRead(_ ids: [MailpitMessageID]) {
        let wanted = Set(ids)
        for index in messages.indices where wanted.contains(messages[index].id) && !messages[index].isRead {
            messages[index].isRead = true
            unread = max(0, unread - 1)
        }
    }

    /// Takes rows out, as a delete Bloom asked for or one the websocket reported.
    public mutating func remove(_ ids: [MailpitMessageID]) {
        let gone = Set(ids)
        let before = messages.count
        let unreadGone = messages.filter { gone.contains($0.id) && !$0.isRead }.count
        messages.removeAll { gone.contains($0.id) }
        let removed = before - messages.count
        matching = max(messages.count, matching - removed)
        total = max(0, total - removed)
        unread = max(0, unread - unreadGone)
    }

    public mutating func removeAll() {
        _ = apply(.truncate)
    }

    // MARK: - Moving

    /// Where the selection goes when `id` is deleted: the row below, or the row above when it was
    /// the last. Nil when it was the only one.
    public func successor(afterRemoving id: MailpitMessageID) -> MailpitMessageID? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        if messages.indices.contains(index + 1) { return messages[index + 1].id }
        if index > 0 { return messages[index - 1].id }
        return nil
    }

}
