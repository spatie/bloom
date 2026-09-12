import AppKit
import SwiftUI
import BloomCore

/// The menu bar item: the starred usage figures beside each provider's mark, a cup while the Mac is
/// being kept awake, how many agents are waiting on a person and how many finished unread, and a
/// menu under a click.
///
/// An `NSStatusItem` rather than SwiftUI's `MenuBarExtra`. `MenuBarExtra(isInserted:)` is the
/// obvious way to express a status item that can be switched off, and on macOS 26 a scene whose
/// `isInserted` binding is false spins the process at 100% CPU for as long as the app runs. That
/// was measured: the same build with the scene removed idles at 0%, and with the binding forced
/// true it also idles at 0%. A `SceneBuilder` has no `buildOptional`, so the scene cannot be
/// wrapped in an `if` either. AppKit's own status item has neither problem and removes cleanly.
///
/// **A menu, and a custom view for exactly one row of it.** This was a panel for a while, a
/// borderless `NSPanel` holding a whole SwiftUI dashboard, and the owner's verdict on it was that
/// the limits were better and everything else had stopped feeling like a Mac. So the rows are menu
/// items again, with their own highlight, submenus and checkmarks, and the limits hang in the
/// middle of them as a hosted view, because a proportion is the one thing a menu item's title
/// cannot draw. What the panel could do and a menu cannot, dragging and hovering, moved into
/// Settings ▸ Menu Bar.
///
/// The menu is rebuilt on every open rather than kept in sync, because it is read at most once
/// every few minutes and building it costs one pass over the workspace list. That is also what
/// makes the checkmarks correct for free: they are read out of `UserDefaults` at the moment the
/// menu opens, so they agree with the Settings window without either of them watching the other.
@MainActor
final class MenuBarStatusItem: NSObject, NSMenuDelegate {
    static let shared = MenuBarStatusItem()

    /// Shared with the Menu Bar settings pane, which writes it.
    static let settingKey = "menuBar.showsStatusItem"

    /// On.
    ///
    /// It shipped off, on the reasoning that a second permanent place for the app to live is a
    /// taste decision and the Dock already carries the count. What that produced was a feature
    /// nobody found: it was asked for again, from scratch, by the person it had already been built
    /// for. A menu bar item that has to be switched on before it can be discovered cannot be
    /// discovered.
    static let isOnByDefault = true

    private var item: NSStatusItem?
    private weak var app: AppModel?
    private var unreadCount = 0
    private var waitingCount = 0
    private var keepsAwake = false
    private var strip = MenuBarUsageStrip()
    private let model = UsageMenuModel.shared

    private override init() {}

    /// Inserts or removes the item. Idempotent, so the reporter can call it on every change.
    func setEnabled(_ isEnabled: Bool, app: AppModel) {
        self.app = app
        model.refresh = { [weak app] in
            guard let app else { return }
            Task { await app.refreshQuotas(after: 0) }
        }

        guard isEnabled else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        guard item == nil else { return }

        let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        created.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        created.menu = menu
        item = created
        observeUsage()
        refreshButton()
        claimPlaceInMenuBar(created)
    }

    // MARK: - The mark

    /// Bloom's own mark, out of the bundle, as a template image. Drawn when no starred metric has a
    /// figure yet, when figures are switched off, and when every provider is.
    ///
    /// `Resources/BloomMenuBar.pdf`, drawn by `Tools/icon/menubar.py` from the same eased lane the
    /// app icon is built from. It is a reduction rather than a scaling: at fifteen points the
    /// icon's ground, panel and three bands close into a texture, so what survives is the one
    /// gesture, three lanes arriving and one leaving.
    ///
    /// A PDF because AppKit redraws a PDF at whatever scale the display asks for, so one file is
    /// right on the built-in display and on an external 1x monitor, where a bitmap tuned for
    /// Retina loses its gaps.
    ///
    /// A TEMPLATE, not a white picture. The status bar tints a template with the menu bar's own
    /// label colour, which makes it white on a dark bar, near black on a light one, and inverted
    /// again while the menu is open. A white image would be right in exactly one of those cases.
    private static let mark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "BloomMenuBar", withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else {
            let fallback = NSImage(
                systemSymbolName: "point.3.connected.trianglepath.dotted",
                accessibilityDescription: "Bloom"
            )
            fallback?.isTemplate = true
            return fallback
        }
        image.isTemplate = true
        image.accessibilityDescription = "Bloom"
        return image
    }()

    // MARK: - Placement

    /// Makes sure the item ends up where it is drawn.
    ///
    /// A new status item's window is parked flush against the right-hand edge of the screen while
    /// the system works out where in the menu bar it belongs, and is moved to its real slot about
    /// a tenth of a second later. On macOS 26 that move sometimes never arrives: the window is
    /// given the menu bar's height and left at the parked position, while the item itself is drawn
    /// in its proper slot by the system, out of this process. It happened on eleven launches out of
    /// forty, and on none out of twenty an hour earlier, so it is a race whose odds move with
    /// whatever else is inserting and removing items at the same moment.
    ///
    /// Nothing looks wrong until the item is clicked. A menu opens against the window rather than
    /// against the drawn item, so it appears at the far right of the screen, under the clock, a
    /// third of a screen away from the icon that opened it. That is the whole bug.
    ///
    /// Taking the item out of the bar and putting it straight back asks for a place again, and the
    /// second ask lands. Checked rather than done blindly, so an item that was placed correctly is
    /// never disturbed, and checked more than once, because an answer that went missing can go
    /// missing twice.
    private func claimPlaceInMenuBar(_ item: NSStatusItem, attemptsLeft: Int = 3) {
        guard attemptsLeft > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard self.item === item, Self.isParked(item) else { return }
            item.isVisible = false
            item.isVisible = true
            claimPlaceInMenuBar(item, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Whether the item's window is still where the system parks one it has not placed: flush
    /// against the right-hand edge of the screen. A real slot never reaches that edge, because the
    /// clock and Control Center sit to the right of anything an app can add.
    private static func isParked(_ item: NSStatusItem) -> Bool {
        guard let window = item.button?.window else { return false }
        guard let screen = window.screen ?? NSScreen.main else { return false }
        return window.frame.maxX >= screen.frame.maxX
    }

    // MARK: - What it counts

    /// The same number the Dock badge shows, from the same `DockBadge` count, so the two places
    /// Bloom speaks from while it is behind another window cannot disagree.
    func setUnreadCount(_ count: Int) {
        guard count != unreadCount else { return }
        unreadCount = count
        refreshButton()
    }

    /// Workspaces whose agent has stopped and is waiting on a person.
    func setWaitingCount(_ count: Int) {
        guard count != waitingCount else { return }
        waitingCount = count
        refreshButton()
    }

    /// Whether idle sleep is being held off right now, by a Keep Awake session or by an agent
    /// running with the switch on. `AgentActivity` says so after every change to the assertion.
    func setKeepsAwake(_ isOn: Bool) {
        guard isOn != keepsAwake else { return }
        keepsAwake = isOn
        refreshButton()
    }

    /// Follows the quotas, the accounts, the layout and the display settings, and redraws the strip
    /// when any of them moves.
    ///
    /// A tracking loop rather than a view modifier, because the strip has to stay right with every
    /// window closed, which is exactly when a modifier on the main window stops being evaluated.
    private func observeUsage() {
        guard let app, item != nil else { return }
        let metrics = withObservationTracking {
            _ = model.layout
            _ = model.options
            _ = model.iconStyle
            _ = model.showsUsage
            return UsageCatalogue.metrics(quotas: app.quotas, accounts: app.accounts)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeUsage() }
        }
        model.adopt(metrics)
        strip = model.showsUsage
            ? MenuBarUsageStrip.make(layout: model.layout, metrics: metrics, options: model.options)
            : MenuBarUsageStrip()
        refreshButton()
    }

    // MARK: - The glance

    private func refreshButton() {
        guard let button = item?.button else { return }
        if !strip.isEmpty, let image = MenuBarStripImage.image(for: strip, style: model.iconStyle) {
            button.image = image
        } else {
            button.image = Self.mark
        }

        let segments = MenuBarSummary.segments(waiting: waitingCount, unread: unreadCount)
        let showsCup = keepsAwake && model.showsCup
        button.attributedTitle = Self.title(for: segments, keepsAwake: showsCup, font: button.font)

        var spoken = [MenuBarSummary.tooltip(waiting: waitingCount, unread: unreadCount)]
        if showsCup { spoken.insert(KeepAwake.onHeadline, at: 0) }
        if !strip.isEmpty { spoken.insert(strip.spoken, at: 0) }
        button.toolTip = spoken.joined(separator: "\n")
        button.setAccessibilityLabel("Bloom. " + spoken.joined(separator: ". "))
    }

    /// Gap between the image and the first glyph, and between one glyph and the next. Wider
    /// between pairs than inside one, so "hand one envelope two" groups the way it is meant to.
    private static let leadingGap: CGFloat = 4
    private static let betweenGap: CGFloat = 7

    private static func title(
        for segments: [MenuBarSummary.Segment],
        keepsAwake: Bool,
        font: NSFont?
    ) -> NSAttributedString {
        let title = NSMutableAttributedString()
        let font = font ?? NSFont.menuBarFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            // The status bar inverts its contents wholesale when the menu bar is dark or the item
            // is pressed, and it can only do that to a template image and to `labelColor`.
            .foregroundColor: NSColor.labelColor,
        ]
        var isFirst = true
        func gap() {
            title.append(NSAttributedString(
                string: " ",
                attributes: [.font: font, .kern: isFirst ? leadingGap : betweenGap]
            ))
            isFirst = false
        }

        if keepsAwake, let cup = glyph(named: KeepAwake.menuBarSymbol, label: KeepAwake.onHeadline, font: font) {
            gap()
            title.append(cup)
        }
        for segment in segments {
            gap()
            if let glyph = glyph(named: segment.symbolName, label: segment.label, font: font) {
                title.append(glyph)
                title.append(NSAttributedString(string: " ", attributes: attributes))
            }
            title.append(NSAttributedString(string: String(segment.count), attributes: attributes))
        }
        return title
    }

    /// One SF Symbol as a run of text.
    ///
    /// Sized off the menu bar font rather than a literal, and dropped onto the text baseline by
    /// hand: an attachment's box sits ON the baseline by default, so an unadjusted glyph floats a
    /// descender's height above the digits next to it.
    private static func glyph(named name: String, label: String, font: NSFont) -> NSAttributedString? {
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.72, weight: .semibold)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration) else { return nil }
        image.isTemplate = true

        let attachment = NSTextAttachment()
        attachment.image = image
        let size = image.size
        attachment.bounds = CGRect(x: 0, y: font.descender * 0.5, width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    // MARK: - The menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Somebody is about to read the limits, so ask for fresher ones. Not awaited: a menu that
        // waited on two subprocesses would open a second after it was clicked, and what this drops
        // in arrives on the store's own feed, ready the next time the menu opens.
        if let app {
            Task { await app.refreshQuotas(after: QuotaPollSchedule.onDemandFloor) }
        }

        // Keep Awake first: it is the one thing in here people open the menu to change rather than
        // to read.
        for item in keepAwakeItems() { menu.addItem(item) }

        if let limits = limitsItem() {
            menu.addItem(.separator())
            menu.addItem(limits)
        }

        menu.addItem(.separator())
        addWorkspaces(to: menu)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Menubar Settings\u{2026}", keyEquivalent: ",") {
            SettingsTabRequest.post(.menuBar)
            Self.openBloomSettings()
        })
        menu.addItem(.separator())
        // Target left nil so it travels the responder chain to `NSApp`, which is what runs
        // `applicationShouldTerminate` and therefore what stops on a running turn.
        menu.addItem(NSMenuItem(
            title: "Quit Bloom",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }

    // MARK: Keep Awake

    private func keepAwakeItems() -> [NSMenuItem] {
        let keepAwake = KeepAwakeModel.shared
        let session = keepAwake.session
        let remaining = session?.until.map { UsageFormat.compactDuration($0.timeIntervalSinceNow) }

        let toggle = ClosureMenuItem(remaining.map { "Keep Awake (\($0) left)" } ?? KeepAwake.title) {
            if keepAwake.isActive { keepAwake.stop() } else { keepAwake.start(for: nil) }
        }
        toggle.state = keepAwake.isActive ? .on : .off
        toggle.toolTip = SleepPrevention.caveat

        let durations = NSMenu()
        durations.addItem(ClosureMenuItem("Indefinitely") { keepAwake.start(for: nil) })
        durations.addItem(Self.submenu("Minutes", KeepAwake.minuteChoices.map { count in
            ClosureMenuItem(KeepAwake.label(minutes: count)) { keepAwake.start(for: TimeInterval(count * 60)) }
        }))
        durations.addItem(Self.submenu("Hours", KeepAwake.hourChoices.map { count in
            ClosureMenuItem(KeepAwake.label(hours: count)) { keepAwake.start(for: TimeInterval(count * 3600)) }
        }))
        durations.addItem(.separator())
        durations.addItem(ClosureMenuItem("Until a Time\u{2026}") { Self.askForTime() })
        let durationsItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        durationsItem.submenu = durations

        let defaults = UserDefaults.standard
        let whileRunning = ClosureMenuItem(SleepPrevention.menuItemTitle) {
            // Written, not just registered, so the choice survives a relaunch.
            // `AgentActivityReporter` watches the same key and retakes or drops the assertion.
            defaults.set(!defaults.bool(forKey: SleepPrevention.settingKey), forKey: SleepPrevention.settingKey)
        }
        whileRunning.state = defaults.bool(forKey: SleepPrevention.settingKey) ? .on : .off
        whileRunning.toolTip = SleepPrevention.caveat

        let lid = ClosureMenuItem("Keep Awake With the Lid Closed") {
            keepAwake.keepsLidClosed.toggle()
        }
        lid.state = keepAwake.keepsLidClosed ? .on : .off
        lid.toolTip = "A closing lid sleeps the Mac whatever an app asks for. This turns the system "
            + "sleep switch off for the length of a session, which needs Bloom's helper."

        return [toggle, durationsItem, whileRunning, lid]
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu()
        for item in items { menu.addItem(item) }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    /// "Until a Time…", as a sheetless alert with a clock in it, because a menu cannot hold a date
    /// picker and a whole window for one time of day is a window too many.
    private static func askForTime() {
        let alert = NSAlert()
        alert.messageText = "Keep this Mac awake until"
        alert.informativeText = "A time that has already gone today is taken as tomorrow."
        alert.addButton(withTitle: "Keep Awake")
        alert.addButton(withTitle: "Cancel")

        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.hourMinute]
        picker.dateValue = Date().addingTimeInterval(3600)
        alert.accessoryView = picker

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        KeepAwakeModel.shared.start(until: KeepAwake.nextOccurrence(of: picker.dateValue, after: Date()))
    }

    // MARK: The limits

    /// The limits, hosted in a menu item.
    ///
    /// The item is disabled on purpose. AppKit highlights a custom view's item under the pointer
    /// exactly as it would a real command, and a block that lights up when you cross it and then
    /// does nothing when you click reads as a bug. Disabling it costs the accessibility label,
    /// which is why one is set by hand.
    ///
    /// The view is measured with `fittingSize` and pinned: an `NSHostingView` inside a menu item is
    /// given no layout pass by the menu, so a view left to size itself lands with a zero height
    /// frame and the row collapses to nothing.
    private func limitsItem() -> NSMenuItem? {
        guard model.showsUsage, let app else { return nil }
        let metrics = model.metrics(quotas: app.quotas, accounts: app.accounts)
        let sections = model.layout.sections(for: metrics)
        guard !sections.isEmpty else { return nil }

        let host = NSHostingView(rootView: UsageMenuBlock(
            model: model,
            metrics: metrics,
            accounts: app.accounts,
            observedAt: Self.oldestReadings(app.quotas),
            now: Date()
        ))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)

        let item = NSMenuItem()
        item.view = host
        item.isEnabled = false
        item.setAccessibilityLabel(MenuBarSummary.limitSentence(for: QuotaBoard.make(from: app.quotas)))
        return item
    }

    static func oldestReadings(_ quotas: [AgentQuota]) -> [AgentKind: Date] {
        Dictionary(grouping: quotas, by: \.provider).compactMapValues { $0.map(\.observedAt).min() }
    }

    // MARK: Workspaces

    private func addWorkspaces(to menu: NSMenu) {
        let sections = MenuBarSummary.sections(
            in: app?.workspaces ?? [],
            isRunning: { app?.isRunning($0) ?? false },
            isAwaitingPermission: { app?.isAwaitingPermission($0) ?? false }
        )
        guard !sections.isEmpty else {
            menu.addItem(disabled(MenuBarSummary.emptyTitle))
            return
        }
        for section in sections {
            menu.addItem(disabled(section.heading))
            for workspace in section.workspaces {
                let item = NSMenuItem(title: workspace.name, action: #selector(select(_:)), keyEquivalent: "")
                item.target = self
                item.represent(workspace.id)
                item.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.label)
                menu.addItem(item)
            }
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let id = sender.represented(WorkspaceID.self) else { return }
        MainWindow.raise()
        OpenWorkspaceNotification.post(id)
    }

    /// Opens the `Settings` scene from a menu, which is not a view.
    ///
    /// `NSApp.sendAction(Selector(("showSettingsWindow:")))` is the answer usually given and it
    /// does nothing here: SwiftUI installs that action on the menu item rather than on the
    /// responder chain. Driving the item itself is what opens the window, which is the same thing
    /// `Snapshot.openSettingsWindow` records having found out.
    static func openBloomSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // Matched by prefix, because the item carries an ellipsis.
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.title.hasPrefix("Settings") })
        else { return }
        appMenu.performActionForItem(at: index)
    }
}

/// A menu item that runs a closure, for the rows this menu builds by hand.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, keyEquivalent: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
    }
}
