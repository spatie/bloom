import Foundation

/// The advisor one Claude Code chat asks for, over the app-wide one in Settings.
///
/// Per chat because a consultation rereads the whole conversation at the advisor's rate, so a
/// cheap task needs a way to switch it off.
public enum ChatAdvisor: String, CaseIterable, Identifiable, Sendable {
    /// Follows Settings, and is stored as no row so a later change there still reaches the chat.
    case appDefault = "default"
    case off
    case sonnet
    case opus
    case fable

    public var id: String { rawValue }

    public init(stored: String?) {
        self = stored.flatMap(ChatAdvisor.init(rawValue:)) ?? .appDefault
    }

    public var label: String {
        switch self {
        case .appDefault: "Default"
        case .off: "Off"
        case .sonnet: ClaudeAdvisor.sonnet.label
        case .opus: ClaudeAdvisor.opus.label
        case .fable: ClaudeAdvisor.fable.label
        }
    }

    public var storedValue: String? {
        self == .appDefault ? nil : rawValue
    }

    /// The one place the chat's choice meets the app-wide one, read by the runner for argv and by
    /// the transcript to decide whether a live process has to start again.
    public func resolved(over appWide: ClaudeAdvisor) -> AdvisorLaunch {
        switch self {
        case .appDefault: .consult(appWide)
        case .off: .off
        case .sonnet: .consult(.sonnet)
        case .opus: .consult(.opus)
        case .fable: .consult(.fable)
        }
    }

    /// No column on `Session`, for the output style's reason. See `ComposerControls`.
    public static func key(sessionID: SessionID) -> String {
        "session.\(sessionID).advisor"
    }

    /// A setting that cannot be read falls back to Settings, then to stating nothing.
    public static func launch(sessionID: SessionID, in store: Store) async -> AdvisorLaunch {
        let chat = ChatAdvisor(stored: try? await store.setting(key(sessionID: sessionID)))
        let appWide = ClaudeAdvisor(stored: try? await store.setting(AppDefaults.Key.advisor))
        return chat.resolved(over: appWide)
    }
}

/// What a Claude Code process is launched with for its advisor.
public enum AdvisorLaunch: Equatable, Sendable {
    /// `.inherit` states nothing, leaving the user's own Claude settings in charge.
    case consult(ClaudeAdvisor)
    /// Through the environment, because leaving `advisorModel` out would let the user's own
    /// Claude settings attach one anyway.
    case off

    public static let disableVariable = "CLAUDE_CODE_DISABLE_ADVISOR_TOOL"

    public var settingValue: String? {
        guard case .consult(let advisor) = self else { return nil }
        return advisor.settingValue
    }

    public func applying(to environment: [String: String]) -> [String: String] {
        guard self == .off else { return environment }
        return environment.merging([Self.disableVariable: "1"]) { _, disabled in disabled }
    }
}
