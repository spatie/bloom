import Testing
@testable import BloomCore

@Suite("Pane naming")
struct PaneNamingTests {
    @Test("The first pane of a kind wears the bare name")
    func firstIsBare() {
        #expect(PaneNaming.nextTitle(base: PaneNaming.chat, taken: []) == "Chat")
        #expect(PaneNaming.nextTitle(base: PaneNaming.browser, taken: ["Chat"]) == "Browser")
    }

    @Test("A second pane of a kind is numbered from two")
    func secondIsTwo() {
        #expect(PaneNaming.nextTitle(base: "Chat", taken: ["Chat"]) == "Chat 2")
    }

    @Test("Numbering climbs past every number already out")
    func climbs() {
        #expect(PaneNaming.nextTitle(base: "Chat", taken: ["Chat", "Chat 2"]) == "Chat 3")
        #expect(
            PaneNaming.nextTitle(base: "Chat", taken: ["Chat", "Chat 2", "Chat 3"]) == "Chat 4"
        )
    }

    /// The case the whole rule turns on. Chat, Chat 2, Chat 3; close Chat 2; open a new one.
    /// The gap is filled rather than stepped over, so the strip reads as a run.
    @Test("A closed pane's number is handed out again")
    func reusesTheGap() {
        #expect(PaneNaming.nextTitle(base: "Chat", taken: ["Chat", "Chat 3"]) == "Chat 2")
    }

    /// The bare name is a number too, and it is the first gap there is.
    @Test("The bare name is reused when only numbered panes are left")
    func reusesTheBareName() {
        #expect(PaneNaming.nextTitle(base: "Chat", taken: ["Chat 2", "Chat 3"]) == "Chat")
    }

    /// A person who has typed "Chat 2" over a tab holds that name against the numbering, or two
    /// tabs read identically.
    @Test("A name somebody typed is taken like any other")
    func respectsTypedNames() {
        #expect(PaneNaming.nextTitle(base: "Chat", taken: ["Chat", "Chat 2"]) == "Chat 3")
    }

    /// Chats named from their first turn before this rule existed keep those names, and hold no
    /// number: a workspace whose one chat is called "Are you there" opens its next chat as Chat.
    @Test("A chat named from its content holds no number")
    func ignoresContentNames() {
        #expect(PaneNaming.nextTitle(base: "Chat", taken: ["Are you there"]) == "Chat")
    }

    @Test("Numbering is per kind")
    func perKind() {
        let taken = ["Chat", "Chat 2", "Terminal"]
        #expect(PaneNaming.nextTitle(base: "Chat", taken: taken) == "Chat 3")
        #expect(PaneNaming.nextTitle(base: "Terminal", taken: taken) == "Terminal 2")
    }

    // MARK: - Telling a default name from a typed one

    @Test("Default names are recognised")
    func recognisesDefaults() {
        #expect(PaneNaming.isDefaultTitle("Terminal", base: "Terminal"))
        #expect(PaneNaming.isDefaultTitle("Terminal 2", base: "Terminal"))
        #expect(PaneNaming.isDefaultTitle("Terminal 40", base: "Terminal"))
    }

    @Test("A name somebody typed is not a default")
    func rejectsTypedNames() {
        #expect(!PaneNaming.isDefaultTitle("Terminal server", base: "Terminal"))
        #expect(!PaneNaming.isDefaultTitle("Terminal2", base: "Terminal"))
        #expect(!PaneNaming.isDefaultTitle("", base: "Terminal"))
        #expect(!PaneNaming.isDefaultTitle("Chat", base: "Terminal"))
    }
}
