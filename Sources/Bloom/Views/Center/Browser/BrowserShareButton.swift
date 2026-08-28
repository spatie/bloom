import SwiftUI
import AppKit
import BloomCore

/// The browser toolbar's Share control, which opens the system's own sheet.
///
/// **`NSSharingServicePicker` rather than a menu of ours.** It is the sheet Safari, Finder, Mail
/// and Notes all put behind this glyph: AirDrop, Messages, Mail, Notes, Reminders, Add to Reading
/// List and whatever else the user has turned on in System Settings, in their order, with their
/// icons, kept up to date by the system and never by us. A hand built menu would be a list of the
/// four services we happened to think of, wrong on the day somebody installs a fifth, and it would
/// have to carry out each handoff itself besides.
///
/// **Shown from the control's own rectangle**, so the sheet points at the button that opened it
/// rather than at the middle of the window. That needs an `NSView` sitting where the button is,
/// which SwiftUI does not hand out, so an empty one is parked behind the button and the picker is
/// shown relative to that. What is shared, and why the page's title travels on the URL rather than
/// beside it, is `BrowserToolbar.shareable`.
struct BrowserShareButton: View {
    var control: BrowserToolbar.Control
    var shareable: BrowserToolbar.Shareable?

    @State private var anchor = SharePickerAnchor()

    var body: some View {
        BrowserToolbarRoundButton(control: control) { anchor.present(shareable) }
            .background(SharePickerAnchorView(anchor: anchor))
    }
}

/// The rectangle the sheet points at, and the picker it points with.
///
/// Presented from the button's action rather than from the representable's update, because
/// `updateNSView` runs inside SwiftUI's own layout pass: a sheet put up from in there is anchored
/// to a view whose frame is still being decided, and it lands where the button was rather than
/// where it is.
@MainActor
final class SharePickerAnchor {
    /// Weak, because the view is owned by the hierarchy SwiftUI made for the representable, and
    /// this outlives one of those every time the toolbar is rebuilt.
    fileprivate weak var view: NSView?

    /// Somewhere to keep the picker while its sheet is up.
    ///
    /// `show(relativeTo:of:preferredEdge:)` returns immediately and the sheet outlives the call,
    /// so a picker made as a local in the button's action is one released while the reader is
    /// still looking at it.
    private var picker: NSSharingServicePicker?

    /// Nothing happens for a pane that has not been anywhere, which is also when the button is
    /// disabled, and nothing happens for a view not yet in a window, which is a capture page.
    func present(_ shareable: BrowserToolbar.Shareable?) {
        guard let shareable, let view, view.window != nil else { return }

        // One item, not two. See `BrowserToolbar.shareable`: the picker offers only the services
        // that can take every item it is handed, so a title passed as a second item would cost the
        // sheet every service that accepts a URL and nothing else, Add to Reading List included.
        let item = NSPreviewRepresentingActivityItem(
            item: shareable.url, title: shareable.name, image: nil, icon: nil
        )
        let picker = NSSharingServicePicker(items: [item])
        self.picker = picker
        // Below the control, which is where a sheet hung off a toolbar button drops on this
        // platform. The anchor is the button's own background, so its bounds are the button's.
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

/// An empty AppKit view whose only job is to have a frame the picker can be aimed at.
private struct SharePickerAnchorView: NSViewRepresentable {
    let anchor: SharePickerAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    /// Set again on every update, because SwiftUI is free to hand the representable a new backing
    /// view, and a stale one has no window and would silently swallow the press.
    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
