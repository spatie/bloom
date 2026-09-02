import AppKit
import CoreText
import SwiftUI
import BloomCore

/// A face the conversation is set in, ready to draw.
///
/// The choosing, the migrating and the falling back are all `ChatFontCatalogue` in the core, where
/// tests can reach them. What is left here is the half that cannot leave the app target: asking
/// AppKit which families this Mac has, and turning a resolved `ChatFace` into a `Font` and an
/// `NSFont`. Read the catalogue's head for why the setting is a family name now rather than one
/// of four cases.
///
/// A value type rather than a lookup at every call site, because the three answers below are
/// worked out once, when the setting is read, and then handed to the transcript through the
/// environment. `resolved(scale:face:)` is asked on the way to every rung of every row, and a
/// transcript is tens of thousands of them: reading a stored property there is free, and a font
/// lookup would not be.
struct ChatFont: Hashable, Sendable {
    /// Exactly what is in `UserDefaults`, canonicalised. The picker's tags are these, so an old
    /// `book` arrives as `Charter` and the row that says Book is the one that shows as chosen.
    let rawValue: String
    /// What is actually drawn, which is the system face whenever `rawValue` names a family this
    /// Mac does not have.
    let face: ChatFace
    /// See `ChatFontCatalogue.inlineCodeScale`. Measured here, because an x-height is a question
    /// for CoreText, and applied by `ScaledFont.monospacedCompanion`.
    let inlineCodeScale: CGFloat

    init(rawValue: String) {
        let id = ChatFontCatalogue.canonicalID(rawValue)
        let resolved = ChatFontCatalogue.resolve(id, installed: Self.installedFamilies)
        self.rawValue = id
        face = resolved
        inlineCodeScale = CGFloat(
            ChatFontCatalogue.inlineCodeScale(
                faceXHeight: Double(Self.nsFont(for: resolved, size: Self.metricSize).xHeight),
                monoXHeight: Double(Self.monoXHeight)
            )
        )
    }

    /// The `UserDefaults` slot and the value in it when nobody has chosen. Both forwarded rather
    /// than restated, so the views that read the setting keep naming the app-side type while the
    /// core stays the one place either can change.
    static let defaultsKey = ChatFontCatalogue.defaultsKey
    static let standardID = ChatFontCatalogue.standardID

    /// San Francisco, and what every surface falls back to. See `ChatFontCatalogue.standardID`.
    static let standard = ChatFont(rawValue: standardID)

    /// The default argument of every `ScaledFont` method, and the value the environment starts at.
    static let system = standard

    /// Whether this resolves to the system face, which is the question `ScaledFont` asks before
    /// deciding whether to leave a rung exactly as it was. Not `self == .system`: a family that
    /// has been uninstalled is drawn in San Francisco while still being stored as itself, and
    /// that case has to take the same path as an unset setting rather than the custom-font one.
    var isSystemFace: Bool { face == .system }

    /// The lower half of the picker: every family a paragraph is legible in, with whatever is
    /// selected kept on the list even when it is not installed any more.
    ///
    /// Family names rather than `ChatFont` values, because there are a couple of hundred of them
    /// and each of these would otherwise measure an x-height it has no use for: a picker row needs
    /// the name it stores and the name it shows, and for a family those are the same string.
    static func familyChoices(keeping selected: String) -> [String] {
        ChatFontCatalogue.families(from: availableFamilies, keeping: selected)
    }

    /// The sentence under the picker, which for a family that has gone missing says so.
    static func summary(for stored: String) -> String {
        ChatFontCatalogue.summary(for: stored, installed: installedFamilies)
    }

    func font(size: CGFloat, weight: Font.Weight) -> Font {
        switch face {
        case .system:
            .system(size: size, weight: weight)
        case .serif:
            .system(size: size, weight: weight, design: .serif)
        case .family(let name):
            // `fixedSize`, not `size`: the point size has already been resolved against the
            // conversation's scale, and the dynamic-type form would ask macOS to scale it a second
            // time against a setting this app has established does nothing here anyway.
            .custom(name, fixedSize: size).weight(weight)
        }
    }

    /// The same face as an `NSFont`, for the composer and the transcript's text views, which are
    /// real `NSTextView`s and cannot be handed a SwiftUI `Font`.
    func nsFont(size: CGFloat) -> NSFont { Self.nsFont(for: face, size: size) }

    private static func nsFont(for face: ChatFace, size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size)
        switch face {
        case .system:
            return system
        case .serif:
            return system.fontDescriptor.withDesign(.serif)
                .flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case .family(let name):
            // By the family attribute rather than `NSFont(name:)`, which is documented as taking
            // a font name. Measured here the two agree on all 206 families installed, so this is
            // not a fix for a bug seen; it is asking by the attribute that means what is meant,
            // for a list that is now whatever is on somebody else's Mac rather than two names
            // checked by hand. A family with no face whose name matches it answers nil from the
            // name lookup and answers correctly from this one.
            let descriptor = NSFontDescriptor(fontAttributes: [.family: name])
            return NSFont(descriptor: descriptor, size: size) ?? system
        }
    }

    /// The size the x-heights in `ChatFontCatalogue.inlineCodeScale` were measured at. The ratio
    /// is scale-free in theory and not quite in practice, because hinting moves an x-height by a
    /// fraction of a point at small sizes, so it is asked at the size the transcript is set at.
    private static let metricSize: CGFloat = 13

    private static let monoXHeight = NSFont.monospacedSystemFont(
        ofSize: metricSize, weight: .regular
    ).xHeight

    /// Every family on this Mac, in the font manager's order.
    ///
    /// Resolved once for the process, because this is asked whenever the setting is read and the
    /// list runs to a few hundred names. A font installed while Bloom is running is not picked up
    /// until the next launch, which is the same deal every other Mac app offers.
    ///
    /// `CTFontManagerCopyAvailableFontFamilyNames` rather than
    /// `NSFontManager.shared.availableFontFamilies`. Measured on this Mac the two answer the same
    /// 206 names, and CoreText is the one with no main thread to be on: a `static let` is
    /// initialised lazily by whichever thread touches it first, and an AppKit singleton is not
    /// something to reach for from there. A family disabled in Font Book is in neither list,
    /// which is the point of asking rather than assuming.
    private static let availableFamilies: [String] =
        CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []

    private static let installedFamilies = Set(availableFamilies)

    /// Identity is the setting, not what it was resolved to. Two values with the same stored name
    /// are the same choice, and the face and the scale are both functions of that name.
    static func == (lhs: ChatFont, rhs: ChatFont) -> Bool { lhs.rawValue == rhs.rawValue }

    func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
}

extension EnvironmentValues {
    /// The face every proportional rung of `Typo` resolves to inside a subtree. It sits beside
    /// `fontScale` and is scoped the same way: one value, set once on the conversation, so the
    /// two hundred call sites that write `.font(Typo.body)` never learn there is a setting.
    @Entry var chatFont: ChatFont = .system
}
