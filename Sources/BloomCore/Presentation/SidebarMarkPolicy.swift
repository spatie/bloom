import Foundation

/// Which states are worth a mark at the head of a sidebar row, and which are not.
///
/// Every `WorkspaceStatus` has a glyph, and for a long time every row drew one. Down a pane of a
/// dozen rows that produced a column of five different shapes, not one of which meant anything was
/// wanted from the reader: a branch mark for changes, a pencil for a draft pull request, a merge
/// fork for a merged one, a tick for green checks, a hollow ring for nothing at all. The one mark
/// that mattered, an agent with its hand up, had to be found among them.
///
/// So the column now says one thing: **something is happening here, or something is wanted from
/// you.** Everything else rests. The states that lose their mark lose nothing else: the name, the
/// diff stat under the pointer, the hover card and the legend all still carry them, and the card
/// is where a pull request's state was always said in words.
///
/// It is its own file rather than a property on `WorkspaceStatus` because it is a decision about
/// this pane rather than a fact about the state: Home draws the same verdicts and wants them all.
public enum SidebarMarkPolicy {
    /// Whether a resting row draws its mark.
    ///
    /// Written out case by case, with no `default`, for the reason `describesPullRequest` gives
    /// next door: a state added to the enum and not considered here is a state that silently picks
    /// a side, and the side it would pick is invisible.
    public static func drawsMark(_ status: WorkspaceStatus) -> Bool {
        switch status {
        // Something is happening, or somebody is waiting on you.
        case .settingUp, .awaitingPermission, .running, .setupFailed, .unread:
            true
        // Something went wrong on the branch and only a person can clear it. Both survive because
        // neither resolves itself: red checks stay red until somebody pushes, and a conflict cannot
        // even be pushed away.
        case .checksFailing, .conflicted:
            true
        // A state of the branch or its pull request, which is true whether or not anybody is
        // looking. The hover card says all of it, in words.
        case .merged, .closed, .checksRunning, .checksPassed, .draft, .pullRequestOpen, .changed,
             .clean:
            false
        }
    }
}
