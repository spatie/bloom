import Foundation

/// Files attached to a draft before there was a worktree to put them in, and the crossing into
/// one.
///
/// **The bug this exists to stop.** Somebody dragged screenshots into the create sheet, typed
/// "investigate this problem" and pressed Create. The worktree was cut, the files were moved into
/// it, and the agent answered "your message didn't include a description, error, ticket, or PR",
/// because the sentence it was handed named none of them. The sheet was reading its own
/// `spokenPrompt`, which is the draft with every file taken back out of it, and handing THAT over
/// as the task. That property is right for the three readers it was written for, which name the
/// workspace, cut the branch and decide whether Create may be pressed at all, and wrong for the
/// one reader that is the agent. Two different questions were being answered by one property, and
/// the answer the agent needed was the one nobody had asked for.
///
/// So the crossing is written down here instead, as four steps in the order they happen, because
/// what makes it wrong is always two of them disagreeing about whether a file is still in the
/// sentence. It is in the core rather than beside the sheet for the ordinary reason: a decision
/// taken inside a view is a decision nothing can test, and this one is only visible end to end.
public enum WorkspaceStartAttachments {
    /// What the create sheet hands `startWorkspace` as the task.
    ///
    /// The draft exactly as it was written, files and all, because every path in it is already the
    /// path that file will have in the worktree: `AttachmentStaging` lays a draft out under the
    /// layout it is about to be moved into, so nothing has to be rewritten afterwards. Stripping
    /// here is what lost the attachments; stripping is `spoken`'s job, one step further on, where
    /// only the readers that want a name ask for it.
    ///
    /// Terminal mode hands over the name field instead, and that is not a special case of the
    /// same thing: there is no turn, so there is no sentence, and what the field holds is what the
    /// workspace and its branch are called.
    public static func handover(isChatWorkspace: Bool, draft: String, name: String) -> String {
        (isChatWorkspace ? draft : name).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same task with no file named in it: what the workspace is called, what its branch is
    /// slugged from, and what a model is shown when it is asked for a codename.
    ///
    /// A workspace called `9JVKW4` after the folder a screenshot was copied into is a row nobody
    /// can recognise, which is the whole reason the two texts are different.
    public static func spoken(_ handedOver: String, staged: [String]) -> String {
        AttachmentDraft.withoutAttachments(handedOver, paths: staged)
    }

    /// What the agent reads, or nil when this workspace sends no opening turn.
    ///
    /// Every file that arrived stays named where it was written. Every file that did not is taken
    /// out, because a path to nothing teaches an agent that Bloom lies about paths, and that is
    /// worse than one attachment fewer.
    ///
    /// The filter runs whenever anything was staged, not only when something arrived. It used to
    /// be skipped when the move brought nothing back, which left every dead path in the sentence
    /// in exactly the case where all of them were dead.
    public static func opening(
        _ handedOver: String, staged: [String], arrived: Set<String>, isChatWorkspace: Bool
    ) -> String? {
        guard isChatWorkspace else { return nil }
        guard !staged.isEmpty else { return handedOver }
        return AttachmentDraft.parse(handedOver, paths: staged).keeping { arrived.contains($0) }
    }

    /// Moves the staged files into the worktree they were written for, and answers with the paths
    /// that arrived.
    ///
    /// A move rather than a copy, and no path is rewritten: staging already holds the tree under
    /// the relative paths it will have here, so this only has to put it in its real place.
    /// Anything that fails is dropped from the answer rather than reported, and `opening` takes it
    /// out of the sentence on the strength of that.
    ///
    /// The files come across whichever mode asked for the workspace. This used to sit inside the
    /// chat branch, so a workspace opened as a terminal dropped every staged file on the floor and
    /// said nothing: a screenshot somebody dragged in is a file they wanted in the worktree, and
    /// the shell they are about to get is standing in that worktree.
    @discardableResult
    public static func adopt(
        _ paths: [String], from staging: String, into worktree: String
    ) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        WorktreeScratch.shield(WorktreeScratch.attachments, in: worktree)

        let manager = FileManager.default
        var arrived: Set<String> = []
        for path in paths {
            let from = URL(filePath: (staging as NSString).appendingPathComponent(path))
            let destination = URL(filePath: (worktree as NSString).appendingPathComponent(path))
            guard manager.fileExists(atPath: from.path) else { continue }
            do {
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try manager.moveItem(at: from, to: destination)
                arrived.insert(path)
            } catch {
                continue
            }
        }
        return arrived
    }
}
