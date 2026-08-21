import AppKit
import SwiftUI

/// Takes the rule out from under the tab bar of both settings windows.
///
/// The line looked like the window's title bar separator and was not. Traced through the layer
/// tree it is a half point `CALayer` named `Separator`, black at ten per cent, which is a flat 229
/// grey on white, carried by an `NSScrollPocket` inside `SwiftUI.HostingScrollView`. The pocket is
/// macOS 26's scroll edge effect: an 88 point band AppKit lays over the top of a scroll view that
/// runs under a bar, measured at exactly 640 by 88 in a 640 point window, and 88 points is where a
/// preference style title bar ends. So the rule belongs to the form, not to the window.
///
/// That matters because it rules out the obvious fix. `NSWindow.titlebarSeparatorStyle = .none`
/// does nothing here, measured: the property reads back as `.none` while the rule is still on
/// screen, because the window never drew it. Neither does SwiftUI's own
/// `scrollEdgeEffectStyle(.soft, for: .top)` nor `scrollEdgeEffectHidden(true, for: .top)` on the
/// form. Both compile against the macOS 26 SDK and both leave the pocket exactly as it was,
/// measured on captures at two window sizes. So the pocket is reached the only way that works.
///
/// Hiding it rather than softening it. An AppKit reference window built the way Apple's own
/// preferences windows are, an `NSTabViewController` in `.toolbar` style inside a window with
/// `toolbarStyle = .preference`, draws no rule at rest and a half point of the same 229 grey at
/// the same 88 points once its content is scrolled off the top. Ours drew it at rest too, and a
/// rule saying "there is more above" when there is nothing above is the whole complaint. What is
/// given up is the rule in the case it was meant for, and the title bar behind it is opaque, so
/// content still has something to disappear behind.
///
/// It fails safe. The pocket is found by class name, because AppKit exposes no property for it,
/// and a rename in a later macOS means the rule comes back rather than anything breaking. Written
/// as a representable rather than as a one shot on window attach so that it re-runs on every
/// layout pass: switching tabs builds a new pocket, and a fix that ran once left the rule back on
/// screen on the second tab.
struct SettingsScrollPocket: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let root = nsView.window?.contentView else { return }
        Self.hidePockets(in: root)
    }

    /// Every pocket under this view, hidden. Plural because a `TabView` keeps the pane it came
    /// from alive, so a window that has been on two tabs has two scroll views and two pockets.
    static func hidePockets(in view: NSView) {
        if "\(type(of: view))".contains("Pocket") { view.isHidden = true }
        for subview in view.subviews { hidePockets(in: subview) }
    }
}

extension View {
    /// Hides the scroll edge rule under a settings window's tab bar. See `SettingsScrollPocket`.
    func hidesScrollEdgeRule() -> some View {
        background(SettingsScrollPocket())
    }
}
