import Foundation

/// Which figure the activity rule draws while an agent is working.
///
/// Three of them, and they exist together on purpose. The rule has now been redrawn twice on the
/// strength of "it is not clear enough", and both times the argument was settled by putting the
/// candidates side by side rather than by describing them. `ActivityRuleGallery` draws every case
/// here at the width it is read at, so the next person to disagree has a picture to disagree with.
///
/// `live` is the one the window draws. Everything else is a page in that gallery.
public enum BusyRuleVariant: String, CaseIterable, Sendable {
    /// A lit track with one bright swelling crossing it, towards the edge the next word lands at.
    case crest
    /// The same crest repeated into a train, so every part of the rule is always moving.
    case current
    /// The whole width brightening and thickening at once, with no travel in it.
    case swell

    /// What the window draws.
    ///
    /// The crest. It is the only one of the three that is both **always lit** and **directional**:
    /// the track means a glance can never land on a dim frame, and the asymmetric head means a
    /// single frame says which way the line is running. `current` says both as well and says them
    /// everywhere at once, which is the reason it is not this: a hairline shimmering along its
    /// whole length reads as a progress bar, and a turn is not a progress bar. `swell` is what the
    /// rule already did, kept so the comparison has the incumbent in it.
    public static let live = BusyRuleVariant.crest

    /// What the gallery calls it.
    public var title: String {
        switch self {
        case .crest: "Crest"
        case .current: "Current"
        case .swell: "Swell"
        }
    }

    /// One line under that title, saying what the reader is looking at.
    public var note: String {
        switch self {
        case .crest:
            "A lit track and one crest crossing it, head first, once every three seconds."
        case .current:
            "The crest repeated into a train, sliding one wavelength a beat."
        case .swell:
            "The whole width brightening and thickening at once. No travel, and no direction."
        }
    }

    /// Whether the figure travels along the rule.
    ///
    /// Asked by the mark rather than switched on inside it, because it is also the answer to
    /// "does this one still say anything when it is held still", and that question is put to every
    /// variant on the same page.
    public var travels: Bool { self != .swell }
}
