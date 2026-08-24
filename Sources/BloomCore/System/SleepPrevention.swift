import Foundation

/// Whether the Mac is allowed to fall asleep while agents are working, and the words used to say
/// so wherever the question is asked.
///
/// A type of its own, in the core, for the reason `DockBadge` is: the answer is a judgement rather
/// than a passthrough. It decides what the assertion covers, what it deliberately does not cover,
/// and what the default is, and all three are the kind of thing that drifts once two surfaces
/// each keep their own copy. There are two surfaces here (the Settings pane and the menu bar
/// item), so the copy and the default live in one place and both read them.
public enum SleepPrevention {
    /// The user default. Read by the Settings toggle, by the menu bar item, and by whatever puts
    /// the assertion in place.
    public static let settingKey = "system.preventsSleepWhileRunning"

    /// On unless it has been turned off.
    ///
    /// Two reasons, and the second is the stronger one. An agent turn that dies because the
    /// machine slept underneath it is a silent failure: nothing is logged, the transcript simply
    /// stops, and the user is left to guess. That is the worst class of bug to ship as a default.
    ///
    /// And this is not actually a new behaviour to opt into. Bloom has been holding
    /// `PreventUserIdleSystemSleep` for the whole length of every turn since the App Nap assertion
    /// was added, because `NSActivityUserInitiated` has `NSActivityIdleSystemSleepDisabled` inside
    /// it. Shipping this switch defaulted off would quietly take away something that already
    /// worked, which is a strange thing for a feature request to do.
    public static let isOnByDefault = true

    /// The Settings row.
    public static let settingTitle = "Keep the Mac awake while agents are running"

    /// Said in terms of what it does and what it leaves alone, because "keep awake" is read by
    /// most people as "keep the screen on", which this deliberately does not do.
    public static let settingDetail =
        "Idle sleep is held off from the moment an agent starts until the last one finishes. The display still dims and sleeps as usual."

    /// The menu bar item's first row.
    ///
    /// One fixed phrase with a checkmark beside it rather than a label that rewrites itself
    /// between "Allow Sleep" and "Prevent Sleep". A menu item whose text flips is ambiguous about
    /// whether it is reporting the state or offering the action.
    public static let menuItemTitle = "Prevent Sleep While Agents Run"

    /// The part users will otherwise discover the hard way, on both surfaces.
    ///
    /// Idle sleep is the only kind of sleep a power assertion can hold off. Closing the lid is not
    /// idle sleep: on a MacBook it sleeps the machine outright unless it is on power with an
    /// external display attached, and no assertion any application can take changes that. It also
    /// applies on battery, which is a real cost and is said rather than hidden.
    public static let caveat =
        "Closing the lid still sleeps the Mac, and the agents stop with it. This applies on battery too, so a long run away from power will keep the machine awake and drain it."

    /// Whether the assertion should currently be held open against sleep.
    ///
    /// Both halves matter. The setting alone is not enough, because an app that never lets an
    /// idle Mac sleep is a bad citizen; the running count alone is not enough, because the whole
    /// point of the setting is that some people would rather their machine slept.
    public static func preventsSleep(isEnabled: Bool, runningCount: Int) -> Bool {
        isEnabled && runningCount > 0
    }
}
