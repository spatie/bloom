import Foundation
import Testing
@testable import BloomCore

/// The log excerpt is the one field of a feedback report that could carry somebody's work off
/// their machine, so what it may contain is pinned here rather than left to a reading of the
/// sheet. Every test below is a thing that must not survive `scrubbed`, or a cap that must hold.
@Suite("App log excerpt")
struct AppLogExcerptTests {
    private let start = Date(timeIntervalSince1970: 1_766_000_000)

    private func entry(_ message: String, category: String = "archive", offset: TimeInterval = 0) -> AppLogExcerpt.Entry {
        AppLogExcerpt.Entry(date: start.addingTimeInterval(offset), category: category, message: message)
    }

    private let utc = TimeZone(secondsFromGMT: 0)!

    // MARK: - Shape

    @Test("a line is a time, a category and what was said")
    func lineShape() {
        let text = AppLogExcerpt.line(entry("could not archive"), timeZone: utc)

        #expect(text.hasSuffix("  archive  could not archive"))
        #expect(text.prefix(8).allSatisfy { $0.isNumber || $0 == ":" })
    }

    @Test("a message spanning lines becomes one line")
    func foldsNewlines() {
        let text = AppLogExcerpt.line(entry("first\n\nsecond   third"), timeZone: utc)

        #expect(text.hasSuffix("first second third"))
    }

    @Test("nothing logged says so, rather than sending an empty string")
    func emptyExcerpt() {
        #expect(AppLogExcerpt.excerpt([]) == AppLogExcerpt.empty)
    }

    // MARK: - Caps

    @Test("only the entries inside the window are sent")
    func windowFilter() {
        let entries = [
            entry("old", offset: -3_600),
            entry("recent", offset: -60),
        ]

        let text = AppLogExcerpt.excerpt(entries, since: start.addingTimeInterval(-AppLogExcerpt.window), timeZone: utc)

        #expect(!text.contains("old"))
        #expect(text.contains("recent"))
    }

    @Test("the newest entries survive the entry cap")
    func entryCap() {
        let entries = (0..<(AppLogExcerpt.maxEntries + 50)).map { entry("line \($0)", offset: TimeInterval($0)) }

        let lines = AppLogExcerpt.excerpt(entries, timeZone: utc).components(separatedBy: "\n")

        #expect(lines.count == AppLogExcerpt.maxEntries)
        #expect(lines.last?.hasSuffix("line \(AppLogExcerpt.maxEntries + 49)") == true)
    }

    @Test("one enormous line cannot fill the excerpt on its own")
    func entryLengthCap() {
        // Words rather than one unbroken run: an unbroken run of forty characters is a
        // credential shape and would be taken out before the length cap ever saw it.
        let text = AppLogExcerpt.line(entry(String(repeating: "long line ", count: 500)), timeZone: utc)

        #expect(text.count < AppLogExcerpt.maxEntryCharacters + 64)
        #expect(text.hasSuffix(AppLogExcerpt.elision))
    }

    @Test("the character cap keeps the end and says something was left out")
    func characterCap() {
        let entries = (0..<AppLogExcerpt.maxEntries).map {
            entry(String(repeating: "some words ", count: 27) + "\($0)", offset: TimeInterval($0))
        }

        let text = AppLogExcerpt.excerpt(entries, timeZone: utc)

        #expect(text.count <= AppLogExcerpt.maxCharacters + AppLogExcerpt.elision.count + 1)
        #expect(text.hasPrefix(AppLogExcerpt.elision))
        #expect(text.hasSuffix("\(AppLogExcerpt.maxEntries - 1)"))
    }

    // MARK: - What can never survive

    @Test("an absolute path never survives")
    func scrubsPaths() {
        let text = AppLogExcerpt.scrubbed("could not read /Users/someone/dev/code/thing/file.swift")

        #expect(!text.contains("someone"))
        #expect(!text.contains("/dev/code"))
        #expect(text.contains(AppLogExcerpt.Placeholder.path))
    }

    @Test("a home-relative path never survives")
    func scrubsTildePaths() {
        let text = AppLogExcerpt.scrubbed("reading ~/.claude.json failed")

        #expect(!text.contains(".claude.json"))
        #expect(text.contains(AppLogExcerpt.Placeholder.path))
    }

    @Test("a lone system directory is left alone, because it names nobody")
    func keepsBareDirectories() {
        #expect(AppLogExcerpt.scrubbed("wrote to /tmp") == "wrote to /tmp")
    }

    @Test("a URL never survives, whatever it carries")
    func scrubsURLs() {
        let text = AppLogExcerpt.scrubbed("feed https://example.com/appcast.xml?key=abc123")

        #expect(!text.contains("example.com"))
        #expect(!text.contains("abc123"))
        #expect(text.contains(AppLogExcerpt.Placeholder.url))
    }

    @Test("an email address never survives")
    func scrubsEmail() {
        let text = AppLogExcerpt.scrubbed("signed in as someone@example.com")

        #expect(!text.contains("someone@example.com"))
        #expect(text.contains(AppLogExcerpt.Placeholder.email))
    }

    @Test("credential shapes never survive", arguments: [
        "sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345",
        "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
        "github_pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyz",
        "xoxb-123456789012-abcdefghijkl",
        "AKIAIOSFODNN7EXAMPLE",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dQw4w9WgXcQabcdef",
    ])
    func scrubsCredentials(secret: String) {
        let text = AppLogExcerpt.scrubbed("the CLI answered \(secret) and stopped")

        #expect(!text.contains(secret))
        #expect(text.contains(AppLogExcerpt.Placeholder.secret))
    }

    @Test("anything introduced as a secret loses its value and keeps its name")
    func scrubsNamedSecrets() {
        let text = AppLogExcerpt.scrubbed("Authorization: Bloom-Token-Value-Here")

        #expect(!text.contains("Bloom-Token-Value-Here"))
        #expect(text.lowercased().contains("authorization"))
    }

    @Test("a long unbroken run is taken out even when nobody recognises the format")
    func scrubsUnknownSecrets() {
        let unknown = String(repeating: "Zq7", count: 20)

        #expect(!AppLogExcerpt.scrubbed("value \(unknown)").contains(unknown))
    }

    // MARK: - The words this Mac uses

    @Test("project, workspace and branch names are taken out by name")
    func scrubsKnownWords() {
        let redaction = AppLogExcerpt.Redaction.of(
            projects: ["Billing Importer"],
            workspaces: ["Rewrite the importer"],
            branches: ["freek/rewrite-importer"],
            user: "someone",
            host: "someones-macbook"
        )

        let text = AppLogExcerpt.scrubbed(
            "archived Rewrite the importer on freek/rewrite-importer in Billing Importer for someone at someones-macbook",
            redaction: redaction
        )

        #expect(!text.localizedCaseInsensitiveContains("importer"))
        #expect(!text.contains("someone"))
        #expect(text.contains(AppLogExcerpt.Placeholder.workspace))
        #expect(text.contains(AppLogExcerpt.Placeholder.branch))
        #expect(text.contains(AppLogExcerpt.Placeholder.project))
        #expect(text.contains(AppLogExcerpt.Placeholder.user))
        #expect(text.contains(AppLogExcerpt.Placeholder.host))
    }

    @Test("the longest name goes first, so no half of one is left behind")
    func longestWordFirst() {
        let redaction = AppLogExcerpt.Redaction.of(projects: ["ship"], workspaces: ["shipping-labels"])

        let text = AppLogExcerpt.scrubbed("archived shipping-labels", redaction: redaction)

        #expect(text == "archived \(AppLogExcerpt.Placeholder.workspace)")
    }

    @Test("a name too short to be worth replacing is not replaced")
    func shortWordsAreKept() {
        let redaction = AppLogExcerpt.Redaction.of(projects: ["api"])

        #expect(AppLogExcerpt.scrubbed("the api answered", redaction: redaction) == "the api answered")
    }

    @Test("a name is matched however it was capitalised")
    func caseInsensitiveWords() {
        let redaction = AppLogExcerpt.Redaction.of(workspaces: ["Fix The Header"])

        #expect(AppLogExcerpt.scrubbed("fix the header stalled", redaction: redaction)
            == "\(AppLogExcerpt.Placeholder.workspace) stalled")
    }

    @Test("a real refusal comes out readable and says nothing about the machine")
    func realisticLine() {
        let redaction = AppLogExcerpt.Redaction.of(workspaces: ["Add the export button"], user: "someone")

        let text = AppLogExcerpt.excerpt(
            [entry("could not archive Add the export button: /Users/someone/dev/thing is dirty")],
            redaction: redaction,
            timeZone: utc
        )

        #expect(text.contains("could not archive"))
        #expect(text.contains(AppLogExcerpt.Placeholder.workspace))
        #expect(text.contains(AppLogExcerpt.Placeholder.path))
        #expect(!text.contains("someone"))
    }
}
