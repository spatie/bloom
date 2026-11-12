import Foundation

/// The stronger model a Claude Code chat may consult in the middle of a turn.
///
/// Stated through the `advisorModel` setting, never `--advisor`: a pairing the CLI refuses then
/// drops the advisor for the session, where the flag stops the chat from starting at all.
public enum ClaudeAdvisor: String, CaseIterable, Identifiable, Sendable {
    /// Bloom says nothing, so an `advisorModel` in the user's own Claude settings still applies.
    case inherit
    case sonnet
    case opus
    case fable

    public var id: String { rawValue }

    public init(stored: String?) {
        self = stored.flatMap(ClaudeAdvisor.init(rawValue:)) ?? .inherit
    }

    public var label: String {
        switch self {
        case .inherit: "Not set"
        case .sonnet: "Sonnet"
        case .opus: "Opus"
        case .fable: "Fable"
        }
    }

    /// The alias the CLI resolves, or nil where there is nothing to state or to store.
    public var settingValue: String? {
        self == .inherit ? nil : rawValue
    }
}
