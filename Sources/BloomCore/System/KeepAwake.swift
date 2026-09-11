import Foundation

/// A session of keeping the Mac awake that somebody started by hand: for a while, until a time, or
/// until they stop it.
///
/// **Beside `SleepPrevention` rather than instead of it.** That switch holds the Mac open while an
/// agent is mid turn, which is the case nobody should have to think about. This is the other case,
/// asked for by name after using Amphetamine: a long run started before walking away, a download,
/// a build on another machine, where the person knows how long they want and would rather say so
/// than leave the switch on and remember to come back for it. Either one holds the assertion;
/// `holdsAwake` is the rule that combines them.
///
/// Persisted, so a session that was meant to last three hours still lasts three hours across a
/// relaunch, and one that ran out while Bloom was closed is simply gone.
public struct KeepAwakeSession: Sendable, Hashable, Codable {
    public var startedAt: Date
    /// When the session ends by itself, or nothing for one that runs until it is stopped.
    public var until: Date?

    public init(startedAt: Date, until: Date?) {
        self.startedAt = startedAt
        self.until = until
    }

    public static func indefinitely(from now: Date) -> KeepAwakeSession {
        KeepAwakeSession(startedAt: now, until: nil)
    }

    public static func lasting(_ seconds: TimeInterval, from now: Date) -> KeepAwakeSession {
        KeepAwakeSession(startedAt: now, until: now.addingTimeInterval(seconds))
    }

    public func isActive(at now: Date) -> Bool {
        guard let until else { return true }
        return until > now
    }
}

/// The rules and the words for keeping the Mac awake, wherever the question is asked: the usage
/// panel's Keep Awake card, the status item's right click menu, and the glyph beside the mark.
public enum KeepAwake {
    public static let sessionKey = "system.keepAwakeSession"

    public static let title = "Keep Awake"

    /// Drawn beside the mark in the menu bar whenever the assertion holds idle sleep off.
    ///
    /// **Because the switch that used to be the only sign of it said nothing.** A checkmark beside
    /// "Prevent Sleep While Agents Run" is a preference, and it read the same whether an agent was
    /// holding the Mac open right then or not. What somebody walking away needs to see is whether
    /// the machine will stay up, and a cup in the menu bar is what Amphetamine taught everyone to
    /// look for.
    public static let menuBarSymbol = "cup.and.saucer.fill"

    /// The same choices Amphetamine offers, trimmed to the ones a coding session needs.
    public static let minuteChoices = [5, 10, 15, 30, 45]
    public static let hourChoices = Array(1...12)

    /// Whether idle sleep should be held off right now.
    public static func holdsAwake(
        session: KeepAwakeSession?,
        whileAgentsRun: Bool,
        runningCount: Int,
        at now: Date
    ) -> Bool {
        (session?.isActive(at: now) ?? false)
            || SleepPrevention.preventsSleep(isEnabled: whileAgentsRun, runningCount: runningCount)
    }

    /// What the card says: whether the Mac will stay up, and why or for how long.
    public struct Status: Sendable, Hashable {
        public var isOn: Bool
        public var headline: String
        public var detail: String
    }

    public static let onHeadline = "Keeping this Mac awake"
    public static let offHeadline = "Sleep allowed"

    public static func status(
        session: KeepAwakeSession?,
        whileAgentsRun: Bool,
        runningCount: Int,
        at now: Date,
        clock: UsageTimeFormat = .automatic,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> Status {
        if let session, session.isActive(at: now) {
            guard let until = session.until else {
                return Status(isOn: true, headline: onHeadline, detail: "Until you stop it")
            }
            let clockTime = UsageFormat.timeOfDay(until, clock: clock, calendar: calendar, locale: locale)
            let left = UsageFormat.compactDuration(until.timeIntervalSince(now))
            return Status(isOn: true, headline: onHeadline, detail: "\(left) left, until \(clockTime)")
        }
        if SleepPrevention.preventsSleep(isEnabled: whileAgentsRun, runningCount: runningCount) {
            let verb = runningCount == 1 ? "runs" : "run"
            return Status(isOn: true, headline: onHeadline, detail: "While \(Counted.of(runningCount, "agent")) \(verb)")
        }
        return Status(
            isOn: false,
            headline: offHeadline,
            detail: whileAgentsRun ? "Stays awake while agents run" : "Nothing is keeping this Mac awake"
        )
    }

    public static func label(minutes: Int) -> String { Counted.of(minutes, "minute") }
    public static func label(hours: Int) -> String { Counted.of(hours, "hour") }

    /// A time of day picked without a date, as the next moment it comes round: 17:30 picked at
    /// 16:00 is today, picked at 18:00 is tomorrow. Nobody asking to stay awake "until half past
    /// five" means a time already gone.
    public static func nextOccurrence(of time: Date, after now: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.nextDate(
            after: now,
            matching: DateComponents(hour: parts.hour, minute: parts.minute, second: 0),
            matchingPolicy: .nextTime
        ) ?? now
    }

    public static func load(from defaults: UserDefaults = .standard, at now: Date = Date()) -> KeepAwakeSession? {
        guard let data = defaults.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(KeepAwakeSession.self, from: data),
              session.isActive(at: now)
        else { return nil }
        return session
    }

    public static func save(_ session: KeepAwakeSession?, to defaults: UserDefaults = .standard) {
        guard let session, let data = try? JSONEncoder().encode(session) else {
            defaults.removeObject(forKey: sessionKey)
            return
        }
        defaults.set(data, forKey: sessionKey)
    }
}
