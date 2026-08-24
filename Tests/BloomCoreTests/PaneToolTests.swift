import Testing
@testable import BloomCore

/// What an agent may ask the window to put in front of the reader.
///
/// The parsing is the whole of what can be tested without a window, and it is the half that
/// matters: every refusal here is a sentence a model reads and acts on, and "invalid input" is the
/// one answer that makes it try the same thing again.
@Suite("Asking for a pane")
struct PaneToolTests {
    private func read(
        kind: String? = "terminal", url: String? = nil, focus: JSONValue? = nil
    ) -> PaneOrderReading {
        PaneOrder.parse(kind: kind, url: url, focus: focus, tool: "pane_open")
    }

    // MARK: - The kind

    @Test("every kind the menu offers is a kind a tool accepts")
    func everyMenuKindIsAWireKind() {
        for kind in PaneKind.allCases {
            #expect(read(kind: kind.rawValue) == .order(PaneOrder(kind: kind)))
        }
    }

    /// The refusal names what would have worked, because a model that is told only "no" repeats
    /// itself.
    @Test("an unknown kind is refused with the list of real ones")
    func anUnknownKindListsTheRealOnes() {
        guard case .refused(let sentence) = read(kind: "editor") else {
            Issue.record("expected a refusal"); return
        }
        #expect(sentence.contains("'editor'"))
        for kind in PaneKind.allCases {
            #expect(sentence.contains("'\(kind.rawValue)'"))
        }
    }

    @Test("a missing kind says which argument is missing and what it takes")
    func aMissingKindSaysSo() {
        for missing in [nil, "", "   "] as [String?] {
            guard case .refused(let sentence) = read(kind: missing) else {
                Issue.record("expected a refusal for \(String(describing: missing))"); return
            }
            #expect(sentence.contains("'kind'"))
            #expect(sentence.contains("pane_open"))
        }
    }

    @Test("surrounding whitespace is not a different kind")
    func whitespaceIsTrimmed() {
        #expect(read(kind: "  browser ") == .order(PaneOrder(kind: .browser)))
    }

    // MARK: - The url

    @Test("a browser takes a url, and keeps it")
    func aBrowserKeepsItsURL() {
        #expect(
            read(kind: "browser", url: "https://runbloom.app")
                == .order(PaneOrder(kind: .browser, url: "https://runbloom.app"))
        )
    }

    @Test("a browser without a url is fine")
    func aBrowserNeedsNoURL() {
        #expect(read(kind: "browser") == .order(PaneOrder(kind: .browser)))
        #expect(read(kind: "browser", url: "  ") == .order(PaneOrder(kind: .browser)))
    }

    /// Refused rather than ignored. A url handed to a terminal is a caller believing something
    /// about what it is opening, and dropping it silently leaves the belief in place.
    @Test("a url on anything but a browser is refused rather than dropped")
    func aURLElsewhereIsRefused() {
        for kind in PaneKind.allCases where kind != .browser {
            guard case .refused(let sentence) = read(kind: kind.rawValue, url: "https://x.test")
            else {
                Issue.record("expected a refusal for \(kind)"); return
            }
            #expect(sentence.contains("browser"))
        }
    }

    // MARK: - Focus

    /// "Open me a terminal" means the terminal, in front.
    @Test("focus defaults to yes")
    func focusDefaultsToYes() {
        guard case .order(let order) = read() else { Issue.record("expected an order"); return }
        #expect(order.focus)
    }

    @Test("focus can be turned off, and only by a boolean")
    func focusIsABoolean() {
        #expect(read(focus: .bool(false)) == .order(PaneOrder(kind: .terminal, focus: false)))
        #expect(read(focus: .bool(true)) == .order(PaneOrder(kind: .terminal, focus: true)))
        #expect(read(focus: .null) == .order(PaneOrder(kind: .terminal, focus: true)))

        guard case .refused(let sentence) = read(focus: .string("yes")) else {
            Issue.record("expected a refusal"); return
        }
        #expect(sentence.contains("'focus'"))
    }

    /// The one fact the caller could not have known is whether the pane is in front, so the
    /// sentence it gets back has to say.
    @Test("what the model is told says whether the reader is looking at it")
    func theConfirmationSaysWhereItWent() {
        #expect(PaneOrder(kind: .terminal).confirmation.contains("front"))
        #expect(PaneOrder(kind: .terminal, focus: false).confirmation.contains("background"))
        #expect(
            PaneOrder(kind: .browser, url: "https://runbloom.app").confirmation
                .contains("https://runbloom.app")
        )
    }

    // MARK: - The direction of a split

    /// `horizontal` meaning side by side is the thing everyone reads backwards, so the wire says
    /// what the reader sees and the enum stays the app's.
    @Test("beside is side by side, below is stacked, and beside is the default")
    func theDirectionIsNamedForTheReader() throws {
        #expect(try PaneSplitTool.axis(named: "beside").get() == .horizontal)
        #expect(try PaneSplitTool.axis(named: "below").get() == .vertical)
        #expect(try PaneSplitTool.axis(named: nil).get() == .horizontal)
        #expect(try PaneSplitTool.axis(named: "  BESIDE ").get() == .horizontal)
    }

    @Test("an unknown direction is refused with the two that work")
    func anUnknownDirectionIsRefused() {
        guard case .failure(let refusal) = PaneSplitTool.axis(named: "diagonally") else {
            Issue.record("expected a refusal"); return
        }
        #expect(refusal.sentence.contains("beside"))
        #expect(refusal.sentence.contains("below"))
    }

    // MARK: - Who may call them

    /// A subagent opening tabs in its parent's window is a pane arriving from something the
    /// reader did not address.
    @Test("a subagent cannot open panes")
    func aChildCannotOpenPanes() {
        let open = PaneOpenTool { _, _ in .opened("") }
        let split = PaneSplitTool { _, _, _ in .opened("") }
        #expect(!open.roles.contains(.child))
        #expect(!split.roles.contains(.child))
        #expect(open.roles.contains(.parent))
        #expect(split.roles.contains(.parent))
    }

    /// Both add something the reader can see and close, so neither stops a turn to ask.
    @Test("both are Bloom's own tools and need no confirmation")
    func bothAreSelfApproved() {
        #expect(BridgeToolApproval.selfApproved.contains("pane_open"))
        #expect(BridgeToolApproval.selfApproved.contains("pane_split"))
        // And the one that asks for a merge is deliberately not.
        #expect(!BridgeToolApproval.selfApproved.contains("workspace_merge"))
    }
}
