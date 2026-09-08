import SwiftUI
import AppKit
import QuickLookUI
import BloomCore

/// The keyboard a list has, for the lists in this window that are not a `List`.
///
/// Three of them are a `ScrollView` over a `LazyVStack` of buttons: the changed files, the
/// worktree tree and the search results. They stay that way on purpose (a real `List` brings the
/// platform's behaviour and its drawing, and the drawing is the part these three would lose), so
/// the behaviour is brought to them instead: arrows, Home and End, type-select, Return, and the
/// space bar preview that only a mouse could reach before.
///
/// **An `NSView` rather than `focusable()` and `onKeyPress`, and it is not a preference.** This
/// started as the Quick Look host and its reasoning already applies to the whole keyboard.
/// `QLPreviewPanel` is driven from the responder chain: it walks up from the first responder
/// looking for something that accepts control of it, and hands that object the panel's data
/// source. A SwiftUI `focusable()` container that took the window's focus would take it from this
/// view, and this view is what the panel can find. One first responder answers both, which is also
/// the honest description of what focus means: the arrow keys move this list because this list is
/// what the keyboard is pointed at.
///
/// Placed as a background of the list, so the rows above it keep every click. It takes the
/// keyboard when a row is activated and loses it the moment the reader clicks into the composer or
/// a terminal, which is exactly when its keys should stop being its own.
struct ListKeyboardHost: NSViewRepresentable {
    /// The file the space bar would preview. Nil disarms it without tearing the host down, which
    /// is also what a list with nothing to preview passes: the search results have no file behind
    /// a row, so their space bar stays a space.
    var url: URL?
    /// Bumped by the list every time a row is activated, which is what moves the keyboard back
    /// here after the reader has been somewhere else. Selection alone is not enough: clicking the
    /// already selected row is a legitimate way to ask for it again.
    var armToken: Int
    /// What the list does with a key. False hands it back to the responder chain.
    var onKey: (ListKey) -> Bool
    /// Whether this list holds the keyboard, and how it came by it. The first decides between the
    /// emphasised selection fill and the quiet one (see `RowBackground`), the second decides the
    /// ring. The rule over the pair is `ListFocus`, in the core.
    var onFocusChange: (ListFocus) -> Void

    func makeNSView(context: Context) -> ListKeyboardHostView {
        ListKeyboardHostView()
    }

    func updateNSView(_ view: ListKeyboardHostView, context: Context) {
        view.onKey = onKey
        view.onFocusChange = onFocusChange
        view.update(url: url, armToken: armToken)
    }
}

final class ListKeyboardHostView: NSView, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    var onKey: (ListKey) -> Bool = { _ in false }
    var onFocusChange: (ListFocus) -> Void = { _ in }

    private var url: URL?
    private var armToken = 0
    /// How this view came by the keyboard, while it has it. See `ListFocusOrigin`.
    private var origin: ListFocusOrigin = .unknown

    override var acceptsFirstResponder: Bool { true }

    /// Invisible to the mouse. It is a background of the list, so every point in it is over a row,
    /// and an `NSView` added to a hosting view's hierarchy hit-tests ahead of what SwiftUI draws
    /// itself. Being first responder does not go through hit testing, so nothing here needs it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(url: URL?, armToken: Int) {
        let changed = self.url != url
        self.url = url

        if armToken != self.armToken {
            self.armToken = armToken
            window?.makeFirstResponder(self)
        }

        // A panel left open while the reader walks the list follows the selection rather than
        // going stale, which is what Finder does with the arrow keys.
        guard changed, isPanelOpen else { return }
        QLPreviewPanel.shared()?.reloadData()
    }

    // MARK: - Focus

    /// Reported one turn later, never inline. `update(url:armToken:)` runs inside a SwiftUI pass
    /// and takes the responder from there, so telling the list about it synchronously would be
    /// writing state in the middle of the update that caused it.
    private func report(focus: Bool) {
        let value = ListFocus(
            hasKeyboard: focus,
            origin: focus ? origin : .unknown,
            // Read here rather than once at launch: turning Full Keyboard Access on is a thing
            // somebody does in System Settings while an app is open, and the next focus change is
            // soon enough to notice it.
            fullKeyboardAccess: NSApp.isFullKeyboardAccessEnabled
        )
        Task { @MainActor in onFocusChange(value) }
    }

    /// Which device asked for the focus, taken from the event AppKit is dispatching.
    ///
    /// `NSApp.currentEvent` is the last event pulled off the queue, which is still the click when
    /// `update(url:armToken:)` makes this view first responder a turn after a row was activated,
    /// and still the key press when the key view loop moves focus here on Tab. Anything else, and
    /// there is no pointer involved, so the ring is drawn: only a mouse silences it.
    private static func origin(of event: NSEvent?) -> ListFocusOrigin {
        guard let event else { return .unknown }
        switch event.type {
        // The tracking events are in the list on purpose. A click that takes the focus a turn
        // later can have a `mouseMoved` or a `mouseEntered` behind it by the time the SwiftUI pass
        // runs, and a pointer that has merely moved is still a pointer doing the work.
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
             .otherMouseDragged, .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate,
             .scrollWheel:
            return .mouse
        case .keyDown, .keyUp, .flagsChanged:
            return .keyboard
        default:
            return .unknown
        }
    }

    override func becomeFirstResponder() -> Bool {
        origin = Self.origin(of: NSApp.currentEvent)
        report(focus: true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        origin = .unknown
        report(focus: false)
        return super.resignFirstResponder()
    }

    /// A window that stops being key has no keyboard to point anywhere, and a ring left drawn on a
    /// background window is the tell `RowBackground` exists to avoid on the fill.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            origin = .unknown
            report(focus: false)
        }
    }

    /// A reader who clicked a row and then reached for the arrow keys IS a keyboard user, and from
    /// that key on the ring is what says which list the keys are pointed at. So a click starts
    /// silent and the first key this list answers promotes it, which is the whole of the rule: the
    /// ring appears for the reader who needs it and never for the one who does not.
    private func promoteToKeyboard() {
        guard origin == .mouse else { return }
        origin = .keyboard
        report(focus: true)
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        if isSpace(event) {
            promoteToKeyboard()
            toggle()
            return
        }

        if let key = Self.key(for: event), onKey(key) {
            promoteToKeyboard()
            return
        }
        super.keyDown(with: event)
    }

    /// The one place an `NSEvent` is read, and it decides nothing: what each of these means is
    /// `ListKeyboard`, in the core, where the suite can reach it.
    ///
    /// Home and End are `fn` and an arrow on the keyboards this app runs on, and AppKit reports
    /// them as the function keys below rather than as a modified arrow, so nothing extra is needed
    /// to catch them.
    ///
    /// **`.function` and `.numericPad` are subtracted before asking whether a modifier was held**,
    /// and leaving them in is the bug this catches: AppKit sets both on every arrow key, so a
    /// plain Down arrow arrives carrying two modifier flags and a test for "no modifiers" rejects
    /// the one key a list most has to answer. Command, Option, Control and Shift are what the
    /// question is actually about, and they survive the subtraction.
    static func key(for event: NSEvent) -> ListKey? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        guard modifiers.isEmpty else { return nil }

        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return nil
        }

        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return .up
        case NSDownArrowFunctionKey: return .down
        case NSLeftArrowFunctionKey: return .left
        case NSRightArrowFunctionKey: return .right
        case NSHomeFunctionKey: return .home
        case NSEndFunctionKey: return .end
        // Return and the numeric keypad's Enter, which every Mac list treats alike.
        case 0x0D, 0x03: return .activate
        default: break
        }

        // A function key with no meaning here would otherwise arrive as a character in the private
        // use area and start a type-select nobody can see.
        guard let character = event.characters?.first,
              !event.modifierFlags.contains(.function) else { return nil }
        return .character(character)
    }

    /// Bare space only. Every combination with a modifier belongs to somebody else, from the
    /// system's own Command-Space down.
    private func isSpace(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        return modifiers.isEmpty && event.charactersIgnoringModifiers == " "
    }

    private var isPanelOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    /// Space closes an open panel as well as opening one, which is the whole of the Finder
    /// gesture. With nothing previewable selected it does nothing rather than beeping: the reader
    /// pressed a key at a deleted file, and a beep tells them off for it.
    private func toggle() {
        guard let panel = QLPreviewPanel.shared() else { return }

        if isPanelOpen {
            panel.orderOut(nil)
            return
        }

        guard url != nil else { return }
        window?.makeFirstResponder(self)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Panel control

    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    // MARK: - Contents

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }

    /// The panel forwards keys it does not use itself, and two are worth taking back. The space
    /// bar, because without it the panel closes only on Escape and the gesture would not be
    /// symmetric; and the arrows, so the reader can keep walking the list with the preview open,
    /// which is the whole of what Finder's Quick Look does.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }

        if isSpace(event) {
            panel.orderOut(nil)
            return true
        }

        guard let key = Self.key(for: event), key == .up || key == .down else { return false }
        return onKey(key)
    }
}

// MARK: - The front door

extension View {
    /// Gives a list a keyboard, and the ring that says it has one.
    ///
    /// One modifier rather than two, because the ring is not decoration: it is the only thing on
    /// screen that says which of the window's lists the arrow keys are pointed at, and a list that
    /// took the keys without drawing it would be the same silent pile of buttons with more
    /// behaviour behind it. Attaching them together is what stops the second one being forgotten
    /// at the third call site.
    func listKeyboard(
        hasKeyboard: Binding<Bool>,
        previewing url: URL? = nil,
        armToken: Int,
        onKey: @escaping (ListKey) -> Bool
    ) -> some View {
        modifier(
            ListKeyboardModifier(
                hasKeyboard: hasKeyboard,
                url: url,
                armToken: armToken,
                onKey: onKey
            )
        )
    }
}

/// The host and the ring, and the state between them.
///
/// A modifier rather than two calls in the extension above, because the ring needs the whole of
/// `ListFocus` and the three lists only ever wanted the boolean half of it. `hasKeyboard` still
/// goes out to the caller and still decides the selection fill; the origin stays here, where the
/// only thing that reads it is the ring.
private struct ListKeyboardModifier: ViewModifier {
    @Binding var hasKeyboard: Bool
    var url: URL?
    var armToken: Int
    var onKey: (ListKey) -> Bool

    @State private var focus = ListFocus()

    func body(content: Content) -> some View {
        content
            .background(
                ListKeyboardHost(
                    url: url,
                    armToken: armToken,
                    onKey: onKey,
                    onFocusChange: { report($0) }
                )
            )
            .modifier(ListFocusRing(isVisible: focus.showsRing))
    }

    /// Writing an unchanged value is still a write as far as SwiftUI is concerned, and the host
    /// reports on every promotion as well as on every focus change.
    private func report(_ next: ListFocus) {
        if focus != next { focus = next }
        if hasKeyboard != next.hasKeyboard { hasKeyboard = next.hasKeyboard }
    }
}

/// The ring around the list the keyboard is pointed at, when the reader is using the keyboard.
///
/// `keyboardFocusIndicatorColor` at two points, drawn only in the key window, which is the
/// convention the five hand-built text fields in this app already follow (see `HomeBar`). Written
/// once here rather than a sixth time: these three lists are the first things in the window that
/// can hold the keyboard without being a field, and the answer to "which one has it" has to look
/// the same wherever it is asked.
///
/// **Not drawn for a click**, which is the whole of a reported complaint: selecting a file in the
/// inspector put a two point blue rectangle around the pane and told the reader nothing the
/// emphasised row was not already telling them. `ListFocus` holds that rule and the reasoning for
/// it; an `NSTableView` behaves the same way and for the same reason.
///
/// Inset by half the line width so the ring lands inside the pane rather than half outside it,
/// where the split view's own edge would clip it.
private struct ListFocusRing: ViewModifier {
    var isVisible: Bool

    @Environment(\.controlActiveState) private var activeState

    private static let width: CGFloat = 2

    func body(content: Content) -> some View {
        content
            .overlay {
                if isVisible, activeState != .inactive {
                    RoundedRectangle(cornerRadius: Metrics.corner)
                        .strokeBorder(Palette.focusRing, lineWidth: Self.width)
                        .padding(Self.width / 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}
