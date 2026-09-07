import AppKit
import SwiftUI

/// Keeps the unified title bar on its native material and adds the workspace's own strip.
/// The sidebar also uses its system background, so navigation chrome follows appearance,
/// inactive-window state and accessibility preferences together. Reading surfaces stay opaque;
/// no material layers are added to scrolling content.
///
/// The trailing end of the same strip is `TitleBarStrip`, added as a title bar accessory. See
/// that file for why an accessory rather than content drawn under a transparent title bar.
struct WindowChrome: ViewModifier {
    /// Handed in rather than read from the environment. This modifier is applied OUTSIDE the
    /// `.environment(model)` that wraps the window's content, so it is an ancestor of the value
    /// rather than a descendant of it, and reading it there is a crash rather than a nil. Its
    /// neighbours in `BloomApp` take the model the same way for the same reason.
    let app: AppModel

    @State private var window: NSWindow?
    @State private var strip: TitleBarStripController?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor(window: $window))
            .onChange(of: window, initial: true) { _, _ in apply() }
    }

    private func apply() {
        guard let window else { return }
        window.titlebarAppearsTransparent = false
        window.backgroundColor = .windowBackgroundColor
        // AppKit's own title text, off. `WindowTitleControl` draws it as a toolbar item instead,
        // so that a double click on the NAME can start a rename without taking the double click on
        // the BAR that Desktop & Dock has already spent on Zoom or Minimise.
        //
        // **This is only half of it, and the half that shipped alone drew the name twice.** A
        // window can carry two titles by two different routes: the one AppKit draws, which this
        // governs, and a title item SwiftUI contributes to the toolbar from `navigationTitle`,
        // which it owns and re-resolves and which nothing set on the window from the side can
        // touch. That second one is `RootView`'s `.toolbar(removing: .title)`. Neither line makes
        // the other redundant.
        //
        // Here rather than in `WindowTitle`, which owns the title's words, because `addStrip`
        // below measures the title bar and the measurement has to be taken with this already
        // applied. Two sibling modifiers attach to the window in no defined order, so the
        // measurement and the setting belong in one place.
        window.titleVisibility = .hidden
        addStrip(to: window)
    }

    private func addStrip(to window: NSWindow) {
        // The window is checked as well as our own state. A `@State` that comes back empty because
        // the scene was rebuilt would otherwise put a second strip in the same title bar.
        guard strip == nil,
              !window.titlebarAccessoryViewControllers.contains(where: { $0 is TitleBarStripController })
        else { return }
        // Measured before the accessory is added, because `contentLayoutRect` is what the title
        // bar leaves over and an accessory of our own would then be measuring itself.
        let height = window.frame.height - window.contentLayoutRect.height
        guard height > 0 else { return }

        // The search panel hangs its card below the title bar and needs this same number, and
        // this is the one place in the app that measures it correctly: asked again once the strip
        // is in, `contentLayoutRect` answers 152 for a 52 point bar, because an accessory is part
        // of what the title bar leaves over. See `SearchPanelWindowGeometry.titleBarHeight`.
        SearchPanelWindowGeometry.shared.setTitleBarHeight(height)

        let controller = TitleBarStripController(app: app, height: height)
        window.addTitlebarAccessoryViewController(controller)
        strip = controller
    }
}

extension View {
    func paintsTitleBar(_ app: AppModel) -> some View {
        modifier(WindowChrome(app: app))
    }
}
