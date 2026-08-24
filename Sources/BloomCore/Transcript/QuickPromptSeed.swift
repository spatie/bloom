import Foundation

/// The quick prompts a fresh copy of Bloom starts with, and the rule that stops a deleted one from
/// coming back.
///
/// **Seed once, and record that it happened.** The obvious alternative is to reconcile a built-in
/// list against the table on every launch, and it answers the question "why is the prompt I deleted
/// back again?" with "because Bloom puts it there every time you start it". Instead each built-in
/// says which seed version introduced it, the store remembers the version it last seeded, and only
/// the entries newer than that are inserted. A prompt deleted by the owner is a row that is gone,
/// nothing looks for it again, and a second built-in added later inserts itself and resurrects
/// nothing.
///
/// The version is a plain integer rather than the app's own version, because it counts changes to
/// this list and nothing else: shipping a build that adds no built-in must not reseed anything.
public enum QuickPromptSeed {
    /// One built-in, as it is written here rather than as it is stored. It has no id: the row gets
    /// one when it is inserted, so a seeded prompt is an ordinary prompt from that moment on, with
    /// nothing about it that a hand written one does not have.
    public struct Entry: Sendable, Hashable {
        public var name: String
        public var symbol: String
        public var text: String
        /// The seed version that first shipped this entry. Anything above the version a database
        /// has already seen is inserted; anything at or below it has had its chance.
        public var introducedIn: Int

        public init(name: String, symbol: String, text: String, introducedIn: Int) {
            self.name = name
            self.symbol = symbol
            self.text = text
            self.introducedIn = introducedIn
        }

        public func prompt(sortOrder: Int, now: Date = Date()) -> QuickPrompt {
            QuickPrompt(
                name: name, symbol: symbol, text: text, sortOrder: sortOrder, createdAt: now
            )
        }
    }

    /// What the store keeps the last seeded version under, in the settings table.
    public static let versionKey = "quickPrompts.seedVersion"

    /// The highest `introducedIn` on the list below, written down once so the store has something
    /// to record without having to search for the maximum.
    public static let version = 1

    public static let all: [Entry] = [
        // The one Bloom ships with. It is deletable, like everything else here, and deleting it
        // sticks: see the note at the head of this file.
        Entry(
            name: "Explain changes",
            symbol: "doc.richtext",
            text: """
            Explain the changes made in this PR as HTML. Open it as a new tab in this workspace.
            """,
            introducedIn: 1
        ),
    ]

    /// The built-ins a database that last seeded `installed` has not been offered yet.
    ///
    /// Pure, so the whole of the rule can be held still by a test: seeding twice inserts nothing
    /// the second time, and a database seeded at version 1 gets only what version 2 added.
    public static func pending(installed: Int) -> [Entry] {
        all.filter { $0.introducedIn > installed }
    }
}
