import Testing
@testable import BloomCore

@Suite("Whether a workspace may be started")
struct WorkspaceStartPlanTests {
    @Test("a chat needs words")
    func chatNeedsWords() {
        #expect(!WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "", hasCheckout: false,
            isChatWorkspace: true, isBusy: false
        ))
        #expect(WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "Fix the login flow", hasCheckout: false,
            isChatWorkspace: true, isBusy: false
        ))
    }

    @Test("whitespace is not words")
    func whitespaceIsNotWords() {
        #expect(!WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "   \n\t ", hasCheckout: false,
            isChatWorkspace: true, isBusy: false
        ))
    }

    /// The whole point of the feature. A worktree, a branch and a shell is a complete request, and
    /// requiring a sentence for it was requiring somebody to describe work they were about to do
    /// by hand to an agent that is never going to read it.
    @Test("a terminal needs nothing written at all")
    func terminalNeedsNothing() {
        #expect(WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "", hasCheckout: false,
            isChatWorkspace: false, isBusy: false
        ))
    }

    @Test("a checkout needs nothing written, because the pull request brought its own name")
    func checkoutNeedsNothing() {
        #expect(WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "", hasCheckout: true,
            isChatWorkspace: true, isBusy: false
        ))
    }

    @Test("no project, no start, whatever else is true")
    func projectIsRequired() {
        #expect(!WorkspaceStartPlan.canStart(
            hasProject: false, prompt: "Fix the login flow", hasCheckout: true,
            isChatWorkspace: false, isBusy: false
        ))
    }

    /// A second press while the first worktree is being cut is how two workspaces race for one
    /// branch name, so the guard covers the route that needs no words as well as the one that does.
    @Test("a create already in flight blocks every route")
    func busyBlocksEveryRoute() {
        #expect(!WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "Fix the login flow", hasCheckout: false,
            isChatWorkspace: true, isBusy: true
        ))
        #expect(!WorkspaceStartPlan.canStart(
            hasProject: true, prompt: "", hasCheckout: false,
            isChatWorkspace: false, isBusy: true
        ))
    }

    @Test("a typed branch names a terminal workspace")
    func typedBranchNames() {
        #expect(WorkspaceStartPlan.terminalName(
            userSuppliedBranch: "spike/perf", claimedSea: "Coral Sea"
        ) == "spike/perf")
    }

    @Test("otherwise the sea does")
    func seaNames() {
        #expect(WorkspaceStartPlan.terminalName(
            userSuppliedBranch: nil, claimedSea: "Coral Sea"
        ) == "Coral Sea")
        #expect(WorkspaceStartPlan.terminalName(
            userSuppliedBranch: "", claimedSea: "Coral Sea"
        ) == "Coral Sea")
    }

    /// An exhausted catalogue, or a store that is not there yet. Nil is handed back rather than
    /// invented, and `Git.title` answers "New workspace" for the empty prompt behind it.
    @Test("with neither, nothing is claimed to be the name")
    func neitherNames() {
        #expect(WorkspaceStartPlan.terminalName(
            userSuppliedBranch: nil, claimedSea: nil
        ) == nil)
    }
}

/// What survives a person changing their mind about which of the two things they are doing.
///
/// The whole reason the create sheet chooses a mode first is that the two-button version could
/// take a sentence, name a workspace after it and never say so. Choosing first removes the input,
/// which only helps if what was written comes with it.
@Suite("Crossing between chat and terminal")
struct WorkspaceModeCrossingTests {
    @Test("a sentence becomes the name it was always going to become")
    func sentenceBecomesTheName() {
        #expect(WorkspaceStartPlan.carriedName(
            prompt: "Fix the flaky worktree test", currentName: ""
        ) == "Fix the flaky worktree test")
    }

    /// The same cut `Git.title` makes, because the crossing has to promise what the create will
    /// actually do rather than something close to it.
    @Test("a long sentence is cut where the name would have been cut")
    func longSentenceIsCut() {
        let prompt = String(repeating: "alpha ", count: 40)
        #expect(WorkspaceStartPlan.carriedName(prompt: prompt, currentName: "")
                == Git.title(from: prompt))
    }

    @Test("only the first line, because that is what names a workspace")
    func firstLineOnly() {
        #expect(WorkspaceStartPlan.carriedName(
            prompt: "Rebase onto main\n\nThen fix the conflicts", currentName: ""
        ) == "Rebase onto main")
    }

    /// A name somebody typed is not a draft to be improved on. The mode is switched by a click,
    /// and a click may not overwrite words.
    @Test("a name already typed is never overwritten")
    func typedNameWins() {
        #expect(WorkspaceStartPlan.carriedName(
            prompt: "Fix the flaky worktree test", currentName: "spike"
        ) == "spike")
    }

    /// Empty is what claims a sea, and a sea is a better name than "New workspace", which is what
    /// `Git.title` answers for an empty prompt.
    @Test("an empty box carries an empty name, not a placeholder")
    func emptyStaysEmpty() {
        #expect(WorkspaceStartPlan.carriedName(prompt: "", currentName: "").isEmpty)
        #expect(WorkspaceStartPlan.carriedName(prompt: "  \n\t ", currentName: "").isEmpty)
    }

    /// The sheet opens on whichever mode was used last, so somebody can now type a sentence into
    /// the name field and only then realise they wanted an agent. That is the same silent discard
    /// pointing the other way.
    @Test("a name typed in terminal mode comes back as the prompt")
    func nameComesBack() {
        #expect(WorkspaceStartPlan.carriedPrompt(
            name: "Fix the flaky worktree test", currentPrompt: ""
        ) == "Fix the flaky worktree test")
    }

    @Test("a draft already in the box wins")
    func draftWins() {
        #expect(WorkspaceStartPlan.carriedPrompt(
            name: "spike", currentPrompt: "Rebase onto main"
        ) == "Rebase onto main")
    }

    /// Both directions in turn, because the control is a segmented picker and somebody will click
    /// it four times before deciding. Nothing may be lost or invented on the way round.
    @Test("a round trip loses nothing and invents nothing")
    func roundTrip() {
        let written = "Fix the flaky worktree test"
        let name = WorkspaceStartPlan.carriedName(prompt: written, currentName: "")
        // The box is not cleared on the way out, so the sentence is still there to win coming back.
        #expect(WorkspaceStartPlan.carriedPrompt(name: name, currentPrompt: written) == written)
    }
}

@Suite("What the create sheet opens on")
struct WorkspaceStartModeTests {
    /// Nineteen creations out of twenty are chats, and somebody who has not chosen yet can back
    /// out of chat mode by simply typing.
    @Test("a fresh install opens on chat")
    func freshInstallIsChat() {
        #expect(WorkspaceStartMode.remembered(raw: nil) == .chat)
    }

    @Test("the last choice is what it opens on")
    func lastChoiceWins() {
        #expect(WorkspaceStartMode.remembered(raw: "terminal") == .terminal)
        #expect(WorkspaceStartMode.remembered(raw: "chat") == .chat)
        #expect(WorkspaceStartMode.remembered(raw: "browser") == .browser)
    }

    /// A value written by a future version, or a key somebody cleared by hand. Neither is worth an
    /// empty sheet.
    @Test("anything unreadable is a fresh install")
    func unreadableIsFresh() {
        #expect(WorkspaceStartMode.remembered(raw: "shell") == .chat)
        #expect(WorkspaceStartMode.remembered(raw: "") == .chat)
    }

    /// The one question the rest of the sheet is downstream of: the model, the effort, the output
    /// style, the permission mode and the paperclip all qualify a turn, and only one mode has one.
    @Test("only a chat runs an agent")
    func onlyChatRunsAnAgent() {
        #expect(WorkspaceStartMode.chat.runsAnAgent)
        #expect(!WorkspaceStartMode.terminal.runsAnAgent)
        #expect(!WorkspaceStartMode.browser.runsAnAgent)
    }

    /// The segmented control is the only thing on the sheet saying what the difference is, and
    /// three segments have to read as a list. "Just a terminal" was a disclaimer against the one
    /// segment beside it, which is not a thing a list has a member for.
    @Test("only the segment that runs an agent says more than its tab's name")
    func onlyChatSaysMoreThanItsName() {
        #expect(WorkspaceStartMode.chat.sheetLabel == "Chat with an agent")
        #expect(WorkspaceStartMode.terminal.sheetLabel == WorkspaceStartMode.terminal.label)
        #expect(WorkspaceStartMode.browser.sheetLabel == WorkspaceStartMode.browser.label)
    }

    /// The sheet's heading lower-cases the label to say what is being opened in, so a label that
    /// is not a plain noun would read as "Open #12 in a just a terminal".
    @Test("every label is one word the heading can borrow")
    func labelsAreNounsTheHeadingCanUse() {
        for mode in WorkspaceStartMode.allCases {
            #expect(!mode.label.contains(" "))
        }
    }
}

/// What the sheet says under the name field, and the one word it may not use.
@Suite("What a mode with no agent says about itself")
struct StartNoteTests {
    /// The sentence somebody standing in front of an empty field needs: the field is optional,
    /// and something will fill it.
    @Test("an empty field promises a name without explaining where it comes from")
    func emptyFieldPromisesAName() {
        let note = WorkspaceStartPlan.startNote(mode: .terminal, hasCheckout: false, name: "")
        #expect(note.contains("Leave it empty and Bloom names it for you"))
    }

    @Test("a filled field says what it is about to name")
    func filledFieldSaysWhatItNames() {
        let note = WorkspaceStartPlan.startNote(mode: .terminal, hasCheckout: false, name: "spike")
        #expect(note.contains("This names the workspace and its branch"))
    }

    @Test("whitespace is an empty field")
    func whitespaceIsEmpty() {
        #expect(WorkspaceStartPlan.startNote(mode: .terminal, hasCheckout: false, name: "  \n ")
                == WorkspaceStartPlan.startNote(mode: .terminal, hasCheckout: false, name: ""))
    }

    /// A pull request brought its own name, so there is no field and nothing to say about one.
    @Test("a checkout says what the workspace will be instead")
    func checkoutSaysWhatItWillBe() {
        let note = WorkspaceStartPlan.startNote(mode: .terminal, hasCheckout: true, name: "")
        #expect(note.contains("a shell opens in the worktree"))
        #expect(!note.contains("Leave it empty"))
    }

    /// And it says the right one. The sentence was a shell in every mode while there was only one
    /// mode it could be, which is the shape of the bug a third one would have arrived as.
    @Test("a browser checkout does not promise a shell")
    func browserCheckoutOpensABrowser() {
        let note = WorkspaceStartPlan.startNote(mode: .browser, hasCheckout: true, name: "")
        #expect(note.contains(WorkspaceStartMode.browser.openingSentence))
        #expect(!note.contains("shell"))
    }

    /// The field is the same field in both, and so is what it promises. Only the clause about
    /// what opens is allowed to differ, and only where a checkout has taken the field away.
    @Test("without a checkout the two agentless modes say the same thing")
    func agentlessModesAgreeWithoutACheckout() {
        for name in ["", "spike"] {
            #expect(WorkspaceStartPlan.startNote(mode: .terminal, hasCheckout: false, name: name)
                    == WorkspaceStartPlan.startNote(mode: .browser, hasCheckout: false, name: name))
        }
    }

    /// The half that is the whole difference between the two modes, and the half the sheet went
    /// four days without saying at all.
    @Test("every sentence says that nothing is sent to an agent")
    func everySentenceSaysNoAgent() {
        for mode in [WorkspaceStartMode.terminal, .browser] {
            for (hasCheckout, name) in [(true, ""), (true, "spike"), (false, ""), (false, "spike")] {
                let note = WorkspaceStartPlan.startNote(mode: mode, hasCheckout: hasCheckout, name: name)
                #expect(note.hasSuffix("Nothing is sent to an agent."))
            }
        }
    }

    // MARK: - What a workspace ends up called

    /// The rule exists so the row drawn while the worktree is being cut and the row drawn
    /// afterwards cannot say different things. `PendingWorkspace` asks this before `git worktree
    /// add` runs and `WorkspaceManager` asks it when it builds the stored row, so a case that
    /// answered differently from the other would be a name changing under the reader the instant
    /// the workspace became real.
    @Test("a name that was settled wins over everything")
    func settledNameWins() {
        #expect(WorkspaceStartPlan.name(
            supplied: "Harbour", checkout: nil, prompt: "Fix the login flow"
        ) == "Harbour")
        #expect(WorkspaceStartPlan.name(
            supplied: "Harbour",
            checkout: .branch(ExistingBranch(name: "feature/x", isLocal: true)),
            prompt: ""
        ) == "Harbour")
    }

    /// An empty string is a name nobody chose. `WorkspaceStartPlan.terminalName` returns the
    /// branch field as typed, and a field somebody cleared arrives here as "".
    @Test("an empty name is no name")
    func emptyNameIsNoName() {
        #expect(WorkspaceStartPlan.name(
            supplied: "", checkout: nil, prompt: "Fix the login flow"
        ) == "Fix the login flow")
    }

    @Test("a checkout brings its own name")
    func checkoutBringsItsOwn() {
        #expect(WorkspaceStartPlan.name(
            supplied: nil,
            checkout: .branch(ExistingBranch(name: "feature/x", isLocal: true)),
            prompt: "ignored"
        ) == "feature/x")
    }

    /// The last resort, and it never answers nothing: a row with no name at all is worse than one
    /// called "New workspace".
    @Test("nothing settled falls back to the task, and an empty task still has a name")
    func fallsBackToTheTask() {
        #expect(WorkspaceStartPlan.name(
            supplied: nil, checkout: nil, prompt: "Fix the login flow"
        ) == "Fix the login flow")
        #expect(!WorkspaceStartPlan.name(supplied: nil, checkout: nil, prompt: "").isEmpty)
    }

    /// **The regression this suite exists for.**
    ///
    /// The sheet used to say "Named after a sea", "named after a sea" and "named after the sea" in
    /// three places at once. The catalogue is still there and still claims, and the chart and the
    /// notice that fires on a first claim are how somebody is meant to find out about it. A create
    /// sheet that explains the mechanism up front spends that discovery to answer a question
    /// nobody asked, and the answer it gives is about Bloom's insides rather than about what the
    /// person is doing.
    @Test("no sentence names the mechanism behind the name")
    func nothingNamesTheMechanism() {
        let forbidden = ["sea", "ocean"]
        for mode in [WorkspaceStartMode.terminal, .browser] {
            for (hasCheckout, name) in [(true, ""), (true, "spike"), (false, ""), (false, "spike")] {
                let note = WorkspaceStartPlan
                    .startNote(mode: mode, hasCheckout: hasCheckout, name: name)
                    .lowercased()
                for word in forbidden {
                    #expect(!note.contains(word), "\(note) names \(word)")
                }
            }
        }
    }
}
