import Foundation

/// The four things the window has to do for a crew, as values the core can decide about and a
/// closure the app fills in.
///
/// Same shape as `PaneOpening` and `WorkspaceStarting` beside it, and for the reason
/// `BridgeToolbox`'s head gives: a tool that has to make the window act cannot reach the main
/// actor from the core, so it holds a closure the app binds in `AppModel.bridgeToolbox()`. What
/// stays here is every decision worth testing, and what crosses the seam is one verb and its
/// arguments.
///
/// An outcome carries the sentence a refusal is refused with rather than an error, because the
/// reader is a model deciding what to do next and "the window said no, here is why" is a better
/// answer than a thrown error the tool would have to word itself.
public struct CrewOrder: Sendable, Equatable {
    /// What the orchestrator decided to call this one. Freeform, and already through
    /// `Crew.normalisedName` by the time the window sees it.
    public var name: String
    /// The brief. It becomes the first message in the new chat, so it is written to the agent
    /// rather than about it.
    public var task: String
    /// Nil means the model the orchestrator is itself on, which is almost always what a caller
    /// that did not think about it wants.
    public var model: String?
    public var effort: String?

    public init(name: String, task: String, model: String? = nil, effort: String? = nil) {
        self.name = name
        self.task = task
        self.model = model
        self.effort = effort
    }
}

public enum CrewStartOutcome: Sendable, Equatable {
    case started(String)
    case refused(String)
}

public enum CrewSayOutcome: Sendable, Equatable {
    case delivered(String)
    case refused(String)
}

public enum CrewStopOutcome: Sendable, Equatable {
    case stopped(String)
    case refused(String)
}

/// Start a crew member in the caller's own workspace. The `SessionID` is the caller: the chat the
/// new one will report to, and the link that makes it a crew member rather than another chat.
public typealias CrewStarting =
    @Sendable (CrewOrder, SessionID, WorkspaceID) async -> CrewStartOutcome

/// Say something into another agent's chat.
///
/// `to` is a crew member's name when the orchestrator is talking down, and nil when a crew member
/// is talking up, because a crew member has exactly one place to talk and naming it would be a
/// second way to say the same thing. The `SessionID` is the caller either way.
public typealias CrewSaying =
    @Sendable (String?, String, SessionID, WorkspaceID) async -> CrewSayOutcome

/// Stop a crew member by name. Only the chat that started it may.
public typealias CrewStopping =
    @Sendable (String, SessionID, WorkspaceID) async -> CrewStopOutcome
