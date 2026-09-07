import AppKit
import SwiftUI

/// A real ancestor of the glass, editor, and footer. SwiftUI's dropDestination installs a
/// sibling behind them, so a file dropped on a native descendant can miss that destination.
struct ComposerDropContainer<Content: View>: NSViewControllerRepresentable {
    @Binding var isTargeted: Bool
    var onReceive: @MainActor @Sendable ([AttachmentSource]) -> Bool
    var onFailure: @MainActor @Sendable (String) -> Void
    var content: Content

    func makeNSViewController(context: Context) -> ComposerDropController {
        let controller = ComposerDropController()
        updateNSViewController(controller, context: context)
        return controller
    }

    func updateNSViewController(_ controller: ComposerDropController, context: Context) {
        controller.host.rootView = AnyView(content.environment(\.self, context.environment))
        controller.surface.onReceive = onReceive
        controller.surface.onFailure = onFailure
        controller.surface.onTarget = { isTargeted = $0 }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController controller: ComposerDropController,
        context: Context
    ) -> CGSize? {
        controller.host.sizeThatFits(in: CGSize(
            width: proposal.width ?? 400, height: .greatestFiniteMagnitude
        ))
    }
}

final class ComposerDropController: NSViewController {
    let host = NSHostingController(rootView: AnyView(EmptyView()))
    let surface = ComposerDropSurface()

    override func loadView() {
        view = surface
        host.sizingOptions = []
        addChild(host)
        let hosted = host.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: surface.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
    }
}

final class ComposerDropSurface: NSView {
    var onReceive: @MainActor @Sendable ([AttachmentSource]) -> Bool = { _ in false }
    var onFailure: @MainActor @Sendable (String) -> Void = { _ in }
    var onTarget: @MainActor (Bool) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(AttachmentDrop.types)
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = AttachmentDrop.canRead(sender.draggingPasteboard)
        onTarget(accepts)
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        AttachmentDrop.canRead(sender.draggingPasteboard) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        AttachmentDrop.canRead(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { onTarget(false) }
        return AttachmentDrop.receive(
            sender.draggingPasteboard, onReceive: onReceive, onFailure: onFailure
        )
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { onTarget(false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { onTarget(false) }
}

extension View {
    func composerDropDestination(
        isTargeted: Binding<Bool>,
        onReceive: @escaping @MainActor @Sendable ([AttachmentSource]) -> Bool,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) -> some View {
        ComposerDropContainer(
            isTargeted: isTargeted, onReceive: onReceive, onFailure: onFailure, content: self
        )
    }
}
