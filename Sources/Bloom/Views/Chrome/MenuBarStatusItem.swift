import AppKit
import BloomCore

/// The optional menu bar item: which agents are running, which finished while you were away, and
/// one click to land on either.
///
/// An `NSStatusItem` rather than SwiftUI's `MenuBarExtra`. `MenuBarExtra(isInserted:)` is the
/// obvious way to express a status item that can be switched off, and on macOS 26 a scene whose
/// `isInserted` binding is false spins the process at 100% CPU for as long as the app runs. That
/// was measured: the same build with the scene removed idles at 0%, and with the binding forced
/// true it also idles at 0%. A `SceneBuilder` has no `buildOptional`, so the scene cannot be
/// wrapped in an `if` either. AppKit's own status item has neither problem and removes cleanly.
///
/// The menu is rebuilt on every open rather than kept in sync, because it is read at most once
/// every few minutes and building it costs one pass over the workspace list.
@MainActor
final class MenuBarStatusItem: NSObject, NSMenuDelegate {
    static let shared = MenuBarStatusItem()

    /// Off unless somebody asks for it. A second permanent place for the app to live is a taste
    /// decision, and the dock already carries the count. Shared with the General settings pane,
    /// which writes it.
    static let settingKey = "menuBar.showsStatusItem"

    private var item: NSStatusItem?
    private weak var app: AppModel?
    private var runningCount = 0

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
        created.button?.image = NSImage(
            systemSymbolName: "point.3.connected.trianglepath.dotted",
            accessibilityDescription: "Bloom"
        )
        created.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        created.menu = menu
        item = created
        refreshTitle()
    }

    func setRunningCount(_ count: Int) {
        runningCount = count
        refreshTitle()
    }

    /// The count sits beside the mark, because the number is the whole reason to glance up here.
    /// Blank rather than "0", for the same reason the dock badge is cleared rather than zeroed.
    private func refreshTitle() {
        item?.button?.title = runningCount > 0 ? " \(runningCount)" : ""
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let running = app?.workspaces.filter { app?.isRunning($0) ?? false } ?? []
        // The same flag the sidebar's unread mark is drawn from, so the two cannot disagree.
        let waiting = app?.workspaces.filter { $0.unread && !(app?.isRunning($0) ?? false) } ?? []

        if running.isEmpty, waiting.isEmpty {
            menu.addItem(disabled("No agents running"))
        }

        if !running.isEmpty {
            menu.addItem(disabled("Running"))
            for workspace in running {
                menu.addItem(entry(for: workspace, symbol: "circle.fill", label: "Agent running"))
            }
        }

        if !waiting.isEmpty {
            if !running.isEmpty { menu.addItem(.separator()) }
            menu.addItem(disabled("Waiting for you"))
            for workspace in waiting {
                menu.addItem(entry(for: workspace, symbol: "envelope.badge", label: "Unread"))
            }
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Bloom", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func entry(for workspace: Workspace, symbol: String, label: String) -> NSMenuItem {
        let item = NSMenuItem(title: workspace.name, action: #selector(select(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = workspace.id
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        raiseWindow()
        NotificationCenter.default.post(name: .bloomOpenWorkspace, object: id)
    }

    @objc private func openWindow() {
        raiseWindow()
    }

    private func raiseWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
