import Foundation

/// Every number and every countdown the usage panel prints, in one voice.
///
/// **The wording is OpenUsage's, on purpose.** The panel was redrawn to match that app, and the
/// part of it people read is these strings: "99% left", "Resets in 4h 57m", "Limit in 3h 45m".
/// A panel that looks like it and speaks differently is a panel that looks borrowed, so the
/// arithmetic is ported rather than paraphrased: minutes round up, "4d 0h" keeps its zero, and
/// anything within five minutes of a reset is "soon" because the provider's clock and this one are
/// not the same clock.
///
/// `Locale`, the calendar and the clock style are parameters, so a test can pin every one of them.
public enum UsageFormat {
    /// "18d 23h", "4h 57m", "5h", "12m". Never seconds, and never zero minutes: a window that
    /// resets in forty seconds resets in "1m".
    public static func compactDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int((seconds / 60).rounded(.up)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// How close to a deadline counts as "soon" rather than as a countdown.
    public static let soonThreshold: TimeInterval = 5 * 60

    /// "Resets in 4h 57m", or "Resets soon" inside the last five minutes and after the moment has
    /// passed.
    public static func relative(_ prefix: String, until date: Date, from now: Date) -> String {
        let remaining = date.timeIntervalSince(now)
        guard remaining > soonThreshold else { return "\(prefix) soon" }
        return "\(prefix) in \(compactDuration(remaining))"
    }

    /// "Resets today at 5:30 PM", "Resets tomorrow at 9:00", "Resets Feb 15 at 3:45 PM".
    public static func absolute(
        _ prefix: String,
        at date: Date,
        from now: Date,
        clock: UsageTimeFormat = .automatic,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard date.timeIntervalSince(now) > 0 else { return "\(prefix) soon" }
        let time = timeOfDay(date, clock: clock, calendar: calendar, locale: locale)
        if calendar.isDate(date, inSameDayAs: now) { return "\(prefix) today at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "\(prefix) tomorrow at \(time)"
        }
        let formatter = formatter(calendar: calendar, locale: locale)
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(prefix) \(formatter.string(from: date)) at \(time)"
    }

    /// The deadline in whichever of the two forms the setting asks for.
    public static func deadline(
        _ prefix: String,
        at date: Date,
        from now: Date,
        display: UsageResetDisplay,
        clock: UsageTimeFormat = .automatic,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        switch display {
        case .countdown: relative(prefix, until: date, from: now)
        case .exactTime: absolute(prefix, at: date, from: now, clock: clock, calendar: calendar, locale: locale)
        }
    }

    /// The time of day, on the clock the setting asks for.
    ///
    /// Fixed patterns for the two forced clocks rather than a format style's hour field, because a
    /// style's `hour` still follows the locale's own cycle: an American locale asked for the 24
    /// hour clock came back as "5:30", meaning half past five in the afternoon.
    static func timeOfDay(
        _ date: Date,
        clock: UsageTimeFormat,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = formatter(calendar: calendar, locale: locale)
        switch clock {
        case .automatic:
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        case .twelveHour:
            formatter.dateFormat = "h:mm a"
        case .twentyFourHour:
            formatter.dateFormat = "HH:mm"
        }
        return formatter.string(from: date)
    }

    private static func formatter(calendar: Calendar, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return formatter
    }

    /// A whole percentage, clamped. "42%".
    public static func percent(_ value: Double) -> String {
        "\(Int(min(max(value, 0), 100).rounded()))%"
    }

    /// Money as a row prints it: "$17.20", "$2.1K" from a thousand up.
    public static func money(_ amount: Double, code: String = "USD", locale: Locale = Locale(identifier: "en_US")) -> String {
        if abs(amount) >= 1000 { return compactMoney(amount, code: code, locale: locale) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = code.uppercased()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }

    /// Money as the menu bar prints it: whole units, "$130", and "$2.1K" from a thousand up.
    public static func trayMoney(_ amount: Double, code: String = "USD", locale: Locale = Locale(identifier: "en_US")) -> String {
        if abs(amount) >= 1000 { return compactMoney(amount, code: code, locale: locale) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = code.uppercased()
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: amount.rounded())) ?? "\(Int(amount.rounded()))"
    }

    static func compactMoney(_ amount: Double, code: String, locale: Locale) -> String {
        let symbol = currencySymbol(code: code, locale: locale)
        let compact = amount.formatted(
            .number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale)
        )
        return symbol + compact
    }

    static func currencySymbol(code: String, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = code.uppercased()
        return formatter.currencySymbol ?? code.uppercased()
    }

    /// A count, with thousands folded: "821", "12.9K".
    public static func count(_ value: Double, locale: Locale = Locale(identifier: "en_US")) -> String {
        if abs(value) >= 1000 {
            return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
        }
        return value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }
}
