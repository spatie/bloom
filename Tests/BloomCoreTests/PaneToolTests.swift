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
    @Test("a subagent cannot open, split or close panes")
    func aChildCannotTouchPanes() {
        let open = PaneOpenTool { _, _ in .opened("") }
        let split = PaneSplitTool { _, _, _ in .opened("") }
        let close = PaneCloseTool { _, _ in .opened("") }
        for roles in [open.roles, split.roles, close.roles] {
            #expect(!roles.contains(.child))
            #expect(roles.contains(.parent))
            #expect(roles.contains(.owner))
        }
    }

    /// The pair was half a pair: both of the others told the model that closing was the reader's
    /// to do, which is asking somebody to tidy up after a tool.
    @Test("closing takes the same kinds opening does, and none of its own")
    func closingSpeaksTheSameVocabulary() {
        let close = PaneCloseTool { _, _ in .opened("") }
        guard case .object(let schema) = close.tool.inputSchema,
              case .object(let properties)? = schema["properties"]
        else { Issue.record("no schema"); return }
        // A kind and nothing else: no pane id, because a model handed one would be closing
        // something by a number it guessed.
        #expect(Set(properties.keys) == ["kind"])
        // And no required argument, since leaving it out means the focused pane.
        #expect(schema["required"] == nil)
    }

    /// Both add something the reader can see and close, so neither stops a turn to ask.
    @Test("both are Bloom's own tools and need no confirmation")
    func bothAreSelfApproved() {
        #expect(BridgeToolApproval.selfApproved.contains("pane_open"))
        #expect(BridgeToolApproval.selfApproved.contains("pane_split"))
        #expect(BridgeToolApproval.selfApproved.contains("pane_close"))
        // And the one that asks for a merge is deliberately not.
        #expect(!BridgeToolApproval.selfApproved.contains("workspace_merge"))
    }
}

/// How Bloom's own bridge calls read in a transcript.
///
/// The wire name is `bloom-workspace-bridge` and has to stay that: `BridgeRegistration.serverName`
/// records why, and it is a measurement rather than a convention. What the reader sees is a
/// separate question and is answered where the reading happens.
@Suite("Bloom's own tools, as a reader meets them")
struct BloomBridgePresentationTests {
    private func present(_ tool: String) -> ToolPresentation {
        ToolPresenter.present(
            name: "mcp__\(BridgeRegistration.serverName)__\(tool)", input: .object([:])
        )
    }

    /// "bloom-workspace-bridge: pane open" names the transport where every other row names the
    /// thing that happened.
    @Test("the transport does not appear in the row")
    func theTransportIsNotTheLabel() {
        let row = present("pane_open")
        #expect(row.label == "Bloom: pane open")
        #expect(!row.label.contains("bridge"))
        #expect(!row.label.contains("workspace-bridge"))
    }

    /// The puzzle piece says "some extension" about the app the reader is already inside.
    @Test("Bloom's own tools do not wear the extension glyph")
    func bloomHasItsOwnGlyph() {
        #expect(present("pane_open").glyph != "puzzlepiece.extension")
        #expect(present("workspace_start").glyph != "puzzlepiece.extension")
    }

    /// Somebody else's server is still theirs, named and marked as an extension.
    @Test("another server is still named after itself")
    func anotherServerKeepsItsName() {
        let row = ToolPresenter.present(name: "mcp__linear__create_issue", input: .object([:]))
        #expect(row.label == "linear: create issue")
        #expect(row.glyph == "puzzlepiece.extension")
    }
}
