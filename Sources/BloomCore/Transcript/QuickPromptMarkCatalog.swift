import Foundation

/// One mark the picker offers, with the words that find it.
public struct QuickPromptMarkChoice: Sendable, Hashable, Identifiable {
    public let mark: QuickPromptMark
    /// What typing in the picker's field is matched against.
    ///
    /// For a symbol it is the name with its full stops opened out, so `arrow.triangle.pull` is
    /// found by "triangle" as well as by "arrow". For an emoji it is a word somebody would go
    /// looking for it under, because an emoji carries no name of its own that a person would type.
    public let label: String

    public var id: String { mark.stored }

    public init(mark: QuickPromptMark, label: String) {
        self.mark = mark
        self.label = label
    }
}

/// A band of the picker, under a quiet heading.
public struct QuickPromptMarkSection: Sendable, Hashable, Identifiable {
    public let name: String
    public let choices: [QuickPromptMarkChoice]

    public var id: String { name }

    public init(name: String, choices: [QuickPromptMarkChoice]) {
        self.name = name
        self.choices = choices
    }
}

/// Everything a quick prompt can be marked with, grouped by what somebody would be writing a
/// prompt about.
///
/// **Grouped, and searchable by the group's own name.** A hundred symbols in one band is a wall,
/// and a name like `checkmark.seal` is not what anybody types when they want the mark for a test
/// run. So the section name is matched as well as the choice's label: "test" keeps the whole of
/// Tests and checks, which is the band that answers the question.
///
/// **A curated set of emoji rather than the system picker.** macOS already has a browser of every
/// emoji in Unicode behind Control-Command-Space, and it is the wrong tool here for the reason the
/// old symbol grid gave for having no symbol browser: the mark exists to tell five rows apart at a
/// glance, so choosing it should be smaller than writing the prompt. Four thousand emoji, most of
/// them flags and food, would make it larger. The set below is what somebody writing a prompt
/// about a build, a test, a bug or a review actually reaches for, and anything outside it still
/// works: `QuickPromptMark` classifies by the character's own properties, so an emoji pasted into
/// the row by hand is drawn as an emoji even though this list has never heard of it.
public enum QuickPromptMarkCatalog {
    public static let sections: [QuickPromptMarkSection] = [
        QuickPromptMarkSection(name: "Writing", choices: symbols([
            "text.alignleft", "text.quote", "square.and.pencil", "pencil.and.outline",
            "doc.text", "doc.richtext", "doc.plaintext", "note.text",
            "list.bullet", "list.number", "checklist", "book", "book.closed", "newspaper",
        ])),
        QuickPromptMarkSection(name: "Code and build", choices: symbols([
            "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces", "function",
            "hammer", "wrench.and.screwdriver", "gearshape", "gearshape.2",
            "cpu", "memorychip", "shippingbox", "cube", "command", "bolt",
        ])),
        QuickPromptMarkSection(name: "Tests and checks", choices: symbols([
            "checkmark.seal", "checkmark.circle", "checkmark.shield", "xmark.circle",
            "xmark.octagon", "exclamationmark.triangle", "exclamationmark.octagon", "testtube.2",
            "stethoscope", "waveform.path.ecg", "ladybug", "ant",
        ])),
        QuickPromptMarkSection(name: "Git and review", choices: symbols([
            "arrow.triangle.branch", "arrow.triangle.pull", "arrow.triangle.merge",
            "arrow.triangle.2.circlepath", "arrow.uturn.backward", "clock.arrow.circlepath",
            "tag", "bookmark", "eye", "eyes", "hand.thumbsup", "hand.thumbsdown",
        ])),
        QuickPromptMarkSection(name: "Search and files", choices: symbols([
            "magnifyingglass", "doc.text.magnifyingglass", "folder", "tray.full", "archivebox",
            "externaldrive", "square.stack.3d.up", "map", "binoculars", "paperclip",
        ])),
        QuickPromptMarkSection(name: "Cleaning up", choices: symbols([
            "trash", "scissors", "paintbrush", "paintbrush.pointed", "wand.and.rays",
            "sparkles", "sparkle", "minus.circle", "bandage",
        ])),
        QuickPromptMarkSection(name: "Shipping", choices: symbols([
            "paperplane", "airplane", "globe", "network", "server.rack", "icloud.and.arrow.up",
            "square.and.arrow.up", "antenna.radiowaves.left.and.right", "lock", "key",
        ])),
        QuickPromptMarkSection(name: "Asking and thinking", choices: symbols([
            "questionmark.circle", "lightbulb", "brain", "graduationcap", "person", "person.2",
            "bubble.left.and.bubble.right", "hand.raised", "megaphone", "target",
        ])),
        QuickPromptMarkSection(name: "Time and marks", choices: symbols([
            "clock", "timer", "calendar", "hourglass", "flag", "star", "heart", "pin", "bell",
            "chart.bar", "chart.line.uptrend.xyaxis",
        ])),
        QuickPromptMarkSection(name: "Emoji", choices: emoji([
            "\u{1F41B}": "bug", "\u{2705}": "check pass green", "\u{274C}": "cross fail red",
            "\u{26A0}\u{FE0F}": "warning", "\u{1F680}": "rocket ship launch",
            "\u{1F525}": "fire hot", "\u{2728}": "sparkles polish", "\u{1F3AF}": "target aim",
            "\u{1F9EA}": "test tube experiment", "\u{1F50D}": "search look",
            "\u{1F4DD}": "note write memo", "\u{1F4C4}": "page document",
            "\u{1F4DA}": "books docs", "\u{1F9F9}": "broom clean tidy",
            "\u{1F9F0}": "toolbox tools", "\u{1F527}": "wrench fix",
            "\u{1F528}": "hammer build", "\u{2699}\u{FE0F}": "gear settings",
            "\u{1F4E6}": "package box release", "\u{1F6A2}": "ship deploy",
            "\u{1F3D7}\u{FE0F}": "construction building", "\u{26A1}": "lightning fast speed",
            "\u{1F4A1}": "idea lightbulb", "\u{1F914}": "thinking",
            "\u{2753}": "question", "\u{1F4AC}": "comment chat", "\u{1F4E3}": "announce shout",
            "\u{1F440}": "eyes review look", "\u{1F9E0}": "brain think",
            "\u{1F91D}": "handshake agree", "\u{1F64F}": "please thanks",
            "\u{1F389}": "party done celebrate", "\u{1F3A8}": "art design paint",
            "\u{1F331}": "seedling new grow", "\u{1F343}": "leaf green",
            "\u{2615}": "coffee break", "\u{1F552}": "clock time later",
            "\u{1F512}": "lock secure", "\u{1F511}": "key secret",
            "\u{1F4CC}": "pin keep", "\u{1F9CA}": "ice freeze cold",
            "\u{1FA84}": "wand magic", "\u{1F480}": "skull dead danger",
            "\u{1F422}": "turtle slow",
        ])),
    ]

    /// Every choice, in the order the picker draws them. The flat list the keyboard steps through.
    public static let all: [QuickPromptMarkChoice] = sections.flatMap(\.choices)

    /// The sections a query keeps, each holding only the choices it kept.
    ///
    /// Containment rather than the fuzzy match the prompt list uses. A symbol name is two or three
    /// short words, so a subsequence match keeps most of a hundred of them for most queries, which
    /// is the same failure `QuickPromptTests.bodyIsNotFuzzy` records about matching a paragraph
    /// loosely: a filter that keeps everything cannot say that nothing matched.
    public static func filtered(query: String) -> [QuickPromptMarkSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            // The heading counts as a word of every choice under it, which is how "test" finds
            // `checkmark.seal` and "git" finds `arrow.triangle.branch`.
            if section.name.lowercased().contains(needle) { return section }
            let kept = section.choices.filter {
                $0.label.contains(needle) || $0.mark.stored.lowercased().contains(needle)
            }
            return kept.isEmpty ? nil : QuickPromptMarkSection(name: section.name, choices: kept)
        }
    }

    /// The mark `step` places along from this one, through the sections as one flat list.
    ///
    /// **Clamped at both ends rather than wrapped**, which is where this differs from the prompt
    /// list above it. That list is eight rows in one column, and wrapping off the bottom lands
    /// somewhere a person can still see. This is a hundred and fifty marks in nine bands, and
    /// wrapping from the last of them to the first scrolls the whole picker past everything the
    /// eye was following.
    public static func stepped(
        _ sections: [QuickPromptMarkSection], from mark: QuickPromptMark?, by step: Int
    ) -> QuickPromptMark? {
        let choices = sections.flatMap(\.choices)
        guard !choices.isEmpty else { return nil }
        guard let mark, let index = choices.firstIndex(where: { $0.mark == mark }) else {
            return step > 0 ? choices.first?.mark : choices.last?.mark
        }
        let next = min(max(index + step, 0), choices.count - 1)
        return choices[next].mark
    }

    /// Where the highlight goes once a query has filtered the list: it stays put when its mark
    /// survived, and otherwise moves to the first thing still on screen rather than pointing at
    /// something nobody can see.
    public static func settled(
        _ sections: [QuickPromptMarkSection], after mark: QuickPromptMark?
    ) -> QuickPromptMark? {
        let choices = sections.flatMap(\.choices)
        if let mark, choices.contains(where: { $0.mark == mark }) { return mark }
        return choices.first?.mark
    }

    /// A band of symbols, labelled by their own names with the full stops opened out.
    ///
    /// Derived rather than written by hand, because a hundred labels written out beside a hundred
    /// names is a hundred chances for the two to disagree, and nothing would catch it.
    private static func symbols(_ names: [String]) -> [QuickPromptMarkChoice] {
        names.map {
            QuickPromptMarkChoice(
                mark: .symbol($0),
                label: $0.replacingOccurrences(of: ".", with: " ").lowercased()
            )
        }
    }

    private static func emoji(_ entries: KeyValuePairs<String, String>) -> [QuickPromptMarkChoice] {
        entries.map { QuickPromptMarkChoice(mark: .emoji($0.key), label: $0.value) }
    }
}
