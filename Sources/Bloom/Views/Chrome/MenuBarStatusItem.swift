import AppKit
import BloomCore

/// The menu bar item: which agents are blocked on a question, which are running, which finished
/// while you were away, one click to land on any of them, and the switch that decides whether the
/// Mac may fall asleep underneath them.
///
/// An `NSStatusItem` rather than SwiftUI's `MenuBarExtra`. `MenuBarExtra(isInserted:)` is the
/// obvious way to express a status item that can be switched off, and on macOS 26 a scene whose
/// `isInserted` binding is false spins the process at 100% CPU for as long as the app runs. That
/// was measured: the same build with the scene removed idles at 0%, and with the binding forced
/// true it also idles at 0%. A `SceneBuilder` has no `buildOptional`, so the scene cannot be
/// wrapped in an `if` either. AppKit's own status item has neither problem and removes cleanly.
///
/// The menu is rebuilt on every open rather than kept in sync, because it is read at most once
/// every few minutes and building it costs one pass over the workspace list. That is also what
/// makes the sleep switch correct for free: it is read out of `UserDefaults` at the moment the
/// menu opens, so it agrees with the Settings pane without either of them watching the other.
@MainActor
final class MenuBarStatusItem: NSObject, NSMenuDelegate {
    static let shared = MenuBarStatusItem()

    /// Shared with the General settings pane, which writes it.
    static let settingKey = "menuBar.showsStatusItem"

    /// On.
    ///
    /// It shipped off, on the reasoning that a second permanent place for the app to live is a
    /// taste decision and the Dock already carries the count. What that produced was a feature
    /// nobody found: it was asked for again, from scratch, by the person it had already been built
    /// for. A menu bar item that has to be switched on before it can be discovered cannot be
    /// discovered. It is one row in Settings to turn off, and it is now also the only place the
    /// sleep switch can be reached from without opening a window.
    static let isOnByDefault = true

    private var item: NSStatusItem?
    private weak var app: AppModel?
    private var unreadCount = 0
    private var waitingCount = 0

    private override init() {}

    /// Inserts or removes the item. Idempotent, so the reporter can call it on every change.
    func setEnabled(_ isEnabled: Bool, app: AppModel) {
        self.app = app

        guard isEnabled else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        guard item == nil else { return }

        let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        created.button?.image = Self.mark()
        created.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        created.menu = menu
        item = created
        refreshButton()
        claimPlaceInMenuBar(created)
    }

    // MARK: - The mark

    /// Bloom's own mark, out of the bundle, as a template image.
    ///
    /// `Resources/BloomMenuBar.pdf`, drawn by `Tools/icon/menubar.py` from the same eased lane the
    /// app icon is built from. It is a reduction rather than a scaling: at fifteen points the
    /// icon's ground, panel and three bands close into a texture, so what survives is the one
    /// gesture, three lanes arriving and one leaving. The generator's docstring has the rest.
    ///
    /// A PDF because AppKit redraws a PDF at whatever scale the display asks for, so one file is
    /// right on the built-in display and on an external 1x monitor, where a bitmap tuned for
    /// Retina loses its gaps.
    ///
    /// A TEMPLATE, not a white picture. The status bar tints a template with the menu bar's own
    /// label colour, which makes it white on a dark bar, near black on a light one, and inverted
    /// again while the menu is open and the item is pressed. A white image would be right in
    /// exactly one of those four cases, and the white the owner asked for is what a template
    /// renders as anyway.
    ///
    /// The SF Symbol this replaced is kept as the fallback, for the one case that produces
    /// nothing to draw: a bundle assembled without the resource.
    private static func mark() -> NSImage? {
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
        // The item is labelled as a sentence in `refreshButton`, which can name both counts. This
        // is what VoiceOver falls back to before there is anything to count.
        image.accessibilityDescription = "Bloom"
        return image
    }

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
            // Long enough for the system to have answered one way or the other. Before it has,
            // the window is still at the parked position legitimately and there is nothing to fix.
            try? await Task.sleep(for: .milliseconds(250))
            guard self.item === item, Self.isParked(item) else { return }
            item.isVisible = false
            item.isVisible = true
            claimPlaceInMenuBar(item, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Whether the item's window is still where the system parks one it has not placed: flush
    /// against the right-hand edge of the screen.
    ///
    /// A real slot never reaches that edge, because the clock and Control Center sit to the right
    /// of anything an app can add, so there is no correctly placed item this can mistake for a
    /// parked one.
    private static func isParked(_ item: NSStatusItem) -> Bool {
        guard let window = item.button?.window else { return false }
        guard let screen = window.screen ?? NSScreen.main else { return false }
        return window.frame.maxX >= screen.frame.maxX
    }

    /// The same number the Dock badge shows, from the same `DockBadge` count, so the two places
    /// Bloom speaks from while it is behind another window cannot disagree.
    func setUnreadCount(_ count: Int) {
        guard count != unreadCount else { return }
        unreadCount = count
        refreshButton()
    }

    /// Workspaces whose agent has stopped and is waiting on a person. Drawn first in the strip,
    /// because it is the only count here that costs something to ignore.
    func setWaitingCount(_ count: Int) {
        guard count != waitingCount else { return }
        waitingCount = count
        refreshButton()
    }

    // MARK: - The glance

    /// The counts beside the mark, each with the glyph that says what it counts.
    ///
    /// Blank when there is nothing to report, rather than "0", for the same reason the Dock badge
    /// is cleared rather than zeroed. An attributed title rather than plain text because two bare
    /// numbers next to each other say nothing about which is which, and the menu bar has no room
    /// for the words.
    private func refreshButton() {
        guard let button = item?.button else { return }
        let segments = MenuBarSummary.segments(waiting: waitingCount, unread: unreadCount)
        let spoken = MenuBarSummary.tooltip(waiting: waitingCount, unread: unreadCount)
        button.attributedTitle = Self.title(for: segments, font: button.font)
        button.toolTip = spoken
        // VoiceOver would otherwise read the two digits and neither glyph, which is worse than
        // nothing. "Bloom" first, because in the menu bar the item has to name itself.
        button.setAccessibilityLabel("Bloom. \(spoken)")
    }

    /// Gap between the mark and the first count, and between one count and the next. Wider between
    /// pairs than inside one, so "hand one envelope two" groups the way it is meant to be read.
    private static let leadingGap: CGFloat = 4
    private static let betweenGap: CGFloat = 7

    private static func title(for segments: [MenuBarSummary.Segment], font: NSFont?) -> NSAttributedString {
        let title = NSMutableAttributedString()
        guard !segments.isEmpty else { return title }

        // The menu bar's own font, whatever size the user's menu bar is drawn at, so the numbers
        // sit on the same baseline as every other item's text.
        let font = font ?? NSFont.menuBarFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            // The status bar inverts its contents wholesale when the menu bar is dark or the item
            // is pressed, and it can only do that to a template image and to `labelColor`.
            .foregroundColor: NSColor.labelColor,
        ]

        for (index, segment) in segments.enumerated() {
            // A space carrying the gap as kerning, rather than two or three literal spaces whose
            // width is whatever the menu bar font happens to give them.
            title.append(NSAttributedString(
                string: " ",
                attributes: [.font: font, .kern: index == 0 ? leadingGap : betweenGap]
            ))
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

        // Nothing is said about the glyph here. An attachment carries no accessible text, and
        // `NSAttributedString` has no key on macOS for giving it one, so the whole item is
        // labelled instead, in `refreshButton`, where the sentence can name both numbers.
        return NSAttributedString(attachment: attachment)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // First, because that is where it was asked for, and because it is the one row here that
        // is about the machine rather than about a workspace.
        menu.addItem(sleepToggle())
        menu.addItem(.separator())

        // Which lists there are, in which order, and what each one is called: all of it in
        // `MenuBarSummary`, so the menu cannot fall out of step with the strip above it. Both are
        // read from the same two observable sets on `AppModel` that the counts are taken from, so
        // a hand with a 1 beside it in the menu bar and this list always name the same workspace.
        let sections = MenuBarSummary.sections(
            in: app?.workspaces ?? [],
            isRunning: { app?.isRunning($0) ?? false },
            isAwaitingPermission: { app?.isAwaitingPermission($0) ?? false }
        )

        if sections.isEmpty {
            menu.addItem(disabled(MenuBarSummary.emptyTitle))
        }

        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            menu.addItem(disabled(section.heading))
            for workspace in section.workspaces {
                menu.addItem(entry(
                    for: workspace, symbol: section.symbolName, label: section.label
                ))
            }
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Bloom", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    /// One fixed phrase with a checkmark, not a label that rewrites itself. See `SleepPrevention`.
    ///
    /// Read straight out of `UserDefaults` here rather than cached, because the menu is built at
    /// the moment it opens and this is the cheapest way for it to agree with a Settings window
    /// that may have changed the value a second ago.
    private func sleepToggle() -> NSMenuItem {
        let item = NSMenuItem(
            title: SleepPrevention.menuItemTitle,
            action: #selector(togglePreventsSleep),
            keyEquivalent: ""
        )
        item.target = self
        item.state = UserDefaults.standard.bool(forKey: SleepPrevention.settingKey) ? .on : .off
        item.toolTip = SleepPrevention.caveat
        return item
    }

    @objc private func togglePreventsSleep() {
        let defaults = UserDefaults.standard
        // Written, not just registered, so the choice survives a relaunch. `AgentActivityReporter`
        // is watching the same key through `@AppStorage` and is what actually retakes or drops the
        // assertion, so the switch has one owner whichever surface was clicked.
        defaults.set(!defaults.bool(forKey: SleepPrevention.settingKey), forKey: SleepPrevention.settingKey)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func entry(for workspace: Workspace, symbol: String, label: String) -> NSMenuItem {
        let item = NSMenuItem(title: workspace.name, action: #selector(select(_:)), keyEquivalent: "")
        item.target = self
        item.represent(workspace.id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let id = sender.represented(WorkspaceID.self) else { return }
        raiseWindow()
        OpenWorkspaceNotification.post(id)
    }

    @objc private func openWindow() {
        raiseWindow()
    }

    private func raiseWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
