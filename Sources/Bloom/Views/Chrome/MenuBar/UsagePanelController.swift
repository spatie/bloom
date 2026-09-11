import AppKit
import SwiftUI
import BloomCore

/// The window the usage panel is drawn in.
///
/// **A borderless, non-activating panel rather than an `NSMenu` or an `NSPopover`.** The limits
/// used to hang inside the status item's menu as a disabled item holding a hosting view, which is
/// as far as a menu goes: it cannot scroll, cannot hold a control that is not a menu item, cannot
/// resize while open, and is measured once with `fittingSize` and never again. OpenUsage, which
/// this panel is modelled on, went through the same argument and landed here: a panel that becomes
/// key without activating the app, so the buttons, pickers and the keyboard all work while whatever
/// the person was using stays frontmost.
final class UsagePanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Shows, places and dismisses the usage panel.
@MainActor
final class UsagePanelController {
    private let model = UsagePanelModel.shared
    private var panel: UsagePanelWindow?
    private weak var button: NSStatusBarButton?
    private weak var app: AppModel?
    private var monitors: [Any] = []
    /// What the SwiftUI content says it wants, before the screen clamps it.
    private var idealHeight: CGFloat = 480

    /// Tuned to read like a system menu bar popover, which is what OpenUsage measured it against.
    private static let cornerRadius: CGFloat = 13
    private static let gapBelowMenuBar: CGFloat = 4
    private static let screenMargin: CGFloat = 8
    private static let minimumHeight: CGFloat = 200

    var isShown: Bool { panel?.isVisible == true }

    func toggle(from button: NSStatusBarButton, app: AppModel) {
        if isShown { hide() } else { show(from: button, app: app) }
    }

    func show(from button: NSStatusBarButton, app: AppModel, screen: UsagePanelModel.Screen = .dashboard) {
        self.button = button
        self.app = app
        let panel = self.panel ?? makePanel(app: app)
        self.panel = panel

        model.dismiss = { [weak self] in self?.hide() }
        model.refresh = { [weak app] in
            guard let app else { return }
            Task { await app.refreshQuotas(after: 0) }
        }
        model.themeDidChange = { [weak self] in
            guard let self else { return }
            self.panel?.appearance = self.model.appearance
        }
        model.navigate(to: screen, animated: false)
        panel.appearance = model.appearance

        place(panel)
        panel.makeKeyAndOrderFront(nil)
        // The first button would otherwise wear a focus ring the moment the panel appears.
        panel.makeFirstResponder(nil)
        button.highlight(true)
        startMonitors()

        // Somebody is about to read the figures, so ask for fresher ones, subject to the same
        // floor the menu had. The answer lands through the store's feed and redraws in place,
        // which a menu could never do.
        Task { await app.refreshQuotas(after: QuotaPollSchedule.onDemandFloor) }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        button?.highlight(false)
        stopMonitors()
        model.tooltip = nil
        model.navigate(to: .dashboard, animated: false)
    }

    private func makePanel(app: AppModel) -> UsagePanelWindow {
        let panel = UsagePanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: UsagePanelView.width, height: idealHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No open or close animation: it appears, like a menu does.
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = UsagePanelView(app: app, model: model) { [weak self] height in
            self?.setIdealHeight(height)
        }
        let host = NSHostingView(rootView: root)
        // The panel's size is decided here from the content's report, never by the hosting view
        // resizing its own window, which fights the clamp to the screen.
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.cornerRadius = Self.cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        panel.contentView = host
        return panel
    }

    private func setIdealHeight(_ height: CGFloat) {
        guard abs(height - idealHeight) > 0.5 else { return }
        idealHeight = height
        if let panel, panel.isVisible { place(panel) }
    }

    /// Left aligned under the status item and just below the menu bar, kept inside the screen, and
    /// never taller than most of it: the content scrolls once the clamp is reached.
    private func place(_ panel: NSPanel) {
        guard let button, let window = button.window, let screen = window.screen ?? NSScreen.main else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let top = buttonRect.minY - Self.gapBelowMenuBar
        let width = UsagePanelView.width
        let x = min(max(buttonRect.minX, visible.minX + Self.screenMargin), visible.maxX - width - Self.screenMargin)
        let maximum = max(1, min(top - visible.minY - Self.screenMargin, (visible.height * 0.85).rounded(.down)))
        let height = min(max(idealHeight, Self.minimumHeight), maximum)
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
        panel.invalidateShadow()
    }

    // MARK: - Dismissal and keys

    private func startMonitors() {
        stopMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocalClick(event) }
            return event
        }) {
            monitors.append(local)
        }
        // A click in another app never reaches a local monitor, and is the commonest way out.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) {
            monitors.append(global)
        }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                self?.handleKey(code: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers) ?? false
            }
            return consumed ? nil : event
        }) {
            monitors.append(keys)
        }
    }

    private func stopMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handleLocalClick(_ event: NSEvent) {
        guard let panel, panel.isVisible else { return }
        let window = event.window
        if window === panel || window?.sheetParent === panel || panel.attachedSheet != nil { return }
        // The status item's own click toggles the panel; closing it here first would reopen it.
        if let buttonWindow = button?.window, window === buttonWindow { return }
        // A context menu or a picker's menu opened from inside the panel is its own window.
        if let name = window.map({ NSStringFromClass(type(of: $0)).lowercased() }),
           name.contains("menu") || name.contains("popover") {
            return
        }
        hide()
    }

    private func handleKey(code: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Bool {
        guard let panel, panel.isKeyWindow else { return false }
        let modifiers = flags.intersection([.command, .option, .control, .shift])
        switch (code, modifiers) {
        case (53, []):
            if !model.back() { hide() }
            return true
        case (36, []), (76, []):
            if model.customizing != nil {
                model.navigate(to: .customize, forward: false)
            } else if model.screen == .dashboard {
                model.navigate(to: .customize)
            } else {
                model.navigate(to: .dashboard, forward: false)
            }
            return true
        default:
            break
        }
        guard modifiers == .command else { return false }
        switch characters {
        case ",":
            if model.screen == .settings { model.back() } else { model.navigate(to: .settings) }
            return true
        case "r":
            model.refresh()
            return true
        case "q":
            NSApp.terminate(nil)
            return true
        default:
            return false
        }
    }
}
