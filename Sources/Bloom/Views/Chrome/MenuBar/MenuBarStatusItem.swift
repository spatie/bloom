import AppKit
import SwiftUI
import BloomCore

/// The menu bar item: the starred usage figures beside each provider's mark, a cup while the Mac is
/// being kept awake, how many agents are waiting on a person and how many finished unread, and the
/// usage panel under a click.
///
/// An `NSStatusItem` rather than SwiftUI's `MenuBarExtra`. `MenuBarExtra(isInserted:)` is the
/// obvious way to express a status item that can be switched off, and on macOS 26 a scene whose
/// `isInserted` binding is false spins the process at 100% CPU for as long as the app runs. That
/// was measured: the same build with the scene removed idles at 0%, and with the binding forced
/// true it also idles at 0%. A `SceneBuilder` has no `buildOptional`, so the scene cannot be
/// wrapped in an `if` either. AppKit's own status item has neither problem and removes cleanly.
///
/// **A left click opens a panel rather than a menu.** The limits used to be a disabled menu item
/// holding a hosting view at the top of an `NSMenu`, which could not scroll, could not hold a
/// control, and was measured once and never resized. The panel is `UsagePanelController`'s, and it
/// carries everything the menu did: the limits, the workspaces waiting, running and finished, and
/// Open, Settings and Quit. A right click still gets a short menu, because a status item that has
/// no menu at all is one that cannot be quit from without first finding its panel's Options.
@MainActor
final class MenuBarStatusItem: NSObject {
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
    private var keepsAwake = false
    private var strip = MenuBarUsageStrip()
    private let panel = UsagePanelController()

    private override init() {}

    /// Inserts or removes the item. Idempotent, so the reporter can call it on every change.
    func setEnabled(_ isEnabled: Bool, app: AppModel) {
        self.app = app

        guard isEnabled else {
            panel.hide()
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        guard item == nil else { return }

        let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = created.button {
            button.image = Self.mark
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        item = created
        observeUsage()
        refreshButton()
        claimPlaceInMenuBar(created)
    }

    // MARK: - The mark

    /// Bloom's own mark, out of the bundle, as a template image. Drawn when no starred metric has a
    /// figure yet, which is also the first second of every launch.
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
    /// again while the item is pressed. A white image would be right in exactly one of those cases.
    ///
    /// The SF Symbol this replaced is kept as the fallback, for the one case that produces
    /// nothing to draw: a bundle assembled without the resource.
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
    /// Nothing looks wrong until the item is clicked. The panel is placed against the window
    /// rather than against the drawn item, so it appears at the far right of the screen, under the
    /// clock, a third of a screen away from the icon that opened it. That is the whole bug.
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

    // MARK: - What it counts

    /// The same number the Dock badge shows, from the same `DockBadge` count, so the two places
    /// Bloom speaks from while it is behind another window cannot disagree.
    func setUnreadCount(_ count: Int) {
        guard count != unreadCount else { return }
        unreadCount = count
        refreshButton()
    }

    /// Workspaces whose agent has stopped and is waiting on a person. Drawn first among the counts,
    /// because it is the only one that costs something to ignore.
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
    /// Metrics seen for the first time are adopted here, so a new window arrives starred by default
    /// without anybody having to open the panel first.
    private func observeUsage() {
        guard let app, item != nil else { return }
        let model = UsagePanelModel.shared
        let metrics = withObservationTracking {
            _ = model.layout
            _ = model.options
            _ = model.iconStyle
            return UsageCatalogue.metrics(quotas: app.quotas, accounts: app.accounts)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeUsage() }
        }
        model.adopt(metrics)
        strip = MenuBarUsageStrip.make(layout: model.layout, metrics: metrics, options: model.options)
        refreshButton()
    }

    // MARK: - The glance

    /// The strip or the mark, then the cup and the counts, each with the glyph that says what it is.
    private func refreshButton() {
        guard let button = item?.button else { return }
        if !strip.isEmpty,
           let image = MenuBarStripImage.image(for: strip, style: UsagePanelModel.shared.iconStyle) {
            button.image = image
        } else {
            button.image = Self.mark
        }

        let segments = MenuBarSummary.segments(waiting: waitingCount, unread: unreadCount)
        button.attributedTitle = Self.title(for: segments, keepsAwake: keepsAwake, font: button.font)

        var spoken = [MenuBarSummary.tooltip(waiting: waitingCount, unread: unreadCount)]
        if keepsAwake { spoken.insert(KeepAwake.onHeadline, at: 0) }
        if !strip.isEmpty { spoken.insert(strip.spoken, at: 0) }
        button.toolTip = spoken.joined(separator: "\n")
        // VoiceOver would otherwise read the digits and none of the glyphs, which is worse than
        // nothing. "Bloom" first, because in the menu bar the item has to name itself.
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
        // The menu bar's own font, whatever size the user's menu bar is drawn at, so the numbers
        // sit on the same baseline as every other item's text.
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

        // Nothing is said about the glyph here. An attachment carries no accessible text, and
        // `NSAttributedString` has no key on macOS for giving it one, so the whole item is
        // labelled instead, in `refreshButton`, where the sentence can name every part.
        return NSAttributedString(attachment: attachment)
    }

    // MARK: - Clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        guard let app else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu(from: sender)
        } else {
            panel.toggle(from: sender, app: app)
        }
    }

    /// The short menu under a right click: the window, Keep Awake in Amphetamine's shape, the
    /// panel's Settings, and Quit.
    ///
    /// Attached for the length of one click and taken off again, because a status item that owns
    /// a menu shows it on every click and the left click belongs to the panel.
    private func showContextMenu(from button: NSStatusBarButton) {
        panel.hide()
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open Bloom") { MainWindow.raise() })
        menu.addItem(Self.keepAwakeItem())
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Usage Settings\u{2026}") { [weak self] in
            guard let self, let app = self.app, let button = self.item?.button else { return }
            self.panel.show(from: button, app: app, screen: .settings)
        })
        menu.addItem(ClosureMenuItem("Bloom Settings\u{2026}") { Self.openBloomSettings() })
        menu.addItem(.separator())
        // Target left nil so it travels the responder chain to `NSApp`, which is what runs
        // `applicationShouldTerminate` and therefore what stops on a running turn.
        menu.addItem(NSMenuItem(title: "Quit Bloom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item?.menu = menu
        button.performClick(nil)
        item?.menu = nil
    }

    private static func keepAwakeItem() -> NSMenuItem {
        let keepAwake = KeepAwakeModel.shared
        let menu = NSMenu()
        if keepAwake.isActive {
            menu.addItem(ClosureMenuItem("Stop Keeping Awake") { keepAwake.stop() })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Indefinitely") { keepAwake.start(for: nil) })

        let minutes = NSMenu()
        for count in KeepAwake.minuteChoices {
            minutes.addItem(ClosureMenuItem(KeepAwake.label(minutes: count)) { keepAwake.start(for: TimeInterval(count * 60)) })
        }
        let minutesItem = NSMenuItem(title: "Minutes", action: nil, keyEquivalent: "")
        minutesItem.submenu = minutes
        menu.addItem(minutesItem)

        let hours = NSMenu()
        for count in KeepAwake.hourChoices {
            hours.addItem(ClosureMenuItem(KeepAwake.label(hours: count)) { keepAwake.start(for: TimeInterval(count * 3600)) })
        }
        let hoursItem = NSMenuItem(title: "Hours", action: nil, keyEquivalent: "")
        hoursItem.submenu = hours
        menu.addItem(hoursItem)

        menu.addItem(.separator())
        let whileRunning = ClosureMenuItem(SleepPrevention.menuItemTitle) {
            // Written, not just registered, so the choice survives a relaunch. `AgentActivityReporter`
            // watches the same key and is what retakes or drops the assertion.
            let defaults = UserDefaults.standard
            defaults.set(!defaults.bool(forKey: SleepPrevention.settingKey), forKey: SleepPrevention.settingKey)
        }
        whileRunning.state = UserDefaults.standard.bool(forKey: SleepPrevention.settingKey) ? .on : .off
        whileRunning.toolTip = SleepPrevention.caveat
        menu.addItem(whileRunning)

        let parent = NSMenuItem(title: KeepAwake.title, action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: KeepAwake.menuBarSymbol, accessibilityDescription: nil)
        parent.submenu = menu
        return parent
    }

    /// Opens the `Settings` scene from somewhere that is not a view.
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

/// A menu item that runs a closure, for the status item's short menu.
@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
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
