import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Takes a file dragged over a part of the window that has no drop target of its own and hands it
/// to the composer `TypeToComposer.dropTarget` names, lighting that box up while the drag is over.
///
/// A pane container holds one rather than registering as a destination of its own kind, because
/// AppKit offers a drag to the deepest registered view and a container is an ancestor of everything
/// in its pane: a web page or a terminal keeps its own drop, a composer keeps its own, and the
/// rest falls through to here. The target is worked out again on every move, which reads state and
/// writes none: the highlight is written only when the target changes, so a drag across the window
/// costs two writes, and a third each time it crosses the edge of a side conversation's card.
@MainActor
final class WindowFileDrop {
    private var session = AttachmentDropSession()
    private weak var targeted: ComposerEditorHandle?
    private var canRead = false

    /// Whether anything is lit up, which is whether the drop would be taken.
    var hasTarget: Bool { targeted != nil }

    /// `point` is where the drag is in window coordinates, or nil where there is no card to be
    /// over.
    func entered(_ pasteboard: NSPasteboard, in window: NSWindow?, at point: CGPoint?) -> NSDragOperation {
        canRead = AttachmentDrop.canRead(pasteboard)
        return updated(in: window, at: point)
    }

    /// Asked again on every move, because the target depends on where the pointer is: crossing the
    /// edge of the card moves the highlight from one composer to the other. The pasteboard does not
    /// change during a drag, so it is read once, on entry.
    func updated(in window: NSWindow?, at point: CGPoint?) -> NSDragOperation {
        guard canRead, let window, let target = TypeToComposer.dropTarget(in: window, at: point) else {
            exited()
            return []
        }
        if targeted !== target {
            exited()
            targeted = target
            target.dropHint.set(.window, true)
        }
        return .copy
    }

    func exited() {
        targeted?.dropHint.set(.window, false)
        targeted = nil
    }

    /// Asks again rather than using what the drag entered on: the drop goes where the rule says it
    /// goes now, and a SwiftUI `onDrop` can deliver it before its own enter has been seen.
    func perform(_ pasteboard: NSPasteboard, in window: NSWindow?, at point: CGPoint?) -> Bool {
        defer { exited() }
        guard let window, let endpoint = TypeToComposer.dropTarget(in: window, at: point)?.dropEndpoint else {
            return false
        }
        return AttachmentDrop.receive(
            pasteboard, session: session, onReceive: endpoint.attach, onFailure: endpoint.fail
        )
    }

    func windowChanged(to window: NSWindow?) {
        if window == nil { session.cancelAll() }
        if window != nil, !session.isActive { session = AttachmentDropSession() }
    }
}

extension View {
    /// For the sidebar and the create sheet, which are SwiftUI all the way down and have no
    /// container of ours to hold a `WindowFileDrop`. The pane containers do the same for the centre
    /// column and the inspector.
    func routesFileDropsToComposer() -> some View { modifier(RoutedFileDrop()) }
}

private struct RoutedFileDrop: ViewModifier {
    @State private var isTargeted = false
    @State private var relay = WindowFileDrop()

    private static let types = AttachmentDrop.types.compactMap { UTType($0.rawValue) }

    /// The window this view is in, rather than the key one: a drag from Finder arrives while Bloom
    /// is not the active application, and then nothing is key. It is also what tells a sidebar
    /// from a sheet.
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background { WindowAccessor(window: $window) }
            .onDrop(of: Self.types, isTargeted: $isTargeted) { _ in
                relay.perform(NSPasteboard(name: .drag), in: window, at: nil)
            }
            .onChange(of: isTargeted) { _, isOver in
                if isOver {
                    _ = relay.entered(NSPasteboard(name: .drag), in: window, at: nil)
                } else {
                    relay.exited()
                }
            }
    }
}
