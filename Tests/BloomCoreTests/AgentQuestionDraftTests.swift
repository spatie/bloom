import Foundation
import Testing
@testable import BloomCore

/// The bug this file is about: the half-finished answer to a question card used to be `@State` on
/// the card view. A transcript row is a recycled `NSTableView` cell whose root view is replaced
/// whenever the row scrolls out of the visible rect and back, or the table reloads, so somebody
/// ticking options and typing into the Other row of a four question card had his ticks and his
/// words wiped, over and over, while the session streamed. The draft is a value outside the view
/// now, and these are the rules that used to be written inline in it.
@Suite("Agent question drafts")
struct AgentQuestionDraftTests {
    private let single = AgentQuestion(
        question: "Which database should this use?",
        options: [
            AgentQuestion.Option(label: "SQLite"),
            AgentQuestion.Option(label: "Postgres"),
        ]
    )

    private let multi = AgentQuestion(
        question: "Which checks should run?",
        multiSelect: true,
        options: [
            AgentQuestion.Option(label: "Build"),
            AgentQuestion.Option(label: "Lint"),
            AgentQuestion.Option(label: "Tests"),
        ]
    )

    // MARK: Ticking

    @Test("ticking a single-select question replaces, and ticking the same option again clears it")
    func singleSelectReplaces() {
        var draft = AgentQuestionDraft()

        draft.toggle("SQLite", on: single)
        #expect(draft.chosen[single.id] == ["SQLite"])

        draft.toggle("Postgres", on: single)
        #expect(draft.chosen[single.id] == ["Postgres"])

        draft.toggle("Postgres", on: single)
        #expect(draft.chosen[single.id] == [])
    }

    @Test("ticking a multi-select question accumulates, and ticking again removes just that one")
    func multiSelectAccumulates() {
        var draft = AgentQuestionDraft()

        draft.toggle("Build", on: multi)
        draft.toggle("Tests", on: multi)
        #expect(draft.chosen[multi.id] == ["Build", "Tests"])

        draft.toggle("Build", on: multi)
        #expect(draft.chosen[multi.id] == ["Tests"])
    }

    @Test("ticking an option puts the typed words away, so the two are never sent joined together")
    func tickingClearsTypedWords() {
        var draft = AgentQuestionDraft()

        draft.writeOther(on: single)
        draft.other[single.id] = "Neither, use a file"

        draft.toggle("SQLite", on: single)

        #expect(draft.other[single.id] == "")
        #expect(!draft.isWritingOther.contains(single.id))
        #expect(draft.answers(to: [single]) == [single.id: "SQLite"])
    }

    // MARK: Answering in words

    @Test("opening the Other row clears whatever was ticked on that question")
    func otherRowClearsTicks() {
        var draft = AgentQuestionDraft()

        draft.toggle("Lint", on: multi)
        draft.toggle("Tests", on: multi)

        draft.writeOther(on: multi)

        #expect(draft.chosen[multi.id] == [])
        #expect(draft.isWritingOther.contains(multi.id))
    }

    @Test("typed words win over ticks that are still on the question")
    func typedWordsWin() {
        var draft = AgentQuestionDraft()

        // Reached by hand rather than through `writeOther`, which would have cleared the tick: the
        // rule has to hold whichever way the two ended up on one question.
        draft.chosen[single.id] = ["SQLite"]
        draft.other[single.id] = "Neither, use a flat file"

        #expect(draft.answers(to: [single]) == [single.id: "Neither, use a flat file"])
    }

    @Test("an Other row holding nothing but spaces answers nothing")
    func blankOtherAnswersNothing() {
        var draft = AgentQuestionDraft()

        draft.writeOther(on: single)
        draft.other[single.id] = "   \n "

        #expect(draft.answers(to: [single]).isEmpty)
        #expect(!draft.isComplete([single]))
    }

    // MARK: The answers themselves

    @Test("several ticks are joined in the order the asker offered them, not the order tapped")
    func answersKeepTheAskersOrder() {
        var draft = AgentQuestionDraft()

        draft.toggle("Tests", on: multi)
        draft.toggle("Build", on: multi)
        draft.toggle("Lint", on: multi)

        #expect(draft.answers(to: [multi]) == [multi.id: "Build, Lint, Tests"])
    }

    @Test("a question with nothing on it is left out of the answers rather than answered emptily")
    func untouchedQuestionsAreLeftOut() {
        var draft = AgentQuestionDraft()

        draft.toggle("SQLite", on: single)

        #expect(draft.answers(to: [single, multi]) == [single.id: "SQLite"])
    }

    // MARK: Completeness

    @Test("a card is complete only once every one of its questions has something to send")
    func completenessAcrossSeveralQuestions() {
        var draft = AgentQuestionDraft()

        #expect(!draft.isComplete([single, multi]))

        draft.toggle("SQLite", on: single)
        #expect(!draft.isComplete([single, multi]))
        #expect(draft.isComplete([single]))

        draft.writeOther(on: multi)
        draft.other[multi.id] = "Only the ones that changed"
        #expect(draft.isComplete([single, multi]))
    }

    @Test("no questions at all is not complete, whatever the draft holds")
    func noQuestionsIsNotComplete() {
        var draft = AgentQuestionDraft()

        draft.toggle("SQLite", on: single)

        #expect(!draft.isComplete([]))
    }
}
