import Testing
@testable import BloomCore

/// Back and Forward across workspaces and the tabs inside them.
@Suite("Navigation history")
struct NavigationHistoryTests {
    private let first = WorkspaceID("first")
    private let second = WorkspaceID("second")
    private let chat = PaneContent.chat(SessionID("chat"))
    private let terminal = PaneContent.tool("terminal")

    private func place(_ id: WorkspaceID, _ tab: PaneContent? = nil) -> NavigationPlace {
        NavigationPlace(selection: .workspace(id), tab: tab)!
    }

    private func visited(_ places: NavigationPlace...) -> NavigationHistory {
        var history = NavigationHistory()
        for each in places { history.visit(each) }
        return history
    }

    private let everywhere: (NavigationPlace) -> Bool = { _ in true }

    @Test("back and forward walk the places in order")
    func walksInOrder() {
        var history = visited(place(first, chat), place(first, terminal), place(second))

        let toTerminal = history.move(-1, isReachable: everywhere)
        let toChat = history.move(-1, isReachable: everywhere)
        let backToTerminal = history.move(1, isReachable: everywhere)

        #expect(toTerminal == place(first, terminal))
        #expect(toChat == place(first, chat))
        #expect(backToTerminal == place(first, terminal))
    }

    @Test("nothing before the first place or after the last")
    func endsAreEnds() {
        var history = visited(place(first), place(second))

        #expect(!history.canMove(1, isReachable: everywhere))
        let forward = history.move(1, isReachable: everywhere)
        #expect(forward == nil)

        _ = history.move(-1, isReachable: everywhere)
        #expect(!history.canMove(-1, isReachable: everywhere))
        let back = history.move(-1, isReachable: everywhere)
        #expect(back == nil)
        #expect(history.index == 0)
    }

    @Test("an empty history has nowhere to go")
    func emptyHistory() {
        let history = NavigationHistory()
        #expect(!history.canMove(-1, isReachable: everywhere))
        #expect(!history.canMove(1, isReachable: everywhere))
    }

    @Test("the place you are already on is not recorded twice")
    func repeatedPlaceIsIgnored() {
        let history = visited(place(first, chat), place(first, chat))
        #expect(history.places.count == 1)
    }

    @Test("a tab found after arriving completes the arrival instead of adding a step")
    func tabCompletesArrival() {
        let history = visited(place(first), place(first, chat))
        #expect(history.places == [place(first, chat)])

        let later = visited(place(first, chat), place(first, terminal))
        #expect(later.places.count == 2)
    }

    /// Arriving on a workspace with two chats files it before the strip has loaded. Moving to the
    /// second chat has to leave the first one behind as a place Back can return to.
    @Test("leaving the tab a workspace opened on keeps it as a step")
    func settleKeepsTheArrivalTab() {
        var history = visited(place(second), place(first))
        history.settle(chat, in: first)
        history.visit(place(first, terminal))

        #expect(history.places == [place(second), place(first, chat), place(first, terminal)])
    }

    /// Open a workspace on its chat, then click Terminal 1 and Terminal 2: Back must retrace
    /// Terminal 1, then the chat, then the workspace before.
    @Test("back retraces the tab a workspace was entered on")
    func backRetracesTheEnteredTab() {
        var history = visited(place(first), place(second))
        history.settle(chat, in: second)
        history.visit(place(second, .tool("terminal-1")))
        history.settle(.tool("terminal-1"), in: second)
        history.visit(place(second, .tool("terminal-2")))

        let toFirstTerminal = history.move(-1, isReachable: everywhere)
        let toChat = history.move(-1, isReachable: everywhere)
        let toFirst = history.move(-1, isReachable: everywhere)

        #expect(toFirstTerminal == place(second, .tool("terminal-1")))
        #expect(toChat == place(second, chat))
        #expect(toFirst == place(first))
    }

    @Test("settling touches only the place the cursor is on, and only an untabbed one")
    func settleLeavesOthersAlone() {
        var filed = visited(place(first, chat))
        filed.settle(terminal, in: first)
        #expect(filed.places == [place(first, chat)])

        var elsewhere = visited(place(first))
        elsewhere.settle(chat, in: second)
        #expect(elsewhere.places == [place(first)])
    }

    /// Forward only has an answer after a Back, so a new place must cut the old future off.
    @Test("visiting after going back drops what was ahead")
    func visitingDropsTheFuture() {
        var history = visited(place(first), place(second), place(first, terminal))
        _ = history.move(-1, isReachable: everywhere)
        _ = history.move(-1, isReachable: everywhere)

        history.visit(place(second, chat))

        #expect(history.places == [place(first), place(second, chat)])
        #expect(!history.canMove(1, isReachable: everywhere))
    }

    @Test("places that are gone are stepped over in both directions")
    func unreachablePlacesAreSkipped() {
        var history = visited(place(first), place(second), place(first, terminal))
        let secondIsGone: (NavigationPlace) -> Bool = { $0.selection != .workspace(second) }

        let back = history.move(-1, isReachable: secondIsGone)
        let forward = history.move(1, isReachable: secondIsGone)

        #expect(back == place(first))
        #expect(forward == place(first, terminal))
    }

    @Test("a history with only unreachable places left does not move")
    func nothingReachableLeavesTheCursor() {
        var history = visited(place(first), place(second))
        let nowhere: (NavigationPlace) -> Bool = { _ in false }

        #expect(!history.canMove(-1, isReachable: nowhere))
        let moved = history.move(-1, isReachable: nowhere)
        #expect(moved == nil)
        #expect(history.index == 1)
    }

    @Test("the oldest place falls off past the capacity")
    func capacityDropsTheOldest() {
        var history = NavigationHistory()
        for number in 0...NavigationHistory.capacity {
            history.visit(place(WorkspaceID("workspace-\(number)")))
        }

        #expect(history.places.count == NavigationHistory.capacity)
        #expect(history.places.first == place(WorkspaceID("workspace-1")))
        #expect(history.index == NavigationHistory.capacity - 1)
    }

    // MARK: - What counts as a place

    @Test("a subagent or crew member is filed as its workspace")
    func narrowedSelectionsAreTheWorkspace() {
        let subagent = NavigationPlace(selection: .subagent(first, SubagentID("agent")), tab: chat)
        let call = NavigationPlace(selection: .subagentCall(first, toolUseID: "call"), tab: chat)
        let crew = NavigationPlace(selection: .crew(first, SessionID("member")), tab: chat)

        #expect(subagent == place(first, chat))
        #expect(call == place(first, chat))
        #expect(crew == place(first, chat))
    }

    @Test("archived items are read, not worked in, so they are not places")
    func archivedItemsAreNotPlaces() {
        #expect(NavigationPlace(selection: .archived(first), tab: nil) == nil)
        #expect(NavigationPlace(selection: .archivedConversation(SessionID("old")), tab: nil) == nil)
    }

    @Test("a tab only means something inside a workspace")
    func tabsBelongToWorkspaces() {
        #expect(NavigationPlace(selection: .home, tab: chat)?.tab == nil)
        #expect(NavigationPlace(selection: .mail, tab: chat)?.tab == nil)
        #expect(NavigationPlace(selection: .conversation(SessionID("loose")), tab: chat)?.tab == nil)
    }

    // MARK: - Control+Tab

    @Test("Control+Tab goes forward and Shift+Control+Tab back")
    func controlTab() {
        #expect(NavigationHistory.step(forTabWith: [.control]) == 1)
        #expect(NavigationHistory.step(forTabWith: [.control, .shift]) == -1)
    }

    @Test("every other Tab belongs to somebody else")
    func otherTabsAreLeftAlone() {
        #expect(NavigationHistory.step(forTabWith: []) == nil)
        #expect(NavigationHistory.step(forTabWith: [.shift]) == nil)
        #expect(NavigationHistory.step(forTabWith: [.option]) == nil)
        #expect(NavigationHistory.step(forTabWith: [.control, .option]) == nil)
        #expect(NavigationHistory.step(forTabWith: [.control, .command]) == nil)
    }
}
