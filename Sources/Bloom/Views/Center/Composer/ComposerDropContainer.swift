import AppKit
import SwiftUI
import BloomCore

/// A real ancestor of the glass, editor, and footer. SwiftUI's dropDestination installs a
/// sibling behind them, so a file dropped on a native descendant can miss that destination.
struct ComposerDropContainer<Content: View>: NSViewControllerRepresentable {
    @Binding var isTargeted: Bool
    var onReceive: @MainActor @Sendable ([AttachmentSource]) -> Bool
    var onFailure: @MainActor @Sendable (String) -> Void
    var content: Content

    func makeNSViewController(context: Context) -> ComposerDropController<Content> {
        let controller = ComposerDropController(
            root: ComposerDropRootModel(content: content, environment: context.environment)
        )
        updateNSViewController(controller, context: context)
        return controller
    }

    func updateNSViewController(_ controller: ComposerDropController<Content>, context: Context) {
        controller.root.content = content
        controller.root.environment = context.environment
        controller.surface.onReceive = onReceive
        controller.surface.onFailure = onFailure
        controller.surface.onTarget = { isTargeted = $0 }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController controller: ComposerDropController<Content>,
        context: Context
    ) -> CGSize? {
        controller.host.sizeThatFits(in: CGSize(
            width: proposal.width ?? 400, height: .greatestFiniteMagnitude
        ))
    }
}

/// What the embedded hosting view draws, handed over by observation rather than by a new root.
///
/// **The root used to be a fresh `AnyView` on every update of the composer around it**, written
/// into `host.rootView` from inside that composer's own graph update, which runs on every
/// keystroke and on every change a running turn makes to the footer. Five crash reports from
/// 1.40.0 to 1.41.1 abort in AttributeGraph inside this view's render: `input_value_ref_slow`
/// under `NSHostingView.layout()`, from the window's display cycle, two of them in
/// `AnyResetSeed`. The depth of that frame matches this view and no other hosting view whose
/// root is an `AnyView` (17 levels of `_layoutSubtreeWithOldSize:` in the reports, and in
/// `HostDepthProbe`), and three of the five came within two seconds of a message being sent.
///
/// **It was not reproduced**, so this is the likeliest cause rather than a proven one:
/// `ComposerHostProbe` replays drafts, sends and workspace switches and has not aborted on either
/// side of this change. If the abort comes back with this view at the same depth, the cause is
/// somewhere else and this note is wrong.
///
/// So the root is now one concrete type that is set once, with no `AnyView` above the content,
/// and the content and environment reach it as observed values, the way `TranscriptCellRoot`
/// gives a transcript cell one root type for the same reason.
@MainActor
@Observable
final class ComposerDropRootModel<Content: View> {
    var content: Content
    var environment: EnvironmentValues

    init(content: Content, environment: EnvironmentValues) {
        self.content = content
        self.environment = environment
    }
}

struct ComposerDropRoot<Content: View>: View {
    let model: ComposerDropRootModel<Content>

    var body: some View {
        model.content.environment(\.self, model.environment)
    }
}

final class ComposerDropController<Content: View>: NSViewController {
    let root: ComposerDropRootModel<Content>
    let host: NSHostingController<ComposerDropRoot<Content>>
    let surface = ComposerDropSurface()

    init(root: ComposerDropRootModel<Content>) {
        self.root = root
        host = NSHostingController(rootView: ComposerDropRoot(model: root))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not decoded from a nib") }

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
    private var attachmentDropSession = AttachmentDropSession()
    private lazy var sheetSuspension = SheetDropSuspension(self)
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
            sender, session: attachmentDropSession, onReceive: onReceive, onFailure: onFailure
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sheetSuspension.windowChanged(to: window)
        if window == nil { attachmentDropSession.cancelAll() }
        if window != nil, !attachmentDropSession.isActive {
            attachmentDropSession = AttachmentDropSession()
        }
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
