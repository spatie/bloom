import AppKit
import Foundation
import SwiftUI
import BloomCore

/// GitHub state and actions shared by the pull request strip and Checks tab.
extension WorkspaceModel {
    /// Through `gh`, which is what this Mac has. Nil when GitHub refused this token the runs: an
    /// empty list there would say "no checks", which is the one thing that is not known.
    func readChecks() async -> [CheckRun]? {
        await GitHubBridge.checks(for: workspace)
    }

    func sendCheckFailure(_ run: CheckRun) async -> String? {
        await checkFailures.send(run, in: self)
    }

    /// GitLab reports its own access through the read, so gh's state says nothing about it.
    var gitHubReadiness: GitHubAvailability.State {
        forge == .gitLab ? .ready : GitHubAvailability.shared.state
    }

    /// Raises the GitLab sign in sheet for this workspace's host, installing glab first if needed.
    func signInToGitLab() async {
        let access = GitHubAvailability.State(await GitLab.access(in: workspace.path))
        guard access != .ready else {
            await refreshPullRequest()
            return
        }
        let host = await GitLab.host(in: workspace.path)
        GitHubSignIn.shared.presentGitLab(directory: workspace.path, host: host, access: access)
    }

    /// gh's readiness, asked afresh, or ready on GitLab. For the Checks tab's poll.
    func checksReadiness() async -> GitHubAvailability.State {
        forge = await ForgeResolver.forge(for: workspace.path)
        return forge == .gitLab ? .ready : await GitHubAvailability.shared.check()
    }

    func continueAfterMerge(_ pullRequest: PullRequest) async -> AppModel.ContinuationOutcome {
        await app.continueAfterMerge(workspace, pullRequest: pullRequest)
    }

    func requestArchive(presenting: @escaping (ArchiveRequest) -> Void) async {
        await app.archive(workspace, presentConfirmation: presenting)
    }

    func confirmArchive(_ request: ArchiveRequest, presenting: @escaping (ArchiveRequest) -> Void) async {
        await app.confirmArchive(request, presentConfirmation: presenting)
    }

    func reviewContents(for file: ChangedFile) async -> String? {
        await Self.reviewContents(worktree: workspace.path, file: file, scope: diffScope)
    }

    func lookUpInDiff(at offset: Int, view: CodeTextView, lines: [DiffLine?], source: String,
                      path: String, references: Bool, automatic: Bool, newTab: Bool,
                      onOpen: @escaping (CodeLocation, Bool) -> Void) {
        SourceActions.lookupInDiff(at: offset, view: view, lines: lines, source: source, path: path,
                                   model: self, references: references, automatic: automatic,
                                   newTab: newTab, onOpen: onOpen)
    }

    func openFromDiff(_ location: CodeLocation, newTab: Bool) async {
        await FileReview.openFromDiff(location, in: self, newTab: newTab)
    }

    var canStepSourceHistory: (back: Bool, forward: Bool) {
        let history = SourceNavigation.shared.histories[workspace.id]
        return (history?.canGoBack == true, history?.canGoForward == true)
    }

    func stepSourceHistory(_ delta: Int) {
        SourceNavigation.shared.move(delta, in: self)
    }

    func openSource(at location: CodeLocation) {
        FileReview.open(location: location, in: self)
    }

    /// The file itself, which is what the editor opens and what the find bar files its state under.
    /// The file itself, on this Mac's disk. See `EditableFiles`.
    var editableFiles: any EditableFiles { DiskFiles() }

    func editorKey(for relativePath: String) -> String {
        (workspace.path as NSString).appendingPathComponent(relativePath)
    }

    func openTerminal(in folder: String) {
        FolderTerminalTab.open(folder: folder, in: self)
    }

    /// Nil: the file is on this Mac, and the menu offers the Finder and an editor instead.
    func gitHubURL(forFile relativePath: String?) -> URL? { nil }

    func openPage(path: String, splittingAxis: SplitAxis?) {
        if let axis = splittingAxis {
            BrowserTab.splitFile(path, in: self, axis: axis)
        } else {
            BrowserTab.openFile(path, in: self)
        }
    }
}
