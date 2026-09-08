import AppKit
import BloomCore
import SwiftUI

/// A tab's actions stay with its workspace; AppKit owns the control and its interaction state.
struct NativeStripTab: Identifiable {
    var id: PaneContent
    var title: String
    var editableTitle: String
    var icon: TabItemIcon
    var isRunning = false
    var canRename = true
    var closeTitle: String
    var select: () -> Void
    var close: () -> Void
    var rename: (String) -> Void
    var splitRight: (() -> Void)?
    var splitDown: (() -> Void)?
}

struct NativeTabStrip: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tabs: [NativeStripTab]
    var selectedID: PaneContent?
    @Binding var renamingID: PaneContent?
    var onMeasure: ([PaneContent: Double]) -> Void
    var onDragBegin: (String) -> Void
    var onDragMove: (Double) -> Void
    var onDrop: (String, Double) -> Void
    var onDragEnd: (Bool) -> Void

    func makeNSView(context: Context) -> NativeTabStripView { NativeTabStripView() }

    func updateNSView(_ view: NativeTabStripView, context: Context) {
        view.onMeasure = onMeasure
        view.onDragBegin = onDragBegin
        view.onDragMove = onDragMove
        view.onDrop = onDrop
        view.onDragEnd = onDragEnd
        view.onRenamingChange = { renamingID = $0 }
        view.reduceMotion = reduceMotion
        view.update(tabs: tabs, selectedID: selectedID, renamingID: renamingID)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeTabStripView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: Metrics.barHeight)
    }
}

final class NativeTabStripView: NSView, NSTextFieldDelegate {
    let control = NativeTabControl()
    let scroll = NSScrollView()
    let document = NSView()
    private let previous = NSButton()
    private let next = NSButton()
    private let closeButton = NSButton()
    private var indicators: [PaneContent: NSProgressIndicator] = [:]
    private var editor: NSTextField?
    private var editingID: PaneContent?
    private var hoveredID: PaneContent?
    private var selectedID: PaneContent?
    private var needsReveal = false
    private var lastWidth: CGFloat = 0
    private(set) var tabs: [NativeStripTab] = []
    var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            for indicator in indicators.values {
                if reduceMotion { indicator.stopAnimation(nil) } else { indicator.startAnimation(nil) }
            }
        }
    }

    var onMeasure: ([PaneContent: Double]) -> Void = { _ in }
    var onDragBegin: (String) -> Void = { _ in }
    var onDragMove: (Double) -> Void = { _ in }
    var onDrop: (String, Double) -> Void = { _, _ in }
    var onDragEnd: (Bool) -> Void = { _ in }
    var onRenamingChange: (PaneContent?) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        document.addSubview(control)
        addSubview(scroll)
        control.owner = self
        control.controlSize = .regular
        control.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        control.segmentStyle = .automatic
        control.borderShape = .capsule
        control.segmentDistribution = .fillEqually
        control.trackingMode = .selectOne
        control.target = self
        control.action = #selector(selectSegment)
        control.registerForDraggedTypes([.string])
        configure(previous, symbol: "chevron.left", label: "Show earlier tabs", action: #selector(scrollPrevious))
        configure(next, symbol: "chevron.right", label: "Show later tabs", action: #selector(scrollNext))
        addSubview(previous)
        addSubview(next)
        configure(closeButton, symbol: "xmark", label: "Close tab", action: #selector(closeHovered))
        document.addSubview(closeButton)
        closeButton.isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.target = self
        button.action = action
    }

    func update(tabs: [NativeStripTab], selectedID: PaneContent?, renamingID: PaneContent?) {
        needsReveal = needsReveal || self.selectedID != selectedID
        self.tabs = tabs
        self.selectedID = selectedID
        if control.segmentCount != tabs.count { control.segmentCount = tabs.count }
        control.selectedSegment = tabs.firstIndex { $0.id == selectedID } ?? -1
        for id in Array(indicators.keys) where !tabs.contains(where: { $0.id == id }) {
            indicators.removeValue(forKey: id)?.removeFromSuperview()
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        let validRename = tabs.contains(where: { $0.id == renamingID }) ? renamingID : nil
        if editingID != validRename { edit(validRename) }
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        let overflows = CGFloat(tabs.count) * 128 > bounds.width
        let inset: CGFloat = overflows ? 18 : 0
        previous.isHidden = !overflows
        next.isHidden = !overflows
        previous.frame = NSRect(x: 0, y: 4, width: 16, height: 24)
        next.frame = NSRect(x: bounds.width - 16, y: 4, width: 16, height: 24)
        scroll.frame = bounds.insetBy(dx: inset, dy: 0)
        let width = max(scroll.contentSize.width, CGFloat(tabs.count) * 128)
        document.frame = NSRect(x: 0, y: 4, width: width, height: 24)
        control.frame = document.bounds
        control.isHidden = tabs.isEmpty
        var centres: [PaneContent: Double] = [:]
        for (index, tab) in tabs.enumerated() {
            let rect = segmentRect(index)
            let label = shortened(tab.title, fitting: max(20, rect.width - 66))
            control.setLabel(label, forSegment: index)
            control.setWidth(0, forSegment: index)
            control.setToolTip(tab.title + (tab.isRunning ? " (Running)" : ""), forSegment: index)
            control.setImage(tab.isRunning ? NSImage(size: NSSize(width: 16, height: 16)) : image(tab.icon), forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            centres[tab.id] = rect.midX
            updateIndicator(tab, rect: rect, label: label)
        }
        onMeasure(centres)
        if let id = editingID, let index = tabs.firstIndex(where: { $0.id == id }) {
            editor?.frame = segmentRect(index).insetBy(dx: 5, dy: 1)
        }
        positionClose()
        if needsReveal || lastWidth != bounds.width {
            if control.selectedSegment >= 0 { control.scrollToVisible(segmentRect(control.selectedSegment)) }
            needsReveal = false
        }
        lastWidth = bounds.width
    }

    func segmentRect(_ index: Int) -> CGRect {
        let width = control.bounds.width / CGFloat(max(tabs.count, 1))
        return CGRect(x: CGFloat(index) * width, y: 0, width: width, height: 24)
    }

    func index(at point: CGPoint) -> Int? {
        guard control.bounds.contains(point), !tabs.isEmpty else { return nil }
        return min(tabs.count - 1, Int(point.x / (control.bounds.width / CGFloat(tabs.count))))
    }

    func hover(at point: CGPoint?) {
        hoveredID = point.flatMap(index(at:)).map { tabs[$0].id }
        positionClose()
    }

    private func positionClose() {
        guard editingID == nil, let id = hoveredID, let index = tabs.firstIndex(where: { $0.id == id }) else {
            closeButton.isHidden = true
            return
        }
        let rect = segmentRect(index)
        closeButton.frame = CGRect(x: rect.maxX - 22, y: 4, width: 16, height: 16)
        closeButton.toolTip = tabs[index].closeTitle
        closeButton.setAccessibilityLabel(tabs[index].closeTitle)
        closeButton.isHidden = false
    }

    private func updateIndicator(_ tab: NativeStripTab, rect: CGRect, label: String) {
        guard tab.isRunning else {
            indicators.removeValue(forKey: tab.id)?.removeFromSuperview()
            return
        }
        let indicator: NSProgressIndicator
        if let existing = indicators[tab.id] {
            indicator = existing
        } else {
            indicator = TabActivityIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.isIndeterminate = true
            indicator.isDisplayedWhenStopped = true
            indicator.setAccessibilityLabel("Running: \(tab.title)")
            indicators[tab.id] = indicator
            document.addSubview(indicator)
            if !reduceMotion { indicator.startAnimation(nil) }
        }
        let textWidth = (label as NSString).size(withAttributes: [.font: control.font!]).width
        indicator.frame = CGRect(x: rect.midX - (textWidth + 20) / 2, y: 4, width: 16, height: 16)
    }

    private func image(_ icon: TabItemIcon) -> NSImage? {
        let original: NSImage?
        switch icon {
        case .symbol(let name): original = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .page(let image): original = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        }
        let image = original?.copy() as? NSImage
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    private func shortened(_ title: String, fitting width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: control.font!]
        guard (title as NSString).size(withAttributes: attributes).width > width else { return title }
        var value = title
        while !value.isEmpty, ((value + "…") as NSString).size(withAttributes: attributes).width > width {
            value.removeLast()
        }
        return value + "…"
    }

    @objc private func selectSegment() {
        guard tabs.indices.contains(control.selectedSegment) else { return }
        tabs[control.selectedSegment].select()
    }

    @objc private func closeHovered() {
        guard let id = hoveredID else { return }
        tabs.first { $0.id == id }?.close()
    }

    @objc private func scrollPrevious() { scroll(by: -0.75) }
    @objc private func scrollNext() { scroll(by: 0.75) }
    private func scroll(by fraction: CGFloat) {
        let x = min(max(0, scroll.contentView.bounds.minX + scroll.contentSize.width * fraction),
                    max(0, control.bounds.width - scroll.contentSize.width))
        scroll.contentView.scroll(to: CGPoint(x: x, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func requestRename(_ id: PaneContent) {
        guard tabs.first(where: { $0.id == id })?.canRename == true else { return }
        onRenamingChange(id)
    }

    private func edit(_ id: PaneContent?) {
        editingID = nil
        editor?.removeFromSuperview()
        editor = nil
        guard let id, let index = tabs.firstIndex(where: { $0.id == id && $0.canRename }) else { return }
        editingID = id
        let field = NSTextField(string: tabs[index].editableTitle)
        field.font = control.font
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.frame = segmentRect(index).insetBy(dx: 5, dy: 1)
        field.setAccessibilityLabel("Tab name")
        editor = field
        document.addSubview(field)
        control.scrollToVisible(segmentRect(index))
        positionClose()
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, self.editor === field else { return }
            field.selectText(nil)
        }
    }

    private func finishRename(commit: Bool) {
        guard let id = editingID, let field = editor else { return }
        let title = field.stringValue
        editingID = nil
        editor = nil
        field.removeFromSuperview()
        if commit { tabs.first { $0.id == id }?.rename(title) }
        onRenamingChange(nil)
    }

    func controlTextDidEndEditing(_ notification: Notification) { finishRename(commit: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishRename(commit: false)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishRename(commit: true)
            return true
        }
        return false
    }
}

private final class TabActivityIndicator: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
