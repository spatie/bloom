import Foundation
import Synchronization
import Testing
@testable import BloomCore

/// A list page in the shape Mailpit v1.31 answers `api/v1/messages` with, measured off a running
/// copy and with every name and address invented. `Cc` is `null` on purpose: that is what Mailpit
/// sends for a header the message did not have, not an empty array.
private let pageBody = """
{"total":3,"unread":1,"count":2,"messages_count":3,"messages_unread":1,"start":0,"tags":[],
 "messages":[
  {"ID":"a1","MessageID":"one@example.com","Read":false,
   "From":{"Name":"Example App","Address":"hello@example.com"},
   "To":[{"Name":"Test User","Address":"test@example.test"}],"Cc":null,"Bcc":null,"ReplyTo":[],
   "Subject":"Verify your email","Created":"2026-10-05T21:40:53.146+01:00","Username":"",
   "Tags":[],"Size":11481,"Attachments":1,"Snippet":"Click the link to verify."},
  {"ID":"b2","MessageID":"two@example.com","Read":true,
   "From":{"Name":"","Address":"noreply@example.com"},
   "To":null,"Cc":null,"Bcc":null,"ReplyTo":[],
   "Subject":"Welcome","Created":"2026-10-05T20:00:00Z","Username":"",
   "Tags":[],"Size":2000,"Attachments":0,"Snippet":"Hello"}
 ]}
"""

private let messageBody = """
{"ID":"a1","MessageID":"one@example.com",
 "From":{"Name":"Example App","Address":"hello@example.com"},
 "To":[{"Name":"Test User","Address":"test@example.test"}],"Cc":null,"Bcc":null,"ReplyTo":[],
 "ReturnPath":"hello@example.com","Subject":"Verify your email",
 "ListUnsubscribe":{"Header":"","Links":[],"Errors":"","HeaderPost":""},
 "Date":"2026-10-05T21:40:53+01:00","Tags":[],"Username":"",
 "Text":"Click the link to verify.","HTML":"<p>Click the link</p>","Size":11481,
 "Inline":[{"PartID":"1.2","FileName":"logo.png","ContentType":"image/png","ContentID":"logo","Size":10}],
 "Attachments":[{"PartID":"2","FileName":"invoice.pdf","ContentType":"application/pdf","ContentID":"","Size":5120}]}
"""

/// Stands in for Mailpit: answers every request with one status and body, and keeps what it was
/// asked so a test can pin the method, the path and the body.
private final class FakeMailpit: Sendable {
    private let asked = Mutex<[URLRequest]>([])
    let status: Int
    let body: String
    let fails: Bool

    init(status: Int = 200, body: String = "{}", fails: Bool = false) {
        self.status = status
        self.body = body
        self.fails = fails
    }

    var requests: [URLRequest] { asked.withLock { $0 } }

    var client: MailpitClient {
        MailpitClient(base: URL(string: "http://localhost:8025")!) { [self] request in
            asked.withLock { $0.append(request) }
            if fails { throw URLError(.cannotConnectToHost) }
            return (Data(body.utf8), status)
        }
    }
}

private func json(_ request: URLRequest) -> [String: Any]? {
    request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

private func summary(_ id: String, read: Bool = false) -> MailpitSummary {
    MailpitSummary(id: MailpitMessageID(id), isRead: read, subject: id)
}

private func page(_ ids: [String], start: Int = 0, matching: Int? = nil, unread: Int = 0, total: Int? = nil) -> MailpitPage {
    MailpitPage(
        total: total ?? matching ?? ids.count, unread: unread, matching: matching ?? ids.count,
        start: start, messages: ids.map { summary($0) }
    )
}

// MARK: - Bundled settings

@Suite("Bundled mail settings")
struct BundledMailPortTests {
    @Test("incoming mails starts enabled but honours a saved Off choice")
    func enabledSetting() throws {
        let domain = "BundledMailPortTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        #expect(MailpitSettings.isEnabled(in: defaults))
        defaults.set(false, forKey: MailpitSettings.enabledKey)
        #expect(!MailpitSettings.isEnabled(in: defaults))
    }

    @Test("the bundled server keeps production and development ports separate")
    func bundledPorts() {
        #expect(MailpitSettings.bundledPorts(forBundleIdentifier: Store.primaryBundleIdentifier)
            == .init(smtp: 2255, api: 8025))
        #expect(MailpitSettings.bundledPorts(forBundleIdentifier: Store.devBundleIdentifier)
            == .init(smtp: 2256, api: 8026))
        #expect(MailpitSettings.bundledPorts(forBundleIdentifier: nil)
            == .init(smtp: 2256, api: 8026))
        #expect(MailpitSettings.bundledAddress(forBundleIdentifier: Store.devBundleIdentifier)
            == "http://127.0.0.1:8026")
    }

    @Test("SMTP ports must be unprivileged, distinct from the API, and no larger than 65535", arguments: [
        (0, false), (1023, false), (1024, true), (2255, true), (2256, true),
        (8026, false), (65535, true), (65536, false),
    ])
    func validates(_ port: Int, _ expected: Bool) {
        #expect(MailpitSettings.isValidSMTPPort(port, forBundleIdentifier: Store.devBundleIdentifier) == expected)
    }
}

// MARK: - Decoding

@Suite("Mailpit decoding")
struct MailpitDecodingTests {
    @Test("a list page decodes, nulls and all")
    func page() throws {
        let page = try JSONDecoder().decode(MailpitPage.self, from: Data(pageBody.utf8))
        #expect(page.total == 3)
        #expect(page.unread == 1)
        #expect(page.matching == 3)
        #expect(page.messages.map(\.id.rawValue) == ["a1", "b2"])

        let first = try #require(page.messages.first)
        #expect(!first.isRead)
        #expect(first.from?.display == "Example App")
        #expect(first.to.map(\.address) == ["test@example.test"])
        #expect(first.attachments == 1)
        #expect(first.snippet == "Click the link to verify.")

        let second = try #require(page.messages.last)
        #expect(second.to.isEmpty)
        #expect(second.from?.display == "noreply@example.com")
    }

    /// Go writes an offset rather than `Z` whenever the server's clock is not on UTC, with a
    /// fraction or without one, and all three have to land on the same instant they name.
    @Test("timestamps with an offset and a fraction land on the right instant")
    func dates() throws {
        let page = try JSONDecoder().decode(MailpitPage.self, from: Data(pageBody.utf8))
        #expect(abs(page.messages[0].created.timeIntervalSince1970 - 1_791_232_853.146) < 0.001)
        #expect(page.messages[1].created == Date(timeIntervalSince1970: 1_791_230_400))
    }

    @Test("a message decodes with its attachments, and inline images are not counted as attachments")
    func message() throws {
        let message = try JSONDecoder().decode(MailpitMessage.self, from: Data(messageBody.utf8))
        #expect(message.subject == "Verify your email")
        #expect(message.html == "<p>Click the link</p>")
        #expect(message.cc.isEmpty)
        #expect(message.attachments.map(\.fileName) == ["invoice.pdf"])
        #expect(message.attachments.first?.part == "2")
    }

    @Test("an attachment never names a path on this Mac", arguments: [
        ("invoice.pdf", "invoice.pdf"),
        ("../../.zshrc", "..-..-.zshrc"),
        ("a/b:c", "a-b-c"),
        ("", "attachment-3"),
        ("..", "attachment-3"),
    ])
    func savedName(_ name: String, _ expected: String) {
        #expect(MailpitAttachment(part: "3", fileName: name).savedName == expected)
    }

    @Test("a second copy in Downloads is numbered rather than written over the first")
    func avoidsTaken() {
        let invoice = MailpitAttachment(part: "2", fileName: "invoice.pdf")
        #expect(invoice.savedName { _ in false } == "invoice.pdf")
        #expect(invoice.savedName { ["invoice.pdf", "invoice 2.pdf"].contains($0) } == "invoice 3.pdf")
        let bare = MailpitAttachment(part: "2", fileName: "README")
        #expect(bare.savedName { $0 == "README" } == "README 2")
    }

    @Test("an older Mailpit with no match count pages up to the total")
    func noMatchCount() throws {
        let body = #"{"total":7,"unread":0,"start":0,"messages":[]}"#
        let page = try JSONDecoder().decode(MailpitPage.self, from: Data(body.utf8))
        #expect(page.matching == 7)
    }
}

// MARK: - The client

@Suite("Mailpit client")
struct MailpitClientTests {
    @Test("the whole mailbox is a list request, newest first, a page at a time")
    func listRequest() async throws {
        let fake = FakeMailpit(body: pageBody)
        let result = await fake.client.page(query: "", start: 50)
        #expect((try? result.get())?.messages.count == 2)

        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "GET")
        let url = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(url.path == "/api/v1/messages")
        #expect(url.queryItems?.contains(URLQueryItem(name: "start", value: "50")) == true)
        #expect(url.queryItems?.contains(URLQueryItem(name: "limit", value: "50")) == true)
    }

    @Test("a query goes to Mailpit's own search, with its syntax left alone")
    func searchRequest() async throws {
        let fake = FakeMailpit(body: pageBody)
        _ = await fake.client.page(query: " from:hello@example.com is:unread ", start: 0)

        let request = try #require(fake.requests.first)
        let url = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(url.path == "/api/v1/search")
        #expect(url.queryItems?.first { $0.name == "query" }?.value == "from:hello@example.com is:unread")
    }

    /// Mailpit reads an empty list of ids as "every message". An empty selection must never reach
    /// it, or deleting nothing would empty the mailbox.
    @Test("deleting no messages sends nothing at all")
    func deleteNothing() async {
        let fake = FakeMailpit()
        let result = await fake.client.delete([])
        #expect((try? result.get()) != nil)
        #expect(fake.requests.isEmpty)
    }

    @Test("deleting messages names exactly those messages")
    func deleteSome() async throws {
        let fake = FakeMailpit()
        _ = await fake.client.delete([MailpitMessageID("a1"), MailpitMessageID("b2")])

        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path() == "/api/v1/messages")
        #expect(json(request)?["IDs"] as? [String] == ["a1", "b2"])
    }

    @Test("deleting everything is its own call")
    func deleteAll() async throws {
        let fake = FakeMailpit()
        _ = await fake.client.deleteAll()

        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(json(request)?["IDs"] as? [String] == [])
    }

    @Test("marking read is a PUT naming the messages")
    func markRead() async throws {
        let fake = FakeMailpit()
        _ = await fake.client.markRead([MailpitMessageID("a1")])

        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(json(request)?["IDs"] as? [String] == ["a1"])
        #expect(json(request)?["Read"] as? Bool == true)
    }

    @Test("marking nothing read sends nothing, because no ids means every message")
    func markNothing() async {
        let fake = FakeMailpit()
        _ = await fake.client.markRead([])
        #expect(fake.requests.isEmpty)
    }

    @Test("each way of failing says which one it was", arguments: [
        (401, MailpitFailure.unauthorised),
        (403, .unauthorised),
        (404, .notFound),
        (500, .status(500)),
    ])
    func failures(_ status: Int, _ expected: MailpitFailure) async {
        let fake = FakeMailpit(status: status)
        let result = await fake.client.page(query: "", start: 0)
        #expect(result.map(\.total) == .failure(expected))
    }

    /// A 404 from `info` is a server with no such route, not a deleted message, and saying "The
    /// message has been deleted" about an address was what Settings did with a dev server on 8025.
    @Test("something on the port that is not Mailpit is said to be so, not a deleted message")
    func infoNotFound() async {
        let result = await FakeMailpit(status: 404).client.info()
        #expect(result == .failure(.undecodable))
    }

    @Test("a missing message is still a deleted one")
    func messageNotFound() async {
        let result = await FakeMailpit(status: 404).client.message(MailpitMessageID("gone"))
        #expect(result.map(\.id) == .failure(.notFound))
    }

    @Test("nothing listening is unreachable")
    func unreachable() async {
        let result = await FakeMailpit(fails: true).client.info()
        #expect(result == .failure(.unreachable))
    }

    @Test("something answering that is not Mailpit is said to be so")
    func notMailpit() async {
        let result = await FakeMailpit(body: "<html>Herd</html>").client.page(query: "", start: 0)
        #expect(result.map(\.total) == .failure(.undecodable))
    }

    @Test("the websocket and the HTML view hang off the same base, web root included", arguments: [
        ("http://localhost:8025", "ws://localhost:8025/api/events", "http://localhost:8025/view/a1.html"),
        ("https://mail.example.test/mailpit", "wss://mail.example.test/mailpit/api/events",
         "https://mail.example.test/mailpit/view/a1.html"),
    ])
    func addresses(_ base: String, _ events: String, _ html: String) throws {
        let client = MailpitClient(base: try #require(URL(string: base)))
        #expect(client.eventsURL.absoluteString == events)
        #expect(client.htmlURL(of: MailpitMessageID("a1")).absoluteString == html)
    }
}

// MARK: - Events

@Suite("Mailpit events")
struct MailpitEventTests {
    @Test("a new message carries the same summary a list row does")
    func new() throws {
        let frame = """
        {"Type":"new","Data":{"ID":"c3","Read":false,"From":{"Name":"App","Address":"a@example.com"},
         "To":[],"Subject":"Reset your password","Created":"2026-10-05T21:40:53Z","Attachments":0,"Snippet":"Reset"}}
        """
        guard case .new(let summary) = try #require(MailpitEvent.parse(frame)) else {
            Issue.record("not a new message")
            return
        }
        #expect(summary.id == MailpitMessageID("c3"))
        #expect(summary.subject == "Reset your password")
    }

    @Test("each kind of frame is told apart", arguments: [
        (#"{"Type":"update","Data":{"ID":"a1","Read":true}}"#, MailpitEvent.update(MailpitMessageID("a1"), isRead: true)),
        (#"{"Type":"update","Data":{"ID":"a1","Tags":["x"]}}"#, .update(MailpitMessageID("a1"), isRead: nil)),
        (#"{"Type":"delete","Data":{"ID":"a1"}}"#, .delete(MailpitMessageID("a1"))),
        (#"{"Type":"truncate","Data":null}"#, .truncate),
        (#"{"Type":"prune","Data":null}"#, .prune),
        (#"{"Type":"stats","Data":{"Total":4,"Unread":2,"Version":"v1.31.2"}}"#, .stats(total: 4, unread: 2)),
        (#"{"Type":"error","Data":{"Type":"smtp","Message":"x"}}"#, .other),
    ])
    func kinds(_ frame: String, _ expected: MailpitEvent) {
        #expect(MailpitEvent.parse(frame) == expected)
    }

    @Test("a frame that is not JSON is nothing, not a crash")
    func garbage() {
        #expect(MailpitEvent.parse("hello") == nil)
    }
}

// MARK: - The list

@Suite("Mailbox list")
struct MailboxListTests {
    @Test("a first page replaces the list and a later one extends it")
    func paging() {
        var list = MailboxList()
        list.adopt(page(["a", "b"], matching: 4, unread: 3), query: "")
        #expect(list.hasMore)
        #expect(list.nextStart == 2)
        #expect(list.unread == 3)

        list.adopt(page(["c", "d"], start: 2, matching: 4), query: "")
        #expect(list.messages.map(\.id.rawValue) == ["a", "b", "c", "d"])
        #expect(!list.hasMore)

        list.adopt(page(["z"], matching: 1), query: "")
        #expect(list.messages.map(\.id.rawValue) == ["z"])
    }

    /// Mail arriving between two pages pushes every row down one, so the next page starts with the
    /// row the last one ended on.
    @Test("a row already held is not added twice")
    func overlap() {
        var list = MailboxList()
        list.adopt(page(["a", "b"], matching: 4), query: "")
        list.adopt(page(["b", "c"], start: 2, matching: 4), query: "")
        #expect(list.messages.map(\.id.rawValue) == ["a", "b", "c"])
    }

    @Test("a later page for a search that has since changed is dropped")
    func stalePage() {
        var list = MailboxList()
        list.adopt(page(["a"], matching: 3), query: "subject:verify")
        let adopted = list.adopt(page(["x"], start: 1, matching: 3), query: "subject:reset")
        #expect(!adopted)
        #expect(list.messages.map(\.id.rawValue) == ["a"])
    }

    @Test("a search does not change the sidebar unread count")
    func searchKeepsUnread() {
        var list = MailboxList()
        list.adopt(page(["a", "b"], unread: 5), query: "")
        list.adopt(page(["a"], unread: 1), query: "is:unread subject:x")
        #expect(list.unread == 5)
        #expect(list.query == "is:unread subject:x")
    }

    @Test("new mail goes on top, once")
    func newMail() {
        var list = MailboxList()
        list.adopt(page(["a"]), query: "")
        let first = list.apply(.new(summary("b")))
        let again = list.apply(.new(summary("b")))
        #expect(first == .applied)
        #expect(again == .applied)
        #expect(list.messages.map(\.id.rawValue) == ["b", "a"])
        #expect(list.matching == 2)
    }

    /// Whether a new message matches a search is Mailpit's question, not a guess to make here.
    @Test("new mail during a search asks for the search again")
    func newMailWhileSearching() {
        var list = MailboxList()
        list.adopt(page(["a"]), query: "from:x")
        let outcome = list.apply(.new(summary("b")))
        #expect(outcome == .reload)
        #expect(list.messages.map(\.id.rawValue) == ["a"])
    }

    @Test("read, delete, truncate and stats each land on the list")
    func events() {
        var list = MailboxList()
        list.adopt(page(["a", "b", "c"], unread: 3), query: "")

        _ = list.apply(.update(MailpitMessageID("a"), isRead: true))
        #expect(list.summary(MailpitMessageID("a"))?.isRead == true)

        _ = list.apply(.update(MailpitMessageID("b"), isRead: nil))
        #expect(list.summary(MailpitMessageID("b"))?.isRead == false)

        _ = list.apply(.delete(MailpitMessageID("b")))
        #expect(list.messages.map(\.id.rawValue) == ["a", "c"])
        #expect(list.matching == 2)

        _ = list.apply(.stats(total: 9, unread: 4))
        #expect(list.unread == 4)
        #expect(list.total == 9)

        _ = list.apply(.truncate)
        #expect(list.messages.isEmpty)
        #expect(list.unread == 0)
        #expect(!list.hasMore)
    }

    @Test("a prune cannot be followed, so the list is read again")
    func prune() {
        var list = MailboxList()
        let outcome = list.apply(.prune)
        #expect(outcome == .reload)
    }

    @Test("marking read takes the dot off and the count down, once per message")
    func markRead() {
        var list = MailboxList()
        list.adopt(page(["a", "b"], unread: 2), query: "")
        list.markRead([MailpitMessageID("a")])
        list.markRead([MailpitMessageID("a")])
        #expect(list.summary(MailpitMessageID("a"))?.isRead == true)
        #expect(list.unread == 1)
    }

    @Test("deleting the selected row moves to the next older message, or back up from the last", arguments: [
        ("a", "b"), ("b", "c"), ("c", "b"),
    ])
    func successor(_ deleted: String, _ expected: String) {
        var list = MailboxList()
        list.adopt(page(["a", "b", "c"]), query: "")
        #expect(list.successor(afterRemoving: MailpitMessageID(deleted))?.rawValue == expected)
    }

    @Test("the band counts the whole mailbox, and what a search kept of it")
    func countLine() {
        var list = MailboxList()
        list.adopt(page(["a"], matching: 1, unread: 0, total: 1), query: "")
        #expect(list.countLine == "1 message")
        #expect(list.deleteAllQuestion == "Delete the only message?")

        list.adopt(page(["a", "b"], matching: 12, unread: 3, total: 12), query: "")
        #expect(list.countLine == "12 messages, 3 unread")
        #expect(list.deleteAllQuestion == "Delete all 12 messages?")

        list.adopt(page(["a"], matching: 2, unread: 3, total: 12), query: "subject:verify")
        #expect(list.countLine == "2 matching, of 12 messages")
    }

    @Test("deleting the only row leaves nothing to move to")
    func successorOfOnly() {
        var list = MailboxList()
        list.adopt(page(["a"]), query: "")
        #expect(list.successor(afterRemoving: MailpitMessageID("a")) == nil)
    }
}

// MARK: - Discovery state

@Suite("Mailbox presence")
struct MailboxPresenceTests {
    @Test("Mailpit is unknown until it answers, and then remembered")
    func sticky() {
        var presence = MailboxPresence(isEnabled: true)
        #expect(!presence.hasAnswered)
        #expect(presence.isSearching)

        presence.answered()
        #expect(presence.hasAnswered)
        #expect(!presence.isSearching)
    }

    @Test("switched off, there is no looking")
    func disabled() {
        var presence = MailboxPresence(isEnabled: false)
        presence.answered()
        #expect(!presence.hasAnswered)
        #expect(!presence.isSearching)
    }

    @Test("a new address starts over, because the old answer was about another server")
    func reconfigure() {
        var presence = MailboxPresence(isEnabled: true)
        presence.answered()
        presence.reconfigure(isEnabled: true)
        #expect(!presence.hasAnswered)
        #expect(presence.isSearching)
    }

    @Test("reconnecting backs off from a second to thirty and holds there")
    func backoff() {
        let delays = (1...8).map { MailboxPresence.reconnectDelay(afterFailures: $0) }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30].map { Duration.seconds($0) })
        #expect(MailboxPresence.reconnectDelay(afterFailures: 0) == .zero)
    }
}

// MARK: - The loop's decisions

@Suite("Mailbox link")
struct MailboxLinkTests {
    private let info = MailpitInfo(version: "v1.31.2", messages: 0, unread: 0)

    @Test("an answer resets the count and says to listen")
    func answered() {
        var link = MailboxLink(isEnabled: true)
        link.startLooking()
        #expect(link.connection == .connecting)
        let next = link.probed(.success(info))
        #expect(next == .listen)
        #expect(link.presence.hasAnswered)
        link.listening()
        #expect(link.connection == .live)
    }

    @Test("until Mailpit has answered once, the next look is the slow search")
    func searching() {
        var link = MailboxLink(isEnabled: true)
        let first = link.probed(.failure(.unreachable))
        let second = link.probed(.failure(.unreachable))
        #expect(first == .wait(MailboxPresence.searchInterval))
        #expect(second == .wait(MailboxPresence.searchInterval))
        #expect(link.connection == .disconnected(.unreachable))
        #expect(!link.presence.hasAnswered)
    }

    /// A password prompt proves Mailpit answered, even though Bloom cannot authenticate.
    @Test("a password prompt counts as Mailpit answering, and is backed off from")
    func unauthorised() {
        var link = MailboxLink(isEnabled: true)
        let next = link.probed(.failure(.unauthorised))
        #expect(link.presence.hasAnswered)
        #expect(link.connection == .disconnected(.unauthorised))
        #expect(next == .wait(MailboxPresence.reconnectDelay(afterFailures: 1)))
    }

    @Test("something that is not Mailpit does not count as an answer")
    func notMailpit() {
        var link = MailboxLink(isEnabled: true)
        _ = link.probed(.failure(.undecodable))
        #expect(!link.presence.hasAnswered)
    }

    @Test("a drop after a working connection retries quickly, then backs off")
    func dropThenBackOff() {
        var link = MailboxLink(isEnabled: true)
        _ = link.probed(.success(info))
        link.listening()
        let afterDrop = link.dropped(.unreachable)
        #expect(afterDrop == MailboxPresence.reconnectDelay(afterFailures: 1))
        #expect(link.connection == .disconnected(.unreachable))
        let next = link.probed(.failure(.unreachable))
        #expect(next == .wait(MailboxPresence.reconnectDelay(afterFailures: 2)))
        // The earlier answer is remembered for the reconnect interval.
        #expect(link.presence.hasAnswered)
    }

    @Test("a working connection starts the count again")
    func successResets() {
        var link = MailboxLink(isEnabled: true)
        _ = link.probed(.success(info))
        _ = link.dropped(.unreachable)
        _ = link.probed(.failure(.unreachable))
        _ = link.probed(.success(info))
        let afterDrop = link.dropped(.unreachable)
        #expect(afterDrop == MailboxPresence.reconnectDelay(afterFailures: 1))
    }

    @Test("coming to the front looks again only when nothing is connected or connecting")
    func activation() {
        var link = MailboxLink(isEnabled: true)
        link.startLooking()
        #expect(!link.looksAgainOnActivation)
        _ = link.probed(.failure(.unreachable))
        #expect(link.looksAgainOnActivation)
        _ = link.probed(.success(info))
        link.listening()
        #expect(!link.looksAgainOnActivation)

        var off = MailboxLink(isEnabled: false)
        off.stopLooking()
        #expect(!off.looksAgainOnActivation)
    }

    @Test("a new address forgets the old answer")
    func reconfigure() {
        var link = MailboxLink(isEnabled: true)
        _ = link.probed(.success(info))
        link.reconfigure(isEnabled: true)
        #expect(!link.presence.hasAnswered)
        #expect(link.connection == .connecting)
        link.reconfigure(isEnabled: false)
        #expect(link.connection == .idle)
    }
}
