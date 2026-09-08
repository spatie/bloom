import Foundation

/// Whether the pull request band should say it is working while it asks GitHub again.
///
/// **The band flickered, and this is the rule that stops it.** The strip raised its spinner
/// whenever it had no pull request to show, which for a branch that has not got one is every
/// single time: the arrival, the twenty second poll, and every rebuild of the view. So the one
/// control the band exists for, Create pull request, was replaced by a spinner and put back
/// several times a minute, and moving between views did it again. A branch with no pull request is
/// the steady state of most workspaces, so the state the strip spent its time in was the loading
/// one.
///
/// The fix is the same shape as the changed file list's, which asks the same question and got it
/// right: a spinner is for the moment before there is any answer at all, never for a refresh of an
/// answer already on screen. `WorkspaceModel.refreshChanges` says it as
/// `if reason == .requested, changedFiles.isEmpty`, over a list that starts empty and a
/// `hasReadChanges` beside it; this says it over the pull request, where "no pull request" is a
/// perfectly good answer and cannot be read as "nothing yet".
public enum PullRequestProgress {
    /// - Parameters:
    ///   - hasAnswered: whether any refresh has completed for this workspace this launch, whatever
    ///     it came back with. Nil is an answer, and it is the common one.
    ///   - hasPullRequest: whether there is something on screen to keep showing while this refresh
    ///     runs.
    public static func announces(hasAnswered: Bool, hasPullRequest: Bool) -> Bool {
        !hasAnswered && !hasPullRequest
    }
}
