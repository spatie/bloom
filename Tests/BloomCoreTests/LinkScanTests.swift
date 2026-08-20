import Testing
@testable import BloomCore

@Suite("Link detection")
struct LinkScanTests {
    /// The written text of every link found, which is what a reader sees underlined.
    private func written(_ text: String) -> [String] {
        LinkScan.links(in: text).map(\.text)
    }

    /// Where each of them points, which is the only half that is ever opened.
    private func addresses(_ text: String) -> [String] {
        LinkScan.links(in: text).map(\.url)
    }

    // MARK: What is detected

    @Test("an https address is a link, whatever its top level domain is")
    func unusualTopLevelDomain() {
        let sentence = "the url is: https://there-there-6.test/settings/workspace/custom-sidebar-sections"
        #expect(written(sentence) == ["https://there-there-6.test/settings/workspace/custom-sidebar-sections"])
        #expect(addresses(sentence) == ["https://there-there-6.test/settings/workspace/custom-sidebar-sections"])
    }

    @Test("a local development host is a link", arguments: [
        "http://bloom.test",
        "https://bloom.test/one/two?three=four#five",
        "http://192.168.1.14:8080/status",
    ])
    func schemes(address: String) {
        #expect(written("see \(address) now") == [address])
    }

    @Test("a bare localhost with a port is a link, and it is addressed over http")
    func bareLocalhost() {
        #expect(written("open localhost:3000 in a browser") == ["localhost:3000"])
        #expect(addresses("open localhost:3000 in a browser") == ["http://localhost:3000"])
        #expect(addresses("localhost:3000/admin/login") == ["http://localhost:3000/admin/login"])
        #expect(addresses("127.0.0.1:8000") == ["http://127.0.0.1:8000"])
    }

    @Test("the scheme is read without regard to case")
    func mixedCaseScheme() {
        #expect(written("HTTPS://example.com") == ["HTTPS://example.com"])
    }

    @Test("several addresses in one line are all found, in the order they were written")
    func several() {
        #expect(written("https://a.test and https://b.test") == ["https://a.test", "https://b.test"])
    }

    @Test("a link is found where the text is a range, not a copy")
    func rangeIsExact() {
        let sentence = "go to https://example.com now"
        let link = try! #require(LinkScan.links(in: sentence).first)
        #expect(String(sentence[link.range]) == "https://example.com")
    }

    // MARK: What is refused

    @Test("a file path is not a link", arguments: [
        "/Users/freek/dev/code/Bloom/Sources/BloomCore/LinkScan.swift",
        "Sources/Bloom/Views/Transcript/UserTurnRowView.swift",
        "./build.sh",
        "~/Library/Application Support/Bloom/bloom.sqlite",
        "Views/Markdown/MarkdownView.swift:42",
    ])
    func paths(path: String) {
        #expect(written("edited \(path) just now").isEmpty)
    }

    @Test("a git remote is not a link")
    func gitRemote() {
        #expect(written("git@github.com:spatie/bloom.git").isEmpty)
        #expect(written("origin  git@github.com:spatie/bloom.git (fetch)").isEmpty)
    }

    @Test("a branch name with slashes in it is not a link")
    func branchName() {
        #expect(written("on branch freek/transcript/link-detection").isEmpty)
        #expect(written("feature/localhost-fixes").isEmpty)
    }

    @Test("a mail address is not a link, bare or schemed")
    func mailAddress() {
        #expect(written("write to freek@spatie.be about it").isEmpty)
        #expect(written("mailto:freek@spatie.be").isEmpty)
    }

    @Test("a bare host with no scheme is not a link")
    func bareHost() {
        #expect(written("read it on spatie.be").isEmpty)
        #expect(written("www.example.com").isEmpty)
        #expect(written("see Package.swift and README.md").isEmpty)
    }

    @Test("localhost on its own is a word, not an address")
    func localhostAlone() {
        #expect(written("the server runs on localhost").isEmpty)
        #expect(written("localhost:").isEmpty)
        #expect(written("localhost:abc").isEmpty)
    }

    @Test("a host glued to what came before it is part of that, not a link of its own", arguments: [
        "deploy@localhost:2222",
        "./localhost:3000",
        "mylocalhost:3000",
        "cache-https://example.com",
    ])
    func glued(fragment: String) {
        #expect(written("ran \(fragment) today").isEmpty)
    }

    @Test("a scheme with nothing behind it is not a link")
    func emptyHost() {
        #expect(written("http:// is a scheme").isEmpty)
        #expect(written("https://").isEmpty)
    }

    @Test("a scheme Bloom does not open is not a link")
    func otherSchemes() {
        #expect(written("file:///Applications/Bloom.app").isEmpty)
        #expect(written("ftp://example.com/file").isEmpty)
    }

    // MARK: Code

    @Test("an address inside a code span is being quoted, not offered")
    func codeSpan() {
        #expect(written("run `curl https://example.com` first").isEmpty)
        #expect(written("`localhost:3000`").isEmpty)
    }

    @Test("a code span leaves the addresses around it alone")
    func codeSpanNeighbours() {
        #expect(written("https://a.test then `https://b.test` then https://c.test")
            == ["https://a.test", "https://c.test"])
    }

    @Test("an address inside a fenced block is not a link")
    func fencedBlock() {
        let text = """
        before https://a.test

        ```
        curl https://b.test
        ```

        after https://c.test
        """
        #expect(written(text) == ["https://a.test", "https://c.test"])
    }

    @Test("an unclosed fence takes the rest of the text with it")
    func unclosedFence() {
        #expect(written("before https://a.test\n```\nhttps://b.test") == ["https://a.test"])
    }

    // MARK: Where an address stops

    @Test("trailing punctuation belongs to the sentence, not to the address", arguments: [
        ".", ",", ";", ":", "!", "?", "...",
    ])
    func trailingPunctuation(mark: String) {
        #expect(written("go to https://example.com/page\(mark)") == ["https://example.com/page"])
    }

    @Test("a closing bracket is only kept when the address opened one")
    func brackets() {
        #expect(written("(see https://example.com)") == ["https://example.com"])
        #expect(written("[https://example.com]") == ["https://example.com"])
        #expect(written("https://en.wikipedia.org/wiki/Cat_(disambiguation)")
            == ["https://en.wikipedia.org/wiki/Cat_(disambiguation)"])
    }

    @Test("quotes around an address are not part of it")
    func quoted() {
        #expect(written("\"https://example.com\"") == ["https://example.com"])
        #expect(written("it is https://example.com's page") == ["https://example.com"])
    }

    @Test("an address ends at whitespace")
    func whitespace() {
        #expect(written("https://example.com/a b") == ["https://example.com/a"])
        #expect(written("https://example.com\nnext") == ["https://example.com"])
    }

    // MARK: Nothing hangs

    @Test("fragments terminate", arguments: [
        "", "h", "ht", "http", "http:", "http:/", "http://", "l", "localhost", "localhost:",
        "1", "127.0.0.1", "127.0.0.1:", "`", "```", "```\n", "(", ")", "https://(",
    ])
    func fragmentsTerminate(fragment: String) {
        _ = LinkScan.links(in: fragment)
    }

    @Test("every prefix of a paragraph scans")
    func everyPrefixScans() {
        let text = "see https://a.test, `https://b.test` and localhost:3000/x (https://c.test)"
        for length in 0...text.count {
            _ = LinkScan.links(in: String(text.prefix(length)))
        }
    }
}
