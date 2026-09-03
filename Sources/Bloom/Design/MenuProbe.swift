#if DEBUG
import AppKit
import SwiftUI
import BloomCore

/// Photographs the centre pane's contextual menu, or the items one of its split submenus offers.
///
///     Bloom --menu-probe /tmp/menu.png [--menu-part menu|kinds|terminal|terminalKinds|browser|row|colour|worktree|project|projectHidden|filter|diffScope] [--menu-project <path>] [--menu-base <branch>]
///
/// It exists because a menu is the one part of this interface that cannot be captured any other
/// way. `ImageRenderer` draws SwiftUI's yellow placeholder for one, a menu only exists while it is
/// being tracked, and `screencapture -l` handed a menu window's number returns the whole display on
/// this machine, which would put whatever the owner happens to be doing into a PNG. So the menu is
/// built here, opened here, measured here, and the capture is a rectangle exactly the size of the
/// menu's own windows: opaque menu pixels and nothing else.
///
/// The menus are the real ones. `CenterPaneMenu`, `PaneKindItems`, `WorkspaceMenuItems` and
/// `WorktreeMenuItems` are the same views the app hands to `.contextMenu` and to its overflow
/// buttons, built here with closures that do nothing, so a picture taken by this probe cannot show
/// an item the app does not have.
///
/// `terminal` is the odd one and is the reason `present` exists. It is `TerminalPaneMenu`, put up
/// through a real `BloomTerminalView`'s right mouse handling rather than through `NSMenu.popUp`,
/// because those two do not draw the same menu: AppKit merges the text input system's own items
/// into a contextual menu as it presents it, and they never appear in `NSMenu.items` at all. A
/// picture taken the easy way would be a picture of a menu the app never shows.
///
/// `browser` is half ours and half WebKit's. The page's contextual menu is WebKit's, and on this
/// macOS it is drawn out of process: the `NSMenu` that begins tracking holds one hidden placeholder
/// item and never the rows on screen, so there is nothing to read and the photograph is the only
/// account of what the menu says. Under it are the pane's own items, which `BrowserPageWebView`
/// merges in, and they are the reason this part is worth having: whether they arrive and whether
/// they draw is a question only a picture answers. It is put up by right clicking a real
/// `BrowserSession`'s page view, on a page loaded from a string, so nothing is fetched to take a
/// picture. WebKit answers a right click through its web process rather than on the way back out
/// of the event, so this part cannot use the loop below: it sends the click and waits.
///
/// `row` and `colour` are a workspace row's menu and the colour submenu inside it. They need a
/// workspace, so they read one out of the database this instance was pointed at, which means they
/// want `BLOOM_DB_PATH` set at a seeded scratch copy rather than the owner's.
///
/// `project` and `projectHidden` are a project header's own menu, in both of the wordings it has,
/// and they read a project out of that same database: `projectHidden` wants one that really is
/// hidden. `filter` is the sidebar's filter control, which needs nothing at all, since both of its
/// halves are handed to it.
///
/// `worktree` is the inspector's "More for this worktree" menu. It takes a `Workspace` rather than
/// a `WorkspaceModel`, so it needs no database and no window state at all: the branch and the path
/// are made up here, and every item that is not about them is the app's own. `--menu-project`
/// supplies the worktree path, so the applications offered are the ones that would really be
/// offered for a checkout on this machine. No pull request, which is the shape a workspace has
/// before anything is pushed and the shortest the menu ever is.
///
/// **There is no `style` part any more.** The composer's output style picker was here, and it is
/// not a menu now: it and the permission picker are panels of two line rows, because their rows
/// carry a sentence and an `NSMenu` row is one line. A probe that photographed a menu the app no
/// longer draws would be exactly the failure the paragraph above is written against, so the two
/// went to `ComposerPickerGallery`, which is rendered offscreen in both appearances and needs
/// nobody's screen.
///
/// The two are photographed separately because AppKit tracks one menu at a time. A submenu cannot
/// be opened beside the item it hangs off from inside the process: popping the submenu up while its
/// parent is open ends the parent's session, and hovering is not available either, since AppKit
/// highlights on mouse MOVEMENT and the only pointer on this machine is the owner's. A menu that
/// merely appears under a stationary pointer highlights nothing, which is what the first attempt at
/// this photographed.
///
/// Nothing is clicked, nothing is typed and the pointer is never moved.
///
/// Debug builds only. A shipped copy has no business being able to open a menu nobody asked for.
@MainActor
enum MenuProbe {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--menu-probe")
    }

    private static func value(for flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static var outputPath: String {
        value(for: "--menu-probe") ?? (NSTemporaryDirectory() + "bloom-menu.png")
    }

    /// Which menu to open. `menu` is the pane's own and is the default.
    private enum Part: String {
        case menu
        /// The three items a split submenu is made of.
        case kinds
        /// A terminal pane's own menu, put up the way a right click puts it up.
        case terminal
        /// The three items one of its split submenus is made of.
        case terminalKinds
        /// A browser page's own menu, which is WebKit's and not Bloom's.
        case browser
        /// A workspace row's context menu, as both lists offer it.
        case row
        /// The colour submenu inside it, on its own, because AppKit tracks one menu at a time.
        case colour
        /// The inspector's overflow menu for the worktree it is looking at.
        case worktree
        /// A project header's context menu, for a project that is showing.
        case project
        /// The same menu for a project that is hidden, which is one item's wording apart and is
        /// the half nobody would otherwise look at.
        case projectHidden
        /// The sidebar's filter control, which narrows the workspaces and decides whether hidden
        /// projects are listed.
        case filter
        /// The Changes tab's scope menu: what the file list is measured from.
        case diffScope
    }

    private static var part: Part {
        value(for: "--menu-part").flatMap(Part.init(rawValue:)) ?? .menu
    }

    static func schedule() {
        Task { @MainActor in
            // `--appearance light|dark` reaches a menu the same way it reaches a window capture.
            // Without this a menu could only ever be photographed in whichever appearance the
            // machine happened to be in, and half of every colour decision in one went unlooked at.
            Snapshot.applyRequestedAppearance()
            // The same beat the window capture waits for, and for the same reason: the window has
            // to exist before a menu can be opened over it.
            try? await Task.sleep(for: .seconds(3))
            // A model of this probe's own, rather than the one the window is drawing from, which
            // no static can reach. It reads the same database, so the workspace it finds is a
            // workspace the sidebar is showing.
            var model: AppModel?
            if part == .row || part == .colour || part == .project || part == .projectHidden {
                let fresh = AppModel()
                await fresh.bootstrap()
                // The row menu's setup item is drawn only for a workspace that has a live
                // `WorkspaceModel` with its repository's settings read, which in the app is every
                // workspace you have selected. Prepared here, awaited rather than fired off,
                // because the menu below is built synchronously and a settings read that has not
                // landed yet would photograph as the shorter menu an unopened workspace has. This
                // is not a view body, which is the rule `AppModel.model(for:)` is written against.
                if let workspace = fresh.workspaces.first {
                    await fresh.model(for: workspace).reloadSettings()
                }
                model = fresh
            }
            // The commits in this menu are read out of a real repository with `git log`, so the
            // rows are commits that exist rather than rows written down here. `--menu-project`
            // points at the checkout: a scratch clone, never the owner's own, since this reads a
            // worktree and a worktree is a thing somebody may be working in.
            if part == .diffScope {
                scopeModel = await preparedScopeModel()
            }
            if part == .browser {
                await runBrowser()
                return
            }
            run(model: model)
        }
    }

    private static func run(model: AppModel?) {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.contentView != nil && $0.parent == nil && $0.styleMask.contains(.titled)
        }) else {
            fail("no window to open a menu from")
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let menu = build(model: model)

        // Over the app's own window, so the menu is the only thing in the rectangle below it.
        let origin = NSPoint(x: window.frame.minX + 260, y: window.frame.maxY - 220)

        // Tried more than once, because the owner is at this machine: a click anywhere else on the
        // desktop dismisses a menu this process opened, and a run that gave up on the first one
        // reported a failure that was really somebody typing.
        for _ in 0..<6 where !capturedOutput {
            // The capture has to run while the menu is tracking, and tracking is its own run loop
            // mode: presenting does not return until the menu closes. A timer added to the common
            // modes is delivered inside it, which is why it is scheduled before the menu opens
            // rather than written after it.
            let timer = after(0.4) {
                capturedOutput = capture(to: outputPath)
                menu.cancelTracking()
            }
            present(menu, at: origin, in: window)
            timer.invalidate()
        }

        guard capturedOutput else { fail("the menu would not stay open long enough to photograph") }
        print(outputPath)
        exit(0)
    }

    /// Puts the menu on screen, and does not return until it closes again.
    ///
    /// Two ways, because there are two menus. `NSMenu.popUp` is the plain one and is what every
    /// SwiftUI menu here is photographed with. The terminal's goes up the way a right click puts
    /// it up, through `BloomTerminalView`, because AppKit adds items of its own on that path and
    /// only on that path, and whether they are there is the whole question this picture answers.
    private static func present(_ menu: NSMenu, at origin: NSPoint, in window: NSWindow) {
        guard part == .terminal, let pane = terminalPane, let content = window.contentView else {
            menu.popUp(positioning: nil, at: origin, in: nil)
            return
        }

        // In the window, because a view outside one has no window number to put on the event, and
        // AppKit hit tests the contextual menu against the window the event names.
        if pane.superview == nil {
            pane.frame = content.bounds
            content.addSubview(pane)
        }

        let point = NSPoint(x: 260, y: content.bounds.height - 220)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { fail("could not build a right click to open the terminal's menu with") }

        pane.rightMouseDown(with: event)
    }

    /// The shell the terminal menu is photographed over. No process is ever started in it: it is
    /// here to be the `NSView` AppKit asks for a menu, and an empty one draws the same.
    private static let terminalPane: BloomTerminalView? = {
        guard MenuProbe.part == .terminal else { return nil }
        return BloomTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    }()

    /// The menu this run photographs, built from the very views the app shows.
    private static func build(model: AppModel?) -> NSMenu {
        switch part {
        // Split, so the pane menu carries every item it can carry: Close Pane is only offered
        // when there is a pane to close back to.
        case .menu:
            NSHostingMenu(rootView: CenterPaneMenu(isSplit: true, split: { _, _ in }, close: {}))
        case .kinds:
            NSHostingMenu(rootView: PaneKindItems { _ in })
        case .terminal:
            terminalMenu()
        // The submenu on its own, for the reason the two centre menus are separate parts.
        case .terminalKinds:
            terminalSplitKinds()
        // Never asked for: `runBrowser` takes that part and this is not reached for it.
        case .browser:
            NSMenu()
        case .row, .colour:
            workspaceMenu(model: model)
        case .project, .projectHidden:
            projectMenu(model: model)
        case .filter:
            NSHostingMenu(rootView: SidebarFilterMenuItems(
                filter: .constant(.all), showsHiddenProjects: .constant(true), hiddenCount: 2
            ))
        case .worktree:
            NSHostingMenu(rootView: worktreeItems)
        case .diffScope:
            NSHostingMenu(rootView: DiffScopeMenuItems(model: requiredScopeModel))
        }
    }

    /// The pane menu a split terminal offers, with every item it can carry: Close Pane is only
    /// offered when there is a pane to close back to.
    private static func terminalMenu() -> NSMenu {
        let menu = TerminalPaneMenu.make(canClose: true, isZoomed: false) { _ in }
        // The view answers with this one, which is what puts it through AppKit's own contextual
        // menu path rather than round it. See `present`.
        terminalPane?.onContextMenu = { menu }
        return menu
    }

    private static func terminalSplitKinds() -> NSMenu {
        let menu = TerminalPaneMenu.make(canClose: true, isZoomed: false) { _ in }
        guard let kinds = menu.items.first?.submenu else {
            fail("the terminal pane menu has no split submenu")
        }
        // The parent is kept, not just the submenu. It is the menu that owns the items' action
        // target, `NSMenuItem.target` is weak, and a menu whose target has gone validates every
        // row against the responder chain instead and draws the lot greyed out. That is what the
        // first picture of this submenu was.
        parentOfKinds = menu
        return kinds
    }

    // MARK: - The page's own menu

    /// Right clicks a live browser page and photographs whatever WebKit puts up.
    ///
    /// Separate from `run` because the two menus arrive by different routes. Every other part here
    /// is an `NSMenu` this file built, opened with a call that does not return until it closes.
    /// WebKit's is neither: the click goes to the web process, the menu is opened from the reply,
    /// and the call that delivered the click returned long before. So the capture is armed first
    /// and the click is sent after it, and the wait that follows is what lets the menu happen.
    ///
    /// The page is loaded from a string rather than fetched. A picture of a menu says nothing
    /// about where the page came from, and a probe that reaches the network to take one is a probe
    /// that fails on a train.
    private static func runBrowser() async {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.contentView != nil && $0.parent == nil && $0.styleMask.contains(.titled)
        }), let content = window.contentView else {
            fail("no window to open a menu from")
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Empty, so the session has nothing to load and the page below is the only thing in it.
        let session = BrowserSession(url: "")
        // The pane's own menu, which the page puts under WebKit's. Split, so Close Pane is in the
        // picture: it is only offered when there is a pane to close back to. The same view
        // `CenterPaneView` hands down, so this cannot photograph items the app does not have.
        session.webView.paneMenu = {
            NSHostingMenu(rootView: CenterPaneMenu(isSplit: true, split: { _, _ in }, close: {}))
        }
        session.pageView.frame = content.bounds
        content.addSubview(session.pageView)
        session.webView.loadHTMLString(
            "<body style='font:16px -apple-system'><p>Probe page</p></body>",
            baseURL: URL(string: "http://localhost/")
        )
        // Long enough for a string to become a page. There is no navigation to wait on that this
        // file owns: the session's own delegate is the one WebKit will call.
        try? await Task.sleep(for: .seconds(2))

        let point = NSPoint(x: 200, y: content.bounds.height - 200)
        guard let click = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { fail("could not build a right click to open the page's menu with") }

        // Tried more than once, for the reason `run` tries more than once: the owner is at this
        // machine and a click of his anywhere else takes the menu away again. There is no flag to
        // read between goes, because the run that works never comes back here.
        for _ in 0..<6 {
            let timer = after(1.2) {
                if capture(to: outputPath) {
                    print(outputPath)
                    // From inside the timer, because tracking owns the run loop until the menu
                    // closes and there is nothing left to do once the picture is taken.
                    exit(0)
                }
            }
            window.sendEvent(click)
            try? await Task.sleep(for: .seconds(3))
            timer.invalidate()
        }

        fail("the page's menu would not stay open long enough to photograph")
    }

    private static var parentOfKinds: NSMenu?

    /// The inspector's worktree menu, over a workspace invented here.
    ///
    /// Nothing is read and nothing is written: the only fields this menu touches are the branch it
    /// copies and the path it offers, and a path that exists is what makes the Open Worktree in
    /// submenu answer with the applications a real checkout would be offered.
    /// The workspace the scope menu is built from, prepared before the menu is, because building
    /// a menu is synchronous and a `git log` is not. Nil until `schedule` has filled it in.
    private static var scopeModel: WorkspaceModel?

    /// The same, as a value rather than an optional. Every case of `build` is an expression, and
    /// a `guard` in one of them turns the whole switch into a statement whose other cases then
    /// return nothing at all.
    private static var requiredScopeModel: WorkspaceModel {
        guard let scopeModel else { fail("no worktree to read commits from") }
        return scopeModel
    }

    /// A workspace pointed at a real checkout, with one refresh already landed.
    ///
    /// The refresh is awaited rather than fired off. `refreshChanges` is what reads the branch's
    /// commits, and a menu built before it lands photographs as the two rows a branch with no
    /// history has, which is a picture of the wrong thing.
    private static func preparedScopeModel() async -> WorkspaceModel {
        let path = value(for: "--menu-project") ?? FileManager.default.currentDirectoryPath
        let app = AppModel()
        let model = WorkspaceModel(
            workspace: Workspace(
                repoID: .new(),
                name: "Probe",
                branch: "probe/menu",
                path: path,
                baseBranch: value(for: "--menu-base") ?? "main"
            ),
            app: app
        )
        scopeApp = app
        await model.refreshChanges()
        return model
    }

    /// Held for as long as the probe runs: a `WorkspaceModel` keeps its `AppModel` unowned.
    private static var scopeApp: AppModel?

    private static var worktreeItems: WorktreeMenuItems {
        let path = value(for: "--menu-project") ?? FileManager.default.currentDirectoryPath
        return WorktreeMenuItems(
            workspace: Workspace(
                repoID: .new(),
                name: "Probe",
                branch: "probe/menu",
                path: path,
                baseBranch: "main"
            ),
            pullRequest: nil
        )
    }

    /// A project header's menu, for a project read out of the database this instance was pointed
    /// at. The hidden half asks for a project that really is hidden rather than flipping a copy's
    /// flag, so the picture is of a menu the app would actually draw for a row it would actually
    /// list.
    private static func projectMenu(model: AppModel?) -> NSMenu {
        guard let model else { fail("no model to read a project out of") }
        let wantsHidden = part == .projectHidden
        guard let repo = model.repos.first(where: { $0.hidden == wantsHidden }) else {
            fail(wantsHidden
                ? "no hidden project in this database to draw a header menu for"
                : "no showing project in this database to draw a header menu for")
        }
        return NSHostingMenu(rootView: ProjectMenuItems(
            repo: repo, onCreateWorkspace: { _ in }, onRename: {}, onRemove: {}
        ).environment(model))
    }

    private static func workspaceMenu(model: AppModel?) -> NSMenu {
        guard let model, let workspace = model.workspaces.first else {
            fail("no workspace in this database to draw a row menu for")
        }
        let menu = NSHostingMenu(
            rootView: WorkspaceMenuItems(workspace: workspace) { _ in }.environment(model)
        )
        guard part == .colour else { return menu }
        // The submenu on its own. Popping it up beside its open parent is not available: that ends
        // the parent's tracking session, which is the same limit the two pane menus are split for.
        guard let submenu = menu.items.first(where: { $0.title == "Colour" })?.submenu else {
            fail("the row menu has no Colour submenu")
        }
        return submenu
    }

    /// Whether a picture has been taken, which is what stops the retry loop above.
    private static var capturedOutput = false

    // MARK: - Capture

    /// The rectangle the open menu covers, in the coordinates `screencapture -R` speaks.
    ///
    /// Read from the window server rather than from `NSMenu.size`, because a menu is placed by
    /// AppKit as it opens and shifts itself off a screen edge without saying so. Only windows
    /// belonging to THIS process are considered, and only ones at the menu level, so the rectangle
    /// can never be larger than the menu itself.
    private static func menuBounds() -> CGRect? {
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        guard let windows = listed as? [[String: Any]] else { return nil }

        let menuLevel = CGWindowLevelForKey(.popUpMenuWindow)
        var union: CGRect?
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == getpid(),
                  let level = window[kCGWindowLayer as String] as? Int, level >= menuLevel,
                  let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: raw), !frame.isEmpty else { continue }
            union = union.map { $0.union(frame) } ?? frame
        }
        return union
    }

    private static func capture(to path: String) -> Bool {
        guard let bounds = menuBounds() else { return false }
        try? FileManager.default.removeItem(atPath: path)

        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // `-R` is a rectangle rather than a display or a window, and this one is the menu's own
        // bounds, which the menu is painted over completely. `-x` keeps it silent.
        capture.arguments = [
            "-x",
            "-R\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width)),\(Int(bounds.height))",
            path,
        ]
        do {
            try capture.run()
        } catch {
            return false
        }
        capture.waitUntilExit()
        return capture.terminationStatus == 0 && FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Plumbing

    /// A timer in the common modes, which menu tracking is one of. `DispatchQueue.main.asyncAfter`
    /// is not: a block posted that way sits in the queue until the menu closes, which is exactly
    /// too late to photograph it.
    @discardableResult
    private static func after(
        _ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { work() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}
#endif
