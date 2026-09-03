import Foundation
import Testing
@testable import BloomCore

/// What an agent is told about a workspace's tabs, and what happens when it names one.
///
/// The window cannot be reached from here, which is the point of the seam: everything that decides
/// anything is a pure function or a value, and the closure the tools are built with stands in for
/// the app. So every refusal a model can be handed is asserted on, and so is the shape of each
/// answer, without a tab strip existing.
///
/// What is NOT here, and cannot be: whether the census the window builds matches the strip the
/// person is looking at. Which tabs a workspace has is `CenterTabStore` and `WorkspaceTabsStore`,
/// both `@MainActor` singletons in `Sources/Bloom`, which `Tests/BloomCoreTests` does not depend
/// on. The walk over them lives in `AppModel+TabBridge` and is held by the same thing that holds
/// `pane_list`'s walk, which is reading it.
@Suite("Seeing a workspace's tabs", .scratchDirectory)
struct WorkspaceTabToolTests {
    // MARK: - Building a strip to talk about

    private func chat(
        _ number: Int,
        title: String,
        active: Bool = false,
        state: SessionState = .idle,
        messages: Int = 12,
        panes: [WorkspaceTabPane] = []
    ) -> WorkspaceTabReport {
        WorkspaceTabReport(
            number: number,
            title: title,
            isActive: active,
            detail: .chat(
                WorkspaceTabChat(agent: .claudeCode, state: state, messages: messages)
            ),
            panes: panes
        )
    }

    private func terminal(
        _ number: Int, title: String = "Terminal 1", live: Bool = true
    ) -> WorkspaceTabReport {
        WorkspaceTabReport(
            number: number,
            title: title,
            isActive: false,
            detail: .terminal(
                WorkspaceTabTerminal(directory: "/tmp/worktree", isLive: live)
            )
        )
    }

    private func browser(
        _ number: Int, title: String = "Bloom", address: String = "http://localhost:3000"
    ) -> WorkspaceTabReport {
        WorkspaceTabReport(
            number: number,
            title: title,
            isActive: false,
            detail: .browser(BrowserPaneReport(number: 1, name: title, address: address))
        )
    }

    private func review(_ number: Int, file: String) -> WorkspaceTabReport {
        WorkspaceTabReport(
            number: number,
            title: file.isEmpty ? "All changes" : file,
            isActive: false,
            detail: .review(WorkspaceTabReview(file: file))
        )
    }

    /// The workspace the report is written against: a chat in front, a chat split with a browser,
    /// a terminal and a review.
    private var strip: [WorkspaceTabReport] {
        [
            chat(1, title: "Fix the parser", active: true, state: .running, messages: 34),
            chat(
                2,
                title: "Notes on the bridge",
                panes: [
                    WorkspaceTabPane(kind: .chat, title: "Notes on the bridge"),
                    WorkspaceTabPane(kind: .browser, title: "Bloom", browser: 1),
                ]
            ),
            terminal(3),
            review(4, file: "Sources/BloomCore/Bridge/PaneCensus.swift"),
        ]
    }

    // MARK: - The shape of an answer

    @Test("a tab carries its place, its kind, its name and whether it is in front")
    func aTabSaysTheFourThings() {
        let json = chat(1, title: "Fix the parser", active: true).json
        guard case .object(let fields) = json else {
            Issue.record("expected an object"); return
        }
        #expect(fields["tab"] == .integer(1))
        #expect(fields["kind"] == .string("chat"))
        #expect(fields["title"] == .string("Fix the parser"))
        #expect(fields["active"] == .bool(true))
    }

    /// The block is filed under the kind's own word, so a model that has read `kind` knows which
    /// key to look in without being told the mapping.
    @Test("what is in a tab is filed under the kind it is")
    func theDetailIsFiledUnderTheKind() {
        for tab in strip {
            guard case .object(let fields) = tab.json else {
                Issue.record("expected an object"); return
            }
            #expect(fields[tab.kind.rawValue] != nil, "\(tab.kind.rawValue)")
        }
    }

    @Test("a chat says which agent, what it is doing and how long it is")
    func aChatSaysWhatItIsDoing() {
        guard case .object(let fields) = chat(1, title: "x", state: .running, messages: 34).json,
              case .object(let block)? = fields["chat"] else {
            Issue.record("expected a chat block"); return
        }
        #expect(block["agent"] == .string(AgentKind.claudeCode.rawValue))
        #expect(block["state"] == .string("running"))
        #expect(block["running"] == .bool(true))
        #expect(block["messages"] == .integer(34))
    }

    /// `waiting` is the case the flag exists for. The process is alive and no work is happening,
    /// which is the opposite of running rather than a shade of it, and a model that read only
    /// `state` would have to know that.
    @Test("a chat holding a permission question is not reported as running")
    func waitingIsNotRunning() {
        guard case .object(let fields) = chat(1, title: "x", state: .waiting).json,
              case .object(let block)? = fields["chat"] else {
            Issue.record("expected a chat block"); return
        }
        #expect(block["state"] == .string("waiting"))
        #expect(block["running"] == .bool(false))
    }

    @Test("a terminal says where its shell started and says it knows no more than that")
    func aTerminalSaysWhereItStarted() {
        guard case .object(let fields) = terminal(1).json,
              case .object(let block)? = fields["terminal"] else {
            Issue.record("expected a terminal block"); return
        }
        #expect(block["directory"] == .string("/tmp/worktree"))
        #expect(block["live"] == .bool(true))
        guard case .string(let note)? = block["note"] else {
            Issue.record("expected a note"); return
        }
        #expect(note.contains("not what is running in it now"))
    }

    /// A workspace reopened this morning has every terminal tab it had last night and no shell
    /// behind any of them, so this is the ordinary answer rather than the exceptional one, and it
    /// has to read as a fact rather than as a failure.
    @Test("a terminal nobody has opened this launch says so instead of claiming a shell")
    func aTerminalWithNoShellSaysSo() {
        guard case .object(let fields) = terminal(1, live: false).json,
              case .object(let block)? = fields["terminal"],
              case .string(let note)? = block["note"] else {
            Issue.record("expected a terminal block"); return
        }
        #expect(block["live"] == .bool(false))
        #expect(note.contains("no shell has been started"))
    }

    @Test("a review names the file it is on, and says when it is on the whole change")
    func aReviewNamesItsFile() {
        guard case .object(let onFile) = review(1, file: "Sources/Bloom/App.swift").json,
              case .object(let file)? = onFile["review"] else {
            Issue.record("expected a review block"); return
        }
        #expect(file["file"] == .string("Sources/Bloom/App.swift"))
        #expect(file["showing"] == nil)

        guard case .object(let onAll) = review(1, file: "").json,
              case .object(let all)? = onAll["review"] else {
            Issue.record("expected a review block"); return
        }
        #expect(all["showing"] == .string("all changes"))
        #expect(all["file"] == nil)
    }

    /// The note is the reader's own writing and is not addressed to an agent. A length answers the
    /// only question a caller has about it, which is whether there is anything there.
    @Test("the notes report a length and never the text")
    func theNotesReportALength() {
        guard case .object(let fields) = WorkspaceTabReport(
            number: 1, title: "Notes", isActive: false,
            detail: .notes(WorkspaceTabNote(characters: 240))
        ).json, case .object(let notes)? = fields["notes"] else {
            Issue.record("expected a notes block"); return
        }
        #expect(notes["characters"] == .integer(240))
        guard case .string(let note)? = notes["note"] else {
            Issue.record("expected a note"); return
        }
        #expect(note.contains("not reported here"))
    }

    @Test("a browser carries the number the browser_ tools take")
    func aBrowserCarriesItsNumber() {
        guard case .object(let fields) = browser(1).json,
              case .object(let browser)? = fields["browser"] else {
            Issue.record("expected a browser block"); return
        }
        #expect(browser["browser"] == .integer(1))
        #expect(browser["address"] == .string("http://localhost:3000"))
    }

    /// An unsplit tab is one pane holding the content the tab is named after, so listing it would
    /// be the same row printed twice.
    @Test("only a split tab lists what it has absorbed")
    func onlyASplitTabListsItsPanes() {
        guard case .object(let plain) = strip[0].json else {
            Issue.record("expected an object"); return
        }
        #expect(plain["split_into"] == nil)

        guard case .object(let split) = strip[1].json,
              case .array(let panes)? = split["split_into"] else {
            Issue.record("expected a split tab to list its panes"); return
        }
        #expect(panes.count == 2)
        #expect(panes[1] == .object([
            "kind": .string("browser"),
            "title": .string("Bloom"),
            "browser": .integer(1),
        ]))
    }

    @Test("the listing counts what it lists")
    func theListingCountsItself() {
        guard case .object(let fields) = WorkspaceTabCensus(tabs: strip).json,
              case .array(let tabs)? = fields["tabs"] else {
            Issue.record("expected a listing"); return
        }
        #expect(tabs.count == 4)
        #expect(fields["count"] == .integer(4))
    }

    // MARK: - What the answer says about itself

    /// The numbers are positions rather than identities, and the warning belongs in the answer as
    /// well as in the description: a description is read once when the tools are listed and this is
    /// read in the turn the numbers are being acted on.
    @Test("the answer warns that a tab number is a place and not an identity")
    func theNoteWarnsAboutTheNumbers() {
        let note = WorkspaceTabCensus(tabs: strip).note
        #expect(note.contains("'tab' is a place in the strip"))
        #expect(note.contains("workspace_tabs"))
    }

    /// Word for word what `pane_list` says, because a tab named after a page is page-written text
    /// whichever tool reports it. Two wordings is how one of them ends up softer.
    @Test("a strip holding a browser carries the same untrusted-text note pane_list carries")
    func aBrowserBringsTheUntrustedNote() {
        #expect(WorkspaceTabCensus(tabs: strip).note.contains(PaneCensus.browserNote))
        // Including one that is only a pane of a split tab, since its name came off a page too.
        #expect(
            WorkspaceTabCensus(tabs: [strip[1]]).note.contains(PaneCensus.browserNote)
        )
        #expect(!WorkspaceTabCensus(tabs: [strip[0], strip[2]]).note.contains("written by the page"))
    }

    @Test("an empty strip says why it is empty rather than saying nothing")
    func anEmptyStripSaysWhy() {
        let note = WorkspaceTabCensus(tabs: []).note
        #expect(note.contains("nothing open in the centre column"))
    }

    // MARK: - Naming a tab

    @Test("a tab is named by its number or by its title, and one of the two is required")
    func aTabIsNamedOneOfTwoWays() {
        #expect(
            (try? WorkspaceTabChoice.parse(number: .integer(3), title: nil).get()) == .number(3)
        )
        #expect(
            (try? WorkspaceTabChoice.parse(number: nil, title: .string("Notes")).get())
                == .title("Notes")
        )

        guard case .failure(let refusal) =
            WorkspaceTabChoice.parse(number: nil, title: nil) else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("'tab'"))
        #expect(refusal.sentence.contains("'title'"))
    }

    /// They are two ways of saying one thing, so a call that gives both has not decided. Picking
    /// one for it is how a model learns that an argument it thought it was using is ignored.
    @Test("naming a tab both ways is refused rather than resolved to one of them")
    func bothWaysAtOnceIsRefused() {
        guard case .failure(let refusal) = WorkspaceTabChoice.parse(
            number: .integer(2), title: .string("Terminal 1")
        ) else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("not both"))
    }

    @Test("a blank title is a caller that named nothing, not a tab with a blank name")
    func aBlankTitleNamesNothing() {
        for blank in [JSONValue.string(""), .string("   "), .null] {
            guard case .failure(let refusal) =
                WorkspaceTabChoice.parse(number: nil, title: blank) else {
                Issue.record("\(blank) was not refused"); return
            }
            #expect(refusal.sentence.contains("needs to know which tab"))
        }
    }

    /// A caller passing 1.5 has computed something rather than counted along the strip, and
    /// rounding would act on a tab it did not choose.
    @Test("the tab argument is a whole number counting from one")
    func theTabArgumentIsAWholeNumber() {
        for bad in [JSONValue.integer(0), .integer(-2), .string("1"), .number(1.5), .bool(true)] {
            guard case .failure(let refusal) =
                WorkspaceTabChoice.parse(number: bad, title: nil) else {
                Issue.record("\(bad) was not refused"); return
            }
            #expect(refusal.sentence.contains("'tab'"))
        }
    }

    @Test("a title that is not text is refused with what the argument takes")
    func aTitleMustBeText() {
        guard case .failure(let refusal) =
            WorkspaceTabChoice.parse(number: nil, title: .integer(2)) else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("'title'"))
        #expect(refusal.sentence.contains("'tab'"))
    }

    // MARK: - Finding the tab that was named

    @Test("a number picks the tab at that place")
    func aNumberPicksATab() {
        #expect(
            (try? WorkspaceTabChoice.choose(.number(3), among: strip).get())?.title == "Terminal 1"
        )
    }

    @Test("a title picks a tab, whatever case it was typed in")
    func aTitlePicksATab() {
        #expect(
            (try? WorkspaceTabChoice.choose(.title("terminal 1"), among: strip).get())?.number == 3
        )
        #expect(
            (try? WorkspaceTabChoice.choose(.title("Fix the parser"), among: strip).get())?.number
                == 1
        )
    }

    /// A model told only "no such tab" calls again with another guess; one handed the strip picks
    /// off it.
    @Test("a number nothing answers to is refused with the tabs that are there")
    func anUnknownNumberListsTheRealTabs() {
        guard case .failure(let refusal) = WorkspaceTabChoice.choose(.number(9), among: strip)
        else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("no tab 9"))
        #expect(refusal.sentence.contains("1 'Fix the parser' (chat)"))
        #expect(refusal.sentence.contains("3 'Terminal 1' (terminal)"))
        #expect(refusal.sentence.contains("workspace_tabs"))
    }

    @Test("a title nothing answers to is refused with the tabs that are there")
    func anUnknownTitleListsTheRealTabs() {
        guard case .failure(let refusal) =
            WorkspaceTabChoice.choose(.title("Deploy"), among: strip) else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("no tab called 'Deploy'"))
        #expect(refusal.sentence.contains("3 'Terminal 1' (terminal)"))
    }

    /// Two chats can carry one name, and a reader who renamed both meant something by it. Guessing
    /// between them would be selecting a tab the caller did not name, which is the one thing this
    /// tool must not do.
    @Test("a title two tabs share is refused with their numbers rather than guessed at")
    func anAmbiguousTitleIsRefused() {
        let twins = [chat(1, title: "Review"), terminal(2, title: "Review")]
        guard case .failure(let refusal) =
            WorkspaceTabChoice.choose(.title("review"), among: twins) else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("2 tabs are called 'review'"))
        #expect(refusal.sentence.contains("1 'Review' (chat)"))
        #expect(refusal.sentence.contains("2 'Review' (terminal)"))
        #expect(refusal.sentence.contains("'tab'"))
    }

    /// A workspace with nothing in the centre column is a different fact from a name that does not
    /// match, and it has to read as one: the refusal says what opens a tab, since this tool never
    /// will.
    @Test("an empty strip is told so, and told what opens a tab")
    func anEmptyStripIsToldSo() {
        guard case .failure(let refusal) = WorkspaceTabChoice.choose(.number(1), among: []) else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("nothing open"))
        #expect(refusal.sentence.contains("pane_open"))
    }

    /// A refusal is text a model has to read before it can try again, and a workspace with thirty
    /// tabs would otherwise spend the whole of it listing them. Ten and a tail, which is what
    /// `BridgeProjectLookup.listing` does with projects.
    @Test("a refusal over a long strip lists ten tabs and counts the rest")
    func aLongStripIsCappedInTheRefusal() {
        let many = (1...30).map { chat($0, title: "Chat \($0)") }
        guard case .failure(let refusal) = WorkspaceTabChoice.choose(.number(99), among: many)
        else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("10 'Chat 10' (chat)"))
        #expect(!refusal.sentence.contains("11 'Chat 11' (chat)"))
        #expect(refusal.sentence.contains("and 20 more"))
    }

    // MARK: - What a selection that worked says

    /// The success half, which had no test at all: the branch stubbed these sentences in the tool
    /// tests and asserted every refusal instead.
    @Test("a tab that was already in front is a success saying nothing moved")
    func alreadyInFrontIsASuccess() {
        guard case .selected(let sentence) =
            WorkspaceTabSelection.alreadyInFront(chat(2, title: "Fix the parser", active: true))
        else {
            Issue.record("expected a success"); return
        }
        #expect(sentence.contains("'Fix the parser'"))
        #expect(sentence.contains("already the tab in front"))
        // Never the word this tool must not be able to say about itself.
        #expect(!sentence.contains("Opened"))
    }

    /// Selecting a chat also moves the workspace's active conversation, which the caller could not
    /// have predicted, so the sentence says so.
    @Test("a chat brought forward says it is the active conversation now")
    func aChatSaysItIsActiveNow() {
        guard case .selected(let sentence) =
            WorkspaceTabSelection.brought(chat(1, title: "Fix the parser")) else {
            Issue.record("expected a success"); return
        }
        #expect(sentence.contains("Brought 'Fix the parser' to the front of the strip."))
        #expect(sentence.contains("active conversation"))
    }

    @Test("every other kind is brought forward and claims nothing more")
    func otherKindsSayOnlyWhatHappened() {
        let others: [WorkspaceTabReport] = [
            terminal(1, title: "Terminal 1"),
            browser(2, title: "Bloom"),
            review(3, file: "PaneCensus.swift"),
        ]
        for tab in others {
            guard case .selected(let sentence) = WorkspaceTabSelection.brought(tab) else {
                Issue.record("expected a success for \(tab.title)"); return
            }
            #expect(sentence == "Brought '\(tab.title)' to the front of the strip.")
        }
    }

    // MARK: - The tools themselves

    @Test("both are a parent's tools and nobody else's")
    func bothArePartOfTheParentFamily() {
        let listing = WorkspaceTabsTool { _ in nil }
        let selecting = WorkspaceTabSelectTool { _, _ in .refused("no") }
        #expect(listing.roles == [.parent])
        #expect(selecting.roles == [.parent])
    }

    /// A connection standing in no workspace is refused by name rather than being advertised a
    /// tool that could never work. The role gate keeps `.owner` from seeing these at all; this is
    /// the second half of the same rule, for a caller that speaks raw MCP at the socket.
    @Test("a connection with no workspace is refused, and the refusal names the tool")
    func noWorkspaceIsRefusedByName() async throws {
        let store = try makeTestStore("workspace-tabs")
        let handlers: [any BridgeToolHandling] = [
            WorkspaceTabsTool { _ in WorkspaceTabCensus(tabs: []) },
            WorkspaceTabSelectTool { _, _ in .selected("should not be reached") },
        ]
        for handler in handlers {
            let result = await handler.call(
                MCPRequest(id: .integer(1), method: handler.tool.name, params: .object([:])),
                as: .owner,
                store: store
            )
            #expect(result.isError, "\(handler.tool.name)")
            #expect(result.text.contains(handler.tool.name))
        }
    }

    @Test("a workspace the window has lost is a sentence rather than an empty listing")
    func aLostWorkspaceIsASentence() async throws {
        let store = try makeTestStore("workspace-tabs-gone")
        let result = await WorkspaceTabsTool { _ in nil }.call(
            MCPRequest(id: .integer(1), method: "workspace_tabs", params: .object([:])),
            as: identity,
            store: store
        )
        #expect(result.isError)
        #expect(result.text == WorkspaceTabTrouble.noWorkspace)
    }

    @Test("the listing reaches the model as the census the window built")
    func theCensusTravels() async throws {
        let store = try makeTestStore("workspace-tabs-census")
        let tabs = strip
        let tool = WorkspaceTabsTool { _ in WorkspaceTabCensus(tabs: tabs) }
        let result = await tool.call(
            MCPRequest(id: .integer(1), method: "workspace_tabs", params: .object([:])),
            as: identity,
            store: store
        )
        #expect(!result.isError)
        #expect(result.text.contains("Fix the parser"))
        #expect(result.text.contains("Terminal 1"))
        // The last tab in the strip, so the answer is whole rather than truncated. Not an
        // address: this strip's only browser is inside a split, and a split pane deliberately
        // reports kind, title and number and no more. What a browser tab of its own says is
        // `aBrowserCarriesItsNumber` above.
        #expect(result.text.contains("PaneCensus.swift"))
    }

    /// The choice is parsed in the core and handed over whole, so the window is never asked to
    /// read an argument a second time.
    @Test("the choice reaches the window as the caller wrote it")
    func theChoiceReachesTheWindow() async throws {
        let store = try makeTestStore("workspace-tab-select")
        let seen = Recorder()
        let tool = WorkspaceTabSelectTool { choice, _ in
            await seen.record(choice)
            return .selected("Brought 'Notes' to the front of the strip.")
        }
        let result = await tool.call(
            MCPRequest(
                id: .integer(1),
                method: "workspace_tab_select",
                params: .object(["title": .string("Notes")])
            ),
            as: identity,
            store: store
        )
        #expect(!result.isError)
        #expect(result.text.contains("Brought 'Notes'"))
        #expect(await seen.choices == [.title("Notes")])
    }

    @Test("a refusal from the window reaches the model as an errored result")
    func aRefusalTravels() async throws {
        let store = try makeTestStore("workspace-tab-refusal")
        let tool = WorkspaceTabSelectTool { _, _ in .refused("There is no tab 4 in this workspace.") }
        let result = await tool.call(
            MCPRequest(
                id: .integer(1),
                method: "workspace_tab_select",
                params: .object(["tab": .integer(4)])
            ),
            as: identity,
            store: store
        )
        #expect(result.isError)
        #expect(result.text.contains("no tab 4"))
    }

    /// A bad argument is refused before the window is reached at all, because a call that has not
    /// said which tab it means must not be able to move anything.
    @Test("a call that names no tab never reaches the window")
    func aCallThatNamesNoTabNeverReachesTheWindow() async throws {
        let store = try makeTestStore("workspace-tab-unparsed")
        let seen = Recorder()
        let tool = WorkspaceTabSelectTool { choice, _ in
            await seen.record(choice)
            return .selected("should not be reached")
        }
        let result = await tool.call(
            MCPRequest(
                id: .integer(1), method: "workspace_tab_select", params: .object([:])
            ),
            as: identity,
            store: store
        )
        #expect(result.isError)
        #expect(await seen.choices.isEmpty)
    }

    // MARK: - What Bloom answers for itself

    /// Both report or move the window's own furniture in the workspace whose agent is asking, and
    /// both have to work while nobody is watching: an unanswered ask is a hung turn.
    @Test("both are Bloom's own tools and need no confirmation")
    func bothAreSelfApproved() {
        #expect(BridgeToolApproval.isSelfApproved(
            toolName: BridgeToolApproval.toolPrefix + "workspace_tabs"
        ))
        #expect(BridgeToolApproval.isSelfApproved(
            toolName: BridgeToolApproval.toolPrefix + "workspace_tab_select"
        ))
        // And the one that publishes is still deliberately not.
        #expect(!BridgeToolApproval.selfApproved.contains("workspace_merge"))
    }

    // MARK: - Support

    private var identity: BridgeIdentity {
        BridgeIdentity(sessionID: SessionID("s"), workspaceID: WorkspaceID("w"), role: .parent)
    }

    /// What the window was asked for, so a test can assert on the choice rather than on the
    /// sentence that came back.
    private actor Recorder {
        var choices: [WorkspaceTabChoice] = []

        func record(_ choice: WorkspaceTabChoice) {
            choices.append(choice)
        }
    }
}
