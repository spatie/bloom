import AppKit
import SwiftUI

/// Which face the conversation is set in.
///
/// Four, and every one of them already ships with macOS. Bundling a face would mean a licence to
/// read, weight in the bundle and a redistribution question to answer before Bloom can be signed
/// and notarised, and none of that buys anything a system face does not already do.
///
/// The set was picked by rendering real transcript content at the real rungs, in both appearances,
/// and three things decided it.
///
/// **Figures.** Georgia is the sturdiest screen serif on the machine and it is not here, because
/// its only numerals are old style: `+118 -4`, `01:23` and a token count come out with descenders
/// and varying heights, they do not line up in a column, and `monospacedDigit()` cannot fix it
/// because Georgia has no lining set to switch to. A transcript full of counts sitting beside a
/// sidebar that renders the same counts in SF is the one place that mismatch is unmissable.
///
/// **Being enumerable.** Iowan Old Style and Athelas are on the disk and resolve through
/// `NSFont(name:)`, but neither appears in `CTFontManagerCopyAvailableFontFamilyNames()`, which is
/// what a face that has been disabled or never downloaded looks like. Offering one would mean a
/// picker whose third option silently does nothing on somebody else's Mac.
///
/// **The mono pairing.** See `inlineCodeScale`.
enum ChatFont: String, CaseIterable, Identifiable, Sendable {
    /// San Francisco, by way of `Font.system`. What Bloom was set in before there was a choice.
    case system
    /// New York, reached through the serif *design* rather than by name: it has no family name to
    /// ask for, and going through the design is also what keeps it a system font, so weights,
    /// italics and `monospaced()` all still resolve the way they do for San Francisco.
    case reading
    /// Charter, Matthew Carter's text face, which ships in `Supplemental` and is enumerable.
    case book
    /// Verdana, the widest letterforms and the largest x-height of anything installed.
    case legible

    static let defaultsKey = "chat.font"

    /// San Francisco, the same face as the chrome around the conversation.
    ///
    /// New York held this slot for a while, on the argument that an agent transcript is
    /// paragraphs and New York is Apple's face for paragraphs. That argument is sound about
    /// prose and wrong about this prose. A turn is not an essay: it is a few sentences wrapped
    /// around filenames, symbols, paths and diff counts, all of which are set in the mono face,
    /// and a serif body puts a second voice next to that on every line. The reading matter here
    /// has more in common with the interface than with a book.
    ///
    /// The face is still a setting, and Reading is one line down for anyone who wants it.
    static let standard = ChatFont.system

    var id: String { rawValue }

    /// What the face is for rather than what it is called. The family name is in `summary`, where
    /// somebody who wants to know can read it without the control turning into a font menu.
    var title: String {
        switch self {
        case .system: "System"
        case .reading: "Reading"
        case .book: "Book"
        case .legible: "Legible"
        }
    }

    var summary: String {
        switch self {
        case .system:
            "San Francisco, the face the rest of macOS is set in. Drawn for labels and controls."
        case .reading:
            "New York, Apple's serif companion to San Francisco, drawn for paragraphs."
        case .book:
            "Charter, a book face that keeps its shape at small sizes and sets a little lighter."
        case .legible:
            "Verdana, the widest letterforms and the largest x-height, at the cost of a longer line."
        }
    }

    /// The installed family to ask for by name, where there is one. `system` and `reading` are
    /// both system faces and are reached through a `Font.Design` instead.
    private var familyName: String? {
        switch self {
        case .system, .reading: nil
        case .book: "Charter"
        case .legible: "Verdana"
        }
    }

    /// How large a span of inline code is set against the prose around it.
    ///
    /// Inline code is always SF Mono, whatever the prose face is, because it is the face every
    /// code block, path and diff in the window is already in and a paragraph is not the place to
    /// introduce a second one. What has to be tuned is the size, because two faces at the same
    /// point size are not the same size on the page: SF Mono's x-height at 13 points is 6.87, and
    /// New York's is 6.30 and Charter's 6.32. Set at a matching 13 the code runs read a size
    /// larger than the sentence holding them and pull the eye off the prose.
    ///
    /// 0.92 is that ratio, which lands inline code on 12 whole points against 13 point prose.
    /// San Francisco (6.84) and Verdana (7.09) already sit within a rounded point of the mono, so
    /// they ask for nothing.
    var inlineCodeScale: CGFloat {
        switch self {
        case .system, .legible: 1
        case .reading, .book: 0.92
        }
    }

    /// Nil where the face is the system one, which is what lets `ScaledFont` keep returning the
    /// exact `Font` it returned before any of this existed.
    var design: Font.Design? {
        switch self {
        case .system: nil
        case .reading: .serif
        case .book, .legible: nil
        }
    }

    func font(size: CGFloat, weight: Font.Weight) -> Font {
        if let design {
            return .system(size: size, weight: weight, design: design)
        }
        guard let familyName, isInstalled else {
            return .system(size: size, weight: weight)
        }
        // `fixedSize`, not `size`: the point size has already been resolved against the
        // conversation's scale, and the dynamic-type form would ask macOS to scale it a second
        // time against a setting this app has established does nothing here anyway.
        return .custom(familyName, fixedSize: size).weight(weight)
    }

    /// The same face as an `NSFont`, for the composer, which is a real `NSTextView` and cannot be
    /// handed a SwiftUI `Font`.
    func nsFont(size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size)
        if let design {
            return system.fontDescriptor.withDesign(design.appKitDesign)
                .flatMap { NSFont(descriptor: $0, size: size) } ?? system
        }
        guard let familyName else { return system }
        return NSFont(name: familyName, size: size) ?? system
    }

    /// Whether the family is actually on this machine.
    ///
    /// Checked rather than assumed, because a `Font.custom` naming a family that is not there
    /// falls back to the system face without saying so, and a setting that silently does nothing
    /// is worse than one that is not offered. All four options here are enumerable on a stock
    /// macOS, so this only answers false for a Mac whose owner has disabled a font in Font Book.
    var isInstalled: Bool {
        guard let familyName else { return true }
        return Self.installedFamilies.contains(familyName)
    }

    /// Resolved once for the process. This is asked on the way to every rung of every row, and a
    /// transcript is tens of thousands of them, where `NSFont(name:)` is a CoreText lookup and a
    /// set membership is not. A font installed while Bloom is running is not picked up until the
    /// next launch, which is the same deal every other Mac app offers.
    private static let installedFamilies: Set<String> = {
        Set(allCases.compactMap(\.familyName).filter { NSFont(name: $0, size: 13) != nil })
    }()
}

private extension Font.Design {
    /// The AppKit spelling of the design, so the composer can ask for the same face the transcript
    /// does. Only the designs `ChatFont` actually uses are mapped; anything else is the system
    /// face, which is what `nsFont(size:)` would have fallen back to anyway.
    var appKitDesign: NSFontDescriptor.SystemDesign {
        switch self {
        case .serif: .serif
        case .monospaced: .monospaced
        case .rounded: .rounded
        default: .default
        }
    }
}

extension EnvironmentValues {
    /// The face every proportional rung of `Typo` resolves to inside a subtree. It sits beside
    /// `fontScale` and is scoped the same way: one value, set once on the conversation, so the
    /// two hundred call sites that write `.font(Typo.body)` never learn there is a setting.
    @Entry var chatFont: ChatFont = .system
}
