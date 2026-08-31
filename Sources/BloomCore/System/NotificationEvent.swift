import Foundation

/// The things Bloom is willing to interrupt somebody for.
///
/// Separate cases rather than one switch, because they differ in how badly they want attention.
/// "The turn finished" is the reason this app exists and somebody waiting on six agents wants all
/// of them. "Checks went green" is a nicety that a person who watches pull requests in a browser
/// will find noisy. One toggle for the lot would force them to choose between all of it and none.
public enum NotificationEvent: String, CaseIterable, Sendable, Hashable, Codable {
    case turnFinished
    case needsInput
    case agentFailed
    case setupFailed
    case checksFinished

    /// The settings row's label.
    public var title: String {
        switch self {
        case .turnFinished: "An agent finishes its turn"
        case .needsInput: "An agent needs something from me"
        case .agentFailed: "An agent stops without finishing"
        case .setupFailed: "A setup script fails"
        case .checksFinished: "Checks finish on a pull request"
        }
    }

    /// The settings row's help text. Says what the event actually is, because three of these five
    /// are indistinguishable from "it finished" unless somebody explains the difference.
    public var detail: String {
        switch self {
        case .turnFinished:
            "The agent has answered and is waiting for you."
        case .needsInput:
            "The turn ended without doing the work: a permission was denied, or it ran out of turns."
        case .agentFailed:
            "The agent exited without finishing. A model it does not know, expired credentials, a crash."
        case .setupFailed:
            "The workspace was created but its setup script exited non-zero, so no agent was started."
        case .checksFinished:
            "CI on the workspace's pull request went from pending to a result."
        }
    }

    /// What the body says when there is nothing more specific to put in it.
    public var fallbackDetail: String {
        switch self {
        case .turnFinished: "The agent finished its turn."
        case .needsInput: "The agent needs something from you before it can carry on."
        case .agentFailed: "The agent stopped without finishing the turn."
        case .setupFailed: "The setup script failed. The agent was started anyway."
        case .checksFinished: "The checks finished."
        }
    }

    /// The title of the one banner that stands in for several of these at once.
    public func summaryTitle(count: Int) -> String {
        switch self {
        case .turnFinished: "\(count) agents finished"
        case .needsInput: "\(count) agents need you"
        case .agentFailed: "\(count) agents stopped"
        case .setupFailed: "Setup failed in \(count) workspaces"
        case .checksFinished: "Checks finished in \(count) workspaces"
        }
    }
}

/// One person's answer to "what may interrupt me", as a value, so the rule that reads it can be
/// tested without a `UserDefaults` anywhere near it.
public struct NotificationSettings: Sendable, Hashable {
    public var isEnabled: Bool
    public var enabledEvents: Set<NotificationEvent>

    public init(
        isEnabled: Bool = false,
        enabledEvents: Set<NotificationEvent> = Set(NotificationEvent.allCases)
    ) {
        self.isEnabled = isEnabled
        self.enabledEvents = enabledEvents
    }

    public func allows(_ event: NotificationEvent) -> Bool {
        isEnabled && enabledEvents.contains(event)
    }
}

/// Where the toggles live.
///
/// User defaults rather than the `SettingsLoader` chain, for the reason spelled out on
/// `PromptOverrides`: that chain is read-only TOML describing a repository, and this describes a
/// person. The keys are public because the settings form binds to them with `@AppStorage`, and the
/// two have to be reading the same strings or the window will show one thing while the rule that
/// decides whether to interrupt somebody obeys another.
///
/// `@unchecked Sendable` for the same reason as `PromptOverrides`: `UserDefaults` is documented as
/// thread safe but is not annotated, and nothing else is stored here.
public struct NotificationPreferences: @unchecked Sendable {
    public static let enabledKey = "notifications.enabled"
    public static let eventKeyPrefix = "notifications.event."

    public static func key(for event: NotificationEvent) -> String {
        eventKeyPrefix + event.rawValue
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Off until somebody says otherwise. `UserDefaults.bool(forKey:)` already answers false for a
    /// key nobody has written, which is the answer this one wants.
    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// Absent means on. Read through `object(forKey:)` rather than `bool(forKey:)`, which answers
    /// false for an untouched key: the form shows these as on by default, and if the two disagreed
    /// the window would draw five switches in the on position while none of them fired.
    public func isEnabled(_ event: NotificationEvent) -> Bool {
        defaults.object(forKey: Self.key(for: event)) as? Bool ?? true
    }

    public func setEnabled(_ value: Bool, for event: NotificationEvent) {
        defaults.set(value, forKey: Self.key(for: event))
    }

    public var settings: NotificationSettings {
        NotificationSettings(
            isEnabled: isEnabled,
            enabledEvents: Set(NotificationEvent.allCases.filter(isEnabled))
        )
    }
}
