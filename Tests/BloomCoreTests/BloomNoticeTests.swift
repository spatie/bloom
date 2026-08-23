import Testing
import Foundation
@testable import BloomCore

@Suite("How long a notice stays")
struct NoticeLifetimeTests {
    @Test("a word is a unit and a long unbroken token is several")
    func units() {
        #expect(NoticeLifetime.units(in: "") == 0)
        #expect(NoticeLifetime.units(in: "Bloom named this workspace") == 4)
        // Twelve characters is still one glance.
        #expect(NoticeLifetime.units(in: "abcdefghijkl") == 1)
        #expect(NoticeLifetime.units(in: "abcdefghijklm") == 2)
        // The token that forced the rule.
        #expect(NoticeLifetime.units(in: "freekmurze/fade-animation-feel") == 3)
        // The marks are not read out, so they are not counted either.
        #expect(NoticeLifetime.units(in: "`branch`") == 1)
    }

    @Test("a short notice gets the floor and a long one gets the ceiling")
    func clamps() {
        #expect(NoticeLifetime.reading("") == NoticeLifetime.shortest)
        #expect(NoticeLifetime.reading("Renamed.") == NoticeLifetime.shortest)
        let essay = String(repeating: "word ", count: 200)
        #expect(NoticeLifetime.reading(essay) == NoticeLifetime.longest)
    }

    @Test("a longer sentence gets longer, and the real one lands where it should")
    func scales() {
        let short = "This workspace is the first to sail the Coral Sea. One sea is still waiting to be discovered."
        let long = "Bloom named this workspace Describe fade-in animation feel. Its branch is still "
            + "`freekmurze/iyo-sea`, because `freekmurze/fade-animation-feel` is already taken by another branch."

        #expect(NoticeLifetime.reading(short) < NoticeLifetime.reading(long))
        // Both inside the band, so neither is being clamped and the rule is what is being read.
        #expect(NoticeLifetime.reading(short) > NoticeLifetime.shortest)
        #expect(NoticeLifetime.reading(long) < NoticeLifetime.longest)
        // The message from the screenshot this was built for: nine seconds, near enough.
        #expect(NoticeLifetime.reading(long) > .seconds(8))
        #expect(NoticeLifetime.reading(long) < .seconds(10))
    }

    @Test("news goes on its own and a place the user has to look does not")
    func dismissal() {
        #expect(BloomNotice(message: "Bloom named this workspace Foxglove.").lifetime != nil)
        #expect(BloomNotice(message: "It moved.", dismissal: .untilDismissed).lifetime == nil)
    }
}

@Suite("What a notice says")
struct NoticeTextTests {
    @Test("the first sentence is the fact and the rest is the reason")
    func split() {
        let text = NoticeText("Bloom named this workspace Foxglove. Its branch is still `add-a-toggle`.")
        #expect(text.fact.map(\.text).joined() == "Bloom named this workspace Foxglove.")
        #expect(text.reason.map(\.text).joined() == "Its branch is still add-a-toggle.")
    }

    @Test("a one sentence notice keeps all of itself in the fact")
    func oneSentence() {
        let text = NoticeText("Something else was in the way.")
        #expect(text.fact.map(\.text).joined() == "Something else was in the way.")
        #expect(text.reason.isEmpty)
    }

    @Test("a full stop with no space after it is not the end of a sentence")
    func versionNumber() {
        let text = NoticeText("The worktree was rebuilt at /tmp/v1.2.3/work.")
        #expect(text.reason.isEmpty)
    }

    @Test("a full stop inside a machine's own words does not cut the message")
    func markedFullStop() {
        let text = NoticeText("It was rebuilt at `/tmp/one. two/work`. Nothing else moved.")
        #expect(text.fact.map(\.text).joined() == "It was rebuilt at /tmp/one. two/work.")
        #expect(text.reason.map(\.text).joined() == "Nothing else moved.")
    }

    @Test("backticks mark the machine's words and never reach the reader")
    func machineRuns() {
        let text = NoticeText("Its branch is still `iyo-sea`, because `fade-feel` is taken.")
        #expect(text.fact == [
            NoticeRun(text: "Its branch is still ", isMachine: false),
            NoticeRun(text: "iyo-sea", isMachine: true),
            NoticeRun(text: ", because ", isMachine: false),
            NoticeRun(text: "fade-feel", isMachine: true),
            NoticeRun(text: " is taken.", isMachine: false),
        ])
        #expect(!text.plain.contains("`"))
    }

    @Test("an unclosed backtick marks nothing rather than half the sentence")
    func strayMark() {
        let text = NoticeText("It is still `iyo-sea, which is odd.")
        #expect(text.fact.allSatisfy { !$0.isMachine })
        #expect(!text.plain.contains("`"))
    }

    @Test("the plain reading is the message a screen reader should get")
    func plain() {
        let message = "Bloom named this workspace Foxglove. Its branch is still `add-a-toggle`, because it has 2 commits on it."
        #expect(NoticeText(message).plain == message.replacingOccurrences(of: "`", with: ""))
    }

    @Test("every notice the app can raise splits into two readable sentences")
    func realMessages() throws {
        let branch = try #require(WorkspaceNaming.branchNotice(
            name: "Dark mode toggle", branch: "freekmurze/iyo-sea", refusal: .nameTaken("freekmurze/fade-feel")
        ))
        let ocean = try #require(OceanPick(
            ocean: Ocean(name: "Coral Sea", slug: "coral-sea", latitude: 0, longitude: 0),
            isFirstUse: true,
            remainingUndiscovered: 1
        ).notice)

        for message in [branch, ocean] {
            let text = NoticeText(message)
            #expect(!text.fact.isEmpty)
            #expect(!text.reason.isEmpty, "\(message)")
        }
        // The branch names are the machine's, and are marked as such.
        #expect(NoticeText(branch).reason.filter(\.isMachine).map(\.text)
            == ["freekmurze/iyo-sea", "freekmurze/fade-feel"])
    }
}
