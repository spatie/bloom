import Testing
import Foundation
@testable import BloomCore

/// Up and Down in an empty composer. The rules that matter are the ones that keep the keys from
/// being taken away from somebody writing: an empty composer to start, an untouched recall to go
/// on, and the edge line of a prompt that runs to several.
@Suite("Prompt recall")
struct PromptRecallTests {
    let sent = ["first", "second", "third"]

    @Test("Up in an empty composer brings back the newest prompt")
    func startsAtNewest() {
        var recall = PromptRecall()
        let text = recall.step(.older, prompts: sent, draft: "", caret: 0)
        #expect(text == "third")
        #expect(recall.isBrowsing)
    }

    @Test("Up in a composer with words in it is the caret's")
    func leavesADraftAlone() {
        var recall = PromptRecall()
        let text = recall.step(.older, prompts: sent, draft: "half a thought", caret: 4)
        #expect(text == nil)
        #expect(!recall.isBrowsing)
    }

    @Test("Up again walks back, and stops at the oldest")
    func walksBack() {
        var recall = PromptRecall()
        var draft = ""
        for expected in ["third", "second", "first", "first"] {
            let text = recall.step(.older, prompts: sent, draft: draft, caret: 0)
            #expect(text == expected)
            draft = text ?? draft
        }
    }

    @Test("Down walks forward and past the newest leaves the composer empty")
    func walksForward() {
        var recall = PromptRecall()
        _ = recall.step(.older, prompts: sent, draft: "", caret: 0)
        let older = recall.step(.older, prompts: sent, draft: "third", caret: 5)
        #expect(older == "second")

        let newer = recall.step(.newer, prompts: sent, draft: "second", caret: 6)
        #expect(newer == "third")
        let past = recall.step(.newer, prompts: sent, draft: "third", caret: 5)
        #expect(past == "")
        #expect(!recall.isBrowsing)
    }

    @Test("Down without a recall in progress is the caret's")
    func downNeedsARecall() {
        var recall = PromptRecall()
        let text = recall.step(.newer, prompts: sent, draft: "", caret: 0)
        #expect(text == nil)
    }

    /// The owner recalled a prompt to change a word in it. From then on it is their draft.
    @Test("An edit ends the walk")
    func editEnds() {
        var recall = PromptRecall()
        _ = recall.step(.older, prompts: sent, draft: "", caret: 0)
        let text = recall.step(.older, prompts: sent, draft: "third!", caret: 6)
        #expect(text == nil)
        #expect(!recall.isBrowsing)
    }

    @Test("Inside a prompt of several lines the arrows move the caret until the edge line")
    func multilineEdges() {
        let prompts = ["one", "line a\nline b"]
        var recall = PromptRecall()
        let recalled = recall.step(.older, prompts: prompts, draft: "", caret: 0)
        #expect(recalled == "line a\nline b")

        // The caret lands at the end, on the second line: Up there moves it, and does not recall.
        let fromLast = recall.step(.older, prompts: prompts, draft: "line a\nline b", caret: 13)
        #expect(fromLast == nil)
        #expect(recall.isBrowsing)

        let fromFirst = recall.step(.older, prompts: prompts, draft: "line a\nline b", caret: 3)
        #expect(fromFirst == "one")

        let down = recall.step(.newer, prompts: prompts, draft: "one", caret: 3)
        #expect(down == "line a\nline b")
        let downFromFirst = recall.step(.newer, prompts: prompts, draft: "line a\nline b", caret: 2)
        #expect(downFromFirst == nil)
    }

    @Test("No prompts, nothing to recall")
    func empty() {
        var recall = PromptRecall()
        let text = recall.step(.older, prompts: [], draft: "", caret: 0)
        #expect(text == nil)
    }

    // MARK: - What counts as a prompt

    @Test("Blank turns go, and a prompt sent twice in a row is one step")
    func skipsBlankAndRepeats() {
        let prompts = PromptRecall.prompts(from: ["  fix it \n", "", "fix it", "again", "fix it"])
        #expect(prompts == ["fix it", "again", "fix it"])
    }

    @Test("A review turn gives back the typed message, not its scaffolding")
    func reviewMessage() {
        let comment = ReviewComment(
            id: ReviewCommentID("A.swift#2#new"),
            workspaceID: WorkspaceID("w"),
            filePath: "A.swift",
            side: .new,
            anchor: ReviewCommentAnchor.make(line: 2, in: ["a", "b", "c"]),
            body: "tighten this",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let template = PromptRegistry.definition(for: .review).defaultTemplate
        let withMessage = ReviewTurn.compose(
            message: "Tidy these up.", comments: [comment], worktreePath: nil, template: template
        )
        let commentsOnly = ReviewTurn.compose(
            message: "", comments: [comment], worktreePath: nil, template: template
        )
        #expect(PromptRecall.prompts(from: [withMessage, commentsOnly]) == ["Tidy these up."])
    }

    @Test("Instructions Bloom appended are not part of the prompt")
    func withoutInstructions() {
        let sent = "Merge it.\n\n" + MergeInstructions.canonical
        #expect(PromptRecall.prompts(from: [sent]) == ["Merge it."])
    }
}
