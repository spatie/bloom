import Testing
import Foundation
@testable import BloomCore

/// The question asked before setup runs, and the one line that moves with the workspace's state.
///
/// Settled here because the three controls that raise it are all places nothing can reach, and
/// because the sentence about an agent mid turn is the only thing in this app that says what a
/// setup run does to one.
@Suite("The setup run confirmation")
struct SetupRunConfirmationTests {
    @Test("the confirm button says what it will do rather than OK")
    func theConfirmButtonNamesTheAction() {
        let again = SetupRunConfirmation.question(hasRunSetup: true, isAgentRunning: false)
        #expect(again.confirmLabel == "Run Setup Again")

        let first = SetupRunConfirmation.question(hasRunSetup: false, isAgentRunning: false)
        #expect(first.confirmLabel == "Run Setup")
    }

    /// The dialog echoes the item that was pressed, and `SetupRunOffer` says "again" only when
    /// there was a first time. A title that disagreed with the row above it is the bug that
    /// wording rule already exists for.
    @Test("the title says again exactly when the item does")
    func theTitleFollowsTheItem() {
        #expect(
            SetupRunConfirmation.question(hasRunSetup: true, isAgentRunning: false).title
                == "Run the setup script again?"
        )
        #expect(
            SetupRunConfirmation.question(hasRunSetup: false, isAgentRunning: false).title
                == "Run the setup script?"
        )
    }

    /// The two facts that make the run worth asking about: it is long, and nothing here reverses
    /// it. Both are in the message on every workspace, whatever else is going on.
    @Test("the message always says what the run costs")
    func theMessageAlwaysSaysTheCost() {
        for hasRunSetup in [true, false] {
            for isAgentRunning in [true, false] {
                let question = SetupRunConfirmation.question(
                    hasRunSetup: hasRunSetup, isAgentRunning: isAgentRunning
                )
                #expect(question.message.contains("runs in the worktree"))
                #expect(question.message.contains("can take minutes"))
                #expect(question.message.contains("cannot undo"))
            }
        }
    }

    @Test("an idle workspace is told nothing about an agent")
    func anIdleWorkspaceSaysNothingAboutAnAgent() {
        let question = SetupRunConfirmation.question(hasRunSetup: true, isAgentRunning: false)
        #expect(!question.message.contains("agent"))
    }

    /// The line exists to answer "will this interrupt what is running", and the true answer is no,
    /// which is worse rather than better: the script and the agent write to one worktree at the
    /// same time. A dialog that said the turn would be cancelled would be warning about something
    /// that cannot happen.
    @Test("a workspace with an agent mid turn is told the script does not stop it")
    func aRunningAgentGetsTheCollisionLine() {
        let question = SetupRunConfirmation.question(hasRunSetup: true, isAgentRunning: true)
        #expect(question.message.contains("An agent is mid turn here"))
        #expect(question.message.contains("does not stop it"))
    }

    /// One question, not two: the agent adds a paragraph and changes nothing else, because the
    /// action and its cost are the same either way.
    @Test("an agent mid turn adds a line and moves nothing else")
    func theAgentOnlyAddsALine() {
        let idle = SetupRunConfirmation.question(hasRunSetup: true, isAgentRunning: false)
        let busy = SetupRunConfirmation.question(hasRunSetup: true, isAgentRunning: true)

        #expect(busy.title == idle.title)
        #expect(busy.confirmLabel == idle.confirmLabel)
        #expect(busy.cancelLabel == idle.cancelLabel)
        #expect(busy.message.hasPrefix(idle.message))
    }

    /// Escape's answer, and the one that has to read as doing nothing.
    @Test("the cancel button promises nothing happens")
    func theCancelButtonIsPlain() {
        #expect(
            SetupRunConfirmation.question(hasRunSetup: true, isAgentRunning: true).cancelLabel
                == "Don\u{2019}t Run"
        )
    }
}
