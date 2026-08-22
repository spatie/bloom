import SwiftUI
import BloomCore

/// Hands a failed check to the agent: fetches its log with gh, trims it, writes it into the
/// worktree as an attachment and puts a sentence about it in the composer.
///
/// A type beside the list rather than an action inside it, because this runs a subprocess and a
/// `View` does not. It is observable so the row can go quiet while its own hand-off is in flight,
/// which matters more here than for a screenshot: the log has to be downloaded, and on a workflow
/// with a large artefact that is several seconds during which the button must not be pressed
/// again.
///
/// It asks gh through `GitHubBridge` and `GitHub`, which is the same layer `ChecksView` already
/// polls through, rather than shelling out to gh a second way of its own.
@MainActor
@Observable
final class CheckFailureSender {
    /// The run currently being fetched, by `CheckRun.id`, or nil when nothing is.
    private(set) var sending: String?

    func isSending(_ run: CheckRun) -> Bool { sending == run.id }

    /// Whether this check is one there is anything to send.
    ///
    /// Failed only. A passing check has nothing an agent needs and a running one has no conclusion
    /// yet, so offering the action on either would be offering a button that fetches an empty log.
    /// `CheckState` is what decides, so cancelled, timed out and action-required count as failures
    /// here exactly as they do in the rollup above the list and in the row's own glyph.
    static func canSend(_ run: CheckRun) -> Bool { CheckState(run) == .failed }

    /// Fetches, trims, attaches, and answers with a sentence for the user when it could not.
    func send(_ run: CheckRun, in model: WorkspaceModel) async -> String? {
        guard sending == nil else { return nil }
        sending = run.id
        defer { sending = nil }

        let state = CheckState(run)
        var excerpt: CheckFailureHandoff.Excerpt?

        if let target = CheckFailureHandoff.logTarget(detailsURL: run.detailsURL) {
            do {
                let log = try await GitHub.checkRunLog(target, worktree: model.workspace.path)
                excerpt = CheckFailureHandoff.excerpt(log)
            } catch {
                // Not fatal, and deliberately so. A check with no log Bloom can reach is still
                // worth handing over: the name, the conclusion and the URL are three quarters of
                // what the user would have typed by hand, and the agent can open the run itself.
                excerpt = nil
            }
        }

        guard let excerpt else {
            // Nothing to attach, so the sentence goes into the draft on its own rather than
            // through the attachment path, which has no file to give it.
            return await ComposerHandoff.write(
                CheckFailureHandoff.sentence(
                    name: run.name,
                    workflow: run.workflowName,
                    state: state,
                    detailsURL: run.detailsURL
                ),
                to: model
            ).failure
        }

        let name = CheckFailureHandoff.logFilename(for: run.name)
        let outcome = await ComposerHandoff.attach(
            [.text(excerpt.text, named: name)],
            to: model
        ) { paths in
            CheckFailureHandoff.sentence(
                name: run.name,
                workflow: run.workflowName,
                state: state,
                detailsURL: run.detailsURL,
                logPath: paths.first,
                excerpt: excerpt
            )
        }
        return outcome.failure
    }
}
