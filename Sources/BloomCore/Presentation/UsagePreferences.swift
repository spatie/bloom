import Foundation

/// The choices the usage panel's own Settings screen offers, and the keys they are kept under.
///
/// In the core so the meter reading, the strip and the tests can take them as plain values; the
/// panel binds them through `@AppStorage` under the keys below. Every raw value is what is written
/// to `UserDefaults`, so none of them may be renamed.
public enum UsagePreferenceKey {
    public static let layout = "menuBar.usage.layout"
    /// "Count" in the Menu Bar pane: what is left, or what has gone.
    public static let meterStyle = "menuBar.usage.meterStyle"
    /// "Figures": numbers beside each mark, or a small bar for each.
    public static let iconStyle = "menuBar.usage.iconStyle"
    /// Whether the item carries figures at all. Off leaves Bloom's mark alone.
    public static let showsUsage = "menuBar.usage.showsFigures"
    /// Whether a cup is drawn while the Mac is being kept awake.
    public static let showsCup = "menuBar.usage.showsCup"
}

/// Whether a meter reads as what is left or as what has gone.
///
/// Left by default, as OpenUsage ships it: a fresh window reads "100% left", and the number that
/// shrinks is the number somebody is rationing.
public enum UsageMeterStyle: String, CaseIterable, Sendable {
    case left
    case used

    public var title: String {
        switch self {
        case .left: "Left"
        case .used: "Used"
        }
    }

    public var toggled: UsageMeterStyle { self == .left ? .used : .left }
}

/// Whether a reset reads as a countdown or as a clock time.
public enum UsageResetDisplay: String, CaseIterable, Sendable {
    case countdown
    case exactTime

    public var title: String {
        switch self {
        case .countdown: "Countdown"
        case .exactTime: "Exact Time"
        }
    }

    public var toggled: UsageResetDisplay { self == .countdown ? .exactTime : .countdown }
}

/// The clock an exact time is printed on.
public enum UsageTimeFormat: String, CaseIterable, Sendable {
    case automatic = "auto"
    case twelveHour = "12h"
    case twentyFourHour = "24h"

    public var title: String {
        switch self {
        case .automatic: "Auto"
        case .twelveHour: "12-hour"
        case .twentyFourHour: "24-hour"
        }
    }
}

/// What the menu bar item draws for the starred metrics.
public enum MenuBarIconStyle: String, CaseIterable, Sendable {
    /// Each provider's mark with its one or two figures beside it.
    case text
    /// Up to four thin bars in one square, for somebody who wants the shape and not the numbers.
    case bars

    public var title: String {
        switch self {
        case .text: "Text"
        case .bars: "Bars"
        }
    }
}

/// How tightly the panel is set.
public enum UsageDensity: String, CaseIterable, Sendable {
    case regular
    case compact

    public var title: String {
        switch self {
        case .regular: "Default"
        case .compact: "Compact"
        }
    }
}

/// The three display choices a meter reading depends on, bundled so a reading can be taken with
/// one argument and pinned in a test with one value.
public struct UsageDisplayOptions: Sendable, Hashable {
    public var meterStyle: UsageMeterStyle
    public var resetDisplay: UsageResetDisplay
    public var alwaysShowsPacing: Bool
    public var timeFormat: UsageTimeFormat
    public var calendar: Calendar
    public var locale: Locale

    public init(
        meterStyle: UsageMeterStyle = .left,
        resetDisplay: UsageResetDisplay = .countdown,
        alwaysShowsPacing: Bool = false,
        timeFormat: UsageTimeFormat = .automatic,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) {
        self.meterStyle = meterStyle
        self.resetDisplay = resetDisplay
        self.alwaysShowsPacing = alwaysShowsPacing
        self.timeFormat = timeFormat
        self.calendar = calendar
        self.locale = locale
    }
}
