import SwiftUI
import AppKit

/// What a control in the inspector can hand to the system's sharing menu.
///
/// Two cases, because there are two kinds of thing here worth sending someone: the pull request,
/// which is a link the receiver opens, and a diff, which is text the receiver reads where it
/// lands. They are kept apart rather than both flattened to a string, because a service offers a
/// very different set of things to do with a URL than with a paragraph.
enum SharePayload: Equatable {
    case link(URL)
    case text(String)

    /// AppKit wants the bridged reference types, and the sharing services read the class to decide
    /// what they can do with what they are given.
    var items: [Any] {
        switch self {
        case .link(let url): [url as NSURL]
        case .text(let text): [text as NSString]
        }
    }
}

/// Presents `NSSharingServicePicker` under the control that asked for it.
///
/// The picker needs a view and a rectangle to hang its menu off, which no SwiftUI control can hand
/// out. So the anchor is an empty `NSView` sitting behind the control, and the control only has to
/// set a payload: whatever the anchor is behind is what the menu appears under.
///
/// Nil means there is nothing to share. It is cleared again as soon as the picker has been asked
/// for, so pressing the same button twice presents twice.
private struct SharePickerAnchor: NSViewRepresentable {
    @Binding var payload: SharePayload?

    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        guard let payload, !view.isPresenting else { return }
        view.isPresenting = true

        // Deferred out of the update pass on purpose. `show` spins a menu tracking loop, and
        // starting one while SwiftUI is still laying the window out deadlocks it. The hop is also
        // what lets the menu the button lives in finish dismissing first.
        Task { @MainActor in
            self.payload = nil
            view.isPresenting = false
            guard view.window != nil else { return }
            NSSharingServicePicker(items: payload.items)
                .show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        }
    }
}

/// Invisible to the mouse: it is the background of a control, and an `NSView` added to a hosting
/// view's hierarchy hit-tests ahead of whatever SwiftUI draws itself.
final class AnchorView: NSView {
    /// Guards against a second update arriving before the deferred present has run, which would
    /// open two menus for one press.
    var isPresenting = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    /// Hangs the system sharing menu off this view. Setting `payload` presents it.
    func sharePicker(payload: Binding<SharePayload?>) -> some View {
        background(SharePickerAnchor(payload: payload))
    }
}
