import BloomCore

/// Which of Home's questions a workspace is an answer to.
///
/// Three lanes rather than thirteen states, because Home is read from across the room: the user
/// wants to know whether anything is burning, whether anything is moving, and whether the rest can
/// be ignored. The thirteen states stay the source of truth and are still drawn on every row; this
/// only says which pile each of them falls into.
///
/// All that is left of the digest Home used to be built from. The grid of per-project cards, the
/// cross-project attention lane and the caps and sums behind them went with the card grid, and the
/// list that replaced them needs none of it. What the list does still need is this: the coloured
/// rail down the leading edge of a row is `resting` or not, and that is this enum's answer.
enum HomeLane {
    /// A machine is busy in it right now, so there is nothing to do but watch.
    case working
    /// It has stopped and cannot move again until a person does something.
    case waiting
    /// Nothing is asking for anything.
    case resting
}

extension WorkspaceStatus {
    var homeLane: HomeLane {
        switch self {
        case .settingUp, .running, .checksRunning: .working
        case .setupFailed, .unread, .checksFailing, .checksPassed, .merged, .closed: .waiting
        case .draft, .pullRequestOpen, .changed, .clean: .resting
        }
    }
}
