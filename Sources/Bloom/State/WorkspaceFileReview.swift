import Foundation
import BloomCore

/// The data and editing services used by the existing diff and file panes.
@MainActor
protocol WorkspaceFileReview: WorkspaceFileListing {
    var repo: Repo? { get }
    var fileEdits: FileEditSession { get }
    var supportsReviewComments: Bool { get }
    var changesGeneration: Int { get }
    var reviewComments: [ReviewComment] { get }
    var reviewDrafts: [String: ReviewDraft] { get set }
    var reviewEdits: Set<ReviewCommentID> { get set }
    var reviewText: ReviewTextHost { get }
    func patch(for file: ChangedFile) async -> String
    func heldDiff(for file: ChangedFile, ignoringWhitespace: Bool) -> DiffPresentation?
    func holdDiff(_ presentation: DiffPresentation, for file: ChangedFile, ignoringWhitespace: Bool)
    func forgetHeldDiff(for path: String)
    func contents(of path: String) -> String?
    func readContents(of path: String) async -> String?
    func addReviewComment(filePath: String, selection: ReviewSelection, anchor: ReviewCommentAnchor, body: String) async
    func editReviewComment(id: ReviewCommentID, body: String) async
    func removeReviewComment(id: ReviewCommentID) async
}

extension WorkspaceModel: WorkspaceFileReview {
    var fileEdits: FileEditSession { .shared }
    var supportsReviewComments: Bool { true }
    func readContents(of path: String) async -> String? {
        let root = workspace.path
        return await Task.detached { Self.contents(of: path, in: root) }.value
    }
}
