import Foundation

/// Which face the conversation is set in, once a stored setting has been resolved against the
/// fonts this Mac actually has.
///
/// Three cases rather than a family name and a flag, because two of the faces Bloom offers have
/// no family name to ask for. San Francisco and New York are reached through a `Font.Design`, and
/// going through the design is what keeps them system fonts, so weights, italics and the
/// monospaced companion all still resolve.
public enum ChatFace: Hashable, Sendable {
    /// San Francisco, the face the rest of the window is set in.
    case system
    /// New York, Apple's serif companion, reached through the serif design.
    case serif
    /// A family installed on this Mac, named exactly as the font manager names it.
    case family(String)
}

/// One of the faces the picker recommends by name.
public struct ChatFontFace: Identifiable, Hashable, Sendable {
    /// What is written to `UserDefaults` when this face is chosen. A family name where there is
    /// one, so the stored setting names a font on the machine rather than a word only Bloom knows.
    public let id: String
    /// What the face is for rather than what it is called. The family name is in `summary`.
    public let title: String
    public let summary: String
    public let face: ChatFace

    public init(id: String, title: String, summary: String, face: ChatFace) {
        self.id = id
        self.title = title
        self.summary = summary
        self.face = face
    }
}

/// The faces the conversation can be set in: four Bloom recommends, then everything installed.
///
/// **What changed and why.** The setting used to be four cases, and two people asked for the font
/// they read in rather than the font Bloom picked for them. A closed enum cannot answer that, so
/// the stored value is now a string naming a font family, and the four recommendations are four
/// values of that string rather than four cases of a type. Nothing about the four changed: they
/// head the list, keep their names, and keep the sentence each one carried.
///
/// **The stored value is a family name, except twice.** `system` and `reading` stay words,
/// because San Francisco has no family name that survives a lookup and New York is reached
/// through the serif design rather than by name (see `ChatFace`). Book and Legible were only ever
/// labels over Charter and Verdana, so those two now store the family, which means somebody who
/// picks Charter from the long list and somebody who picks Book from the top of it end up with
/// one setting rather than two spellings of it. `canonicalID` is what makes the old spelling
/// arrive as the new one, and it is why nobody's chosen face is reset by this.
///
/// **An open set has to survive its own values going missing.** A family can be disabled in Font
/// Book, or live on a machine the defaults were not copied from, and a custom font naming a
/// family that is not there falls back to the system face without saying so. So `resolve` answers
/// `.system` for anything it cannot find and `summary` says out loud that it did, while the
/// missing name keeps its row in the picker. This is `ComposerOption.adding` and
/// `ModelAlias.cliValue` again: a value we do not recognise is kept, shown and handled, never
/// quietly rewritten to a default.
///
/// **Only the families a paragraph is legible in.** The font manager lists around three hundred
/// names on a stock macOS, and a handful of those cannot set a sentence at all: Wingdings, Zapf
/// Dingbats, Bodoni Ornaments and the emoji and Braille faces render a transcript as symbols or
/// as blanks. `families(from:)` drops those, along with the hidden names beginning with a full
/// stop, which are the system's own internal faces and not a choice anybody means to make.
/// Everything else is offered, display faces included, because "legible" past that point is taste
/// and this is a setting about taste.
public enum ChatFontCatalogue {
    /// The same `UserDefaults` slot the four-way control wrote, kept deliberately: the migration
    /// is a mapping of values, so a setting already made is still found where it was left.
    public static let defaultsKey = "chat.font"

    /// San Francisco, the same face as the chrome around the conversation.
    ///
    /// New York held this slot for a while, on the argument that an agent transcript is
    /// paragraphs and New York is Apple's face for paragraphs. That argument is sound about prose
    /// and wrong about this prose. A turn is not an essay: it is a few sentences wrapped around
    /// filenames, symbols, paths and diff counts, all of which are set in the mono face, and a
    /// serif body puts a second voice next to that on every line. The reading matter here has
    /// more in common with the interface than with a book.
    public static let standardID = "system"

    /// The four, in the order they were offered before there was a list under them.
    ///
    /// Every one of them already ships with macOS. Bundling a face would mean a licence to read,
    /// weight in the bundle and a redistribution question to answer before Bloom can be signed and
    /// notarised, and none of that buys anything a system face does not already do.
    ///
    /// Georgia is the sturdiest screen serif on the machine and it is not among the four, because
    /// its only numerals are old style: `+118 -4`, `01:23` and a token count come out with
    /// descenders and varying heights, and `monospacedDigit()` cannot fix it because Georgia has
    /// no lining set to switch to. It is on the long list now, which is the right place for it,
    /// picked deliberately by name rather than recommended to somebody who did not ask.
    public static let curated: [ChatFontFace] = [
        ChatFontFace(
            id: standardID,
            title: "System",
            summary: "San Francisco, the face the rest of macOS is set in. Drawn for labels and controls.",
            face: .system
        ),
        ChatFontFace(
            id: "reading",
            title: "Reading",
            summary: "New York, Apple's serif companion to San Francisco, drawn for paragraphs.",
            face: .serif
        ),
        ChatFontFace(
            id: "Charter",
            title: "Book",
            summary: "Charter, a book face that keeps its shape at small sizes and sets a little lighter.",
            face: .family("Charter")
        ),
        ChatFontFace(
            id: "Verdana",
            title: "Legible",
            summary: "Verdana, the widest letterforms and the largest x-height, at the cost of a longer line.",
            face: .family("Verdana")
        ),
    ]

    /// The two ids the four-way control wrote that are not what they are written as now.
    ///
    /// `system` and `reading` are absent because they did not move. Read on every load rather
    /// than rewritten once at launch, because a one-shot migration is a thing that has to have
    /// run: a defaults domain copied from another Mac, or a build rolled back and forward again,
    /// would each arrive with the old spelling long after the migration had been marked done.
    private static let legacyIDs = ["book": "Charter", "legible": "Verdana"]

    /// What a stored value means today. Empty and missing come back as the standard; anything
    /// else comes back as itself, so `resolve` is the only place that decides a value cannot be
    /// honoured.
    public static func canonicalID(_ stored: String?) -> String {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return standardID }
        return legacyIDs[trimmed] ?? trimmed
    }

    /// The face a stored value actually draws in, given the families this Mac has.
    ///
    /// The fallback is the system face rather than the nearest match or the previous choice,
    /// because there is no honest nearest match for a missing font, and a setting that silently
    /// becomes a different font is the thing this type is written against. `summary` tells the
    /// reader it happened and the picker keeps the missing name on its list, so plugging the disk
    /// the font lives on back in restores the face rather than asking for it to be chosen again.
    public static func resolve(_ stored: String?, installed: Set<String>) -> ChatFace {
        let id = canonicalID(stored)
        if let recommended = recommendation(for: id) {
            guard case .family(let name) = recommended.face else { return recommended.face }
            return installed.contains(name) ? recommended.face : .system
        }
        return installed.contains(id) ? .family(id) : .system
    }

    /// The recommendation a stored value names, if it names one.
    ///
    /// There is deliberately no companion returning a display name for the rest: a family that is
    /// not one of the four is called by its own name, and a function to say so would be a wrapper
    /// around the identity.
    public static func recommendation(for stored: String?) -> ChatFontFace? {
        let id = canonicalID(stored)
        return curated.first { $0.id == id }
    }

    /// The sentence under the picker. True of the face actually in force, which for a family that
    /// has gone missing means saying that it has.
    public static func summary(for stored: String?, installed: Set<String>) -> String {
        let id = canonicalID(stored)
        if let recommended = recommendation(for: id) {
            guard case .family(let name) = recommended.face, !installed.contains(name) else {
                return recommended.summary
            }
            return missingSummary(name)
        }
        guard installed.contains(id) else { return missingSummary(id) }
        return "\(id), one of the fonts installed on this Mac."
    }

    private static func missingSummary(_ name: String) -> String {
        "\(name) is not installed on this Mac. The conversation is set in San Francisco until you "
            + "choose another face."
    }

    /// The families to offer under the four, in the order a person reads a list of names.
    ///
    /// The recommendations are taken out rather than repeated, because their ids are the family
    /// names: Charter appearing twice in one picker would be two rows carrying the same tag, and
    /// the second of them would be the one that could never be selected.
    public static func families(from available: [String]) -> [String] {
        var seen = Set(curated.map(\.id))
        var result: [String] = []
        for family in available {
            let name = family.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSelectable(name), seen.insert(name).inserted else { continue }
            result.append(name)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The same list plus whatever is selected, so a face that is no longer installed still has a
    /// row to be selected in.
    ///
    /// `ComposerOption.adding` for a font: the value the app is in stays on the only control that
    /// could put it back. Without this, unplugging the disk a font lives on takes the setting off
    /// the picker, and choosing any other face is then a one-way door.
    public static func families(from available: [String], keeping selected: String?) -> [String] {
        let offered = families(from: available)
        let id = canonicalID(selected)
        guard !curated.contains(where: { $0.id == id }), !offered.contains(id) else { return offered }
        return offered + [id]
    }

    /// Whether a paragraph set in this family would be readable as text.
    ///
    /// A test on the name rather than on the glyphs, because the alternative is asking CoreText
    /// whether a family can render Latin, and every family that fails that here fails on its name
    /// too. The hidden faces are the ones whose names begin with a full stop, which is how macOS
    /// marks its own internal system fonts.
    private static func isSelectable(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        let symbolic = ["Emoji", "Dingbat", "Ornament", "Symbols", "Wingdings", "Webdings", "Braille"]
        guard !symbolic.contains(where: { name.localizedCaseInsensitiveContains($0) }) else { return false }
        return name.caseInsensitiveCompare("Symbol") != .orderedSame
    }

    /// How large a span of inline code is set against the prose around it.
    ///
    /// Inline code is always SF Mono, whatever the prose face is, because it is the face every
    /// code block, path and diff in the window is already in and a paragraph is not the place to
    /// introduce a second one. What has to be tuned is the size, because two faces at the same
    /// point size are not the same size on the page: SF Mono's x-height at 13 points is 6.87,
    /// New York's is 6.30 and Charter's is 6.32. Set at a matching 13, the code runs read a size
    /// larger than the sentence holding them and pull the eye off the prose.
    ///
    /// The four faces used to carry a hand-measured constant each. An open set cannot, so the
    /// constant became the ratio those numbers came from: matching the x-heights is what makes
    /// two faces look the same size. It reproduces all four to the digit, San Francisco (6.84)
    /// and Verdana (7.09) answering 1 and New York and Charter answering 0.92.
    ///
    /// Rounded to a hundredth, so a face lands on a whole point more often than not, and never
    /// above 1: code set larger than the sentence around it is the thing being fixed, and a face
    /// with a huge x-height would otherwise ask for exactly that. The floor is there for the
    /// opposite extreme, a display face with almost no x-height, where the honest ratio would set
    /// code too small to read.
    public static func inlineCodeScale(faceXHeight: Double, monoXHeight: Double) -> Double {
        guard faceXHeight > 0, monoXHeight > 0 else { return 1 }
        let ratio = (faceXHeight / monoXHeight * 100).rounded() / 100
        return min(1, max(0.8, ratio))
    }
}
