import Foundation

/// How a turn ended, and the words the line that closes it uses to say so.
///
/// **A turn somebody stopped and a turn that failed drew the same red cross.** SIGTERM makes the
/// CLI report `error_during_execution` on its way out, so a stop arrives at the transcript wearing
/// a failure's clothes: the footer read an error result, drew the failure glyph, and said nothing
/// at all about the button that had just been pressed. The owner could not tell a turn he ended
/// from one that fell over, and the honest answer to "why did this stop" was in the sidebar's
/// session state rather than next to the turn it was about.
///
/// So a stop is an outcome in its own right and it is named first: the error the CLI reported is a
/// consequence of the stop rather than a fault, and reporting the consequence over the cause is
/// how the two became indistinguishable in the first place.
///
/// Here rather than in the footer because it is a decision about which of four things happened and
/// which sentence each one gets, and the test target cannot see a view. The glyph and the tint stay
/// with the drawing, since a symbol name and a colour are not decisions this can be wrong about.
///
/// Not `TurnOutcome`, which is next door and answers a different question: whether an ending is
/// worth interrupting somebody in another app for. That one deliberately says nothing at all about
/// a stopped turn, since a person who pressed Stop does not need to be told they did. This one has
/// to say it, because the transcript is where they are looking.
public enum TurnEnding: Sendable, Hashable {
    /// It ran to the end and nothing was refused.
    case finished
    /// It ran to the end, and this many tool calls were declined by the permission mode on the
    /// way. A result whose every shell call was denied still arrives as a plain success, so
    /// without this the footer put a tick under an agent that had been stopped at every door.
    case denied(Int)
    /// The turn itself failed.
    case failed
    /// Somebody ended it: the Stop button, quitting Bloom, closing or archiving the workspace
    /// while it ran. Every route into `SessionState.cancelled` is the owner doing something, which
    /// is why one sentence can honestly cover all of them, and why a process that merely died is
    /// not one of them. See `SessionLifecycle` and `AgentExit`.
    case stopped

    /// Which of the four this was, in the one order that reads correctly.
    public static func of(wasStopped: Bool, succeeded: Bool, denials: Int) -> TurnEnding {
        // Before the error, deliberately. See the note at the top of this file.
        if wasStopped { return .stopped }
        if !succeeded { return .failed }
        if denials > 0 { return .denied(denials) }
        return .finished
    }

    /// What the glyph means, for a reader who cannot see it.
    public var label: String {
        switch self {
        case .finished: "Finished"
        case .denied: "Finished, with calls denied"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }

    /// The sentence under the footer, where there is one.
    ///
    /// Said once for the turn rather than on each row it applies to, because the answer is one
    /// fact and repeating it fifteen times would be noise. A turn that simply finished, and one
    /// that failed with a row of its own already explaining why, say nothing here.
    public func note(permissionMode: PermissionMode) -> String? {
        switch self {
        case .finished, .failed:
            nil
        case .denied(let count):
            "\(count == 1 ? "1 tool call was" : "\(count) tool calls were") denied in "
                + "\(permissionMode.label). Pick another permission mode under the composer, "
                + "then ask again."
        case .stopped:
            // What a person wants to know the moment after they press Stop is whether they have
            // just thrown away the work. They have not: the agent's edits are on disk in the
            // worktree, and only the turn was ended. The same promise `AgentExit.advice` makes,
            // in the same words, because it is the same worry.
            "You stopped this turn. Everything the agent had already changed is still in the "
                + "worktree, and you can ask for something else whenever you like."
        }
    }
}
