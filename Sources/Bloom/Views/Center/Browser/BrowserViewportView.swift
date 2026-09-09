import SwiftUI
import BloomCore

/// The live page stays at one structural identity while its native coordinate space changes.
/// The surrounding scroll view makes oversized previews reachable at 100 percent.
struct BrowserViewportView: View {
    @Bindable var session: BrowserSession
    var paneMenu: (@MainActor () -> NSMenu)?
    var host = BrowserPaneHost()
    var isSelectingRegion = false
    var regionCapture: BrowserRegionCapture?
    var cancelRegion: @MainActor () -> Void = {}
    var addRegion: @MainActor () -> Void = {}
    @State private var drag: ResizeStart?

    private let gutter: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let viewport = session.viewport
            let padding = viewport.isEnabled ? gutter : 0
            let scale = viewport.scale(
                availableWidth: geometry.size.width - padding * 2,
                availableHeight: geometry.size.height - padding * 2
            )
            let width = viewport.isEnabled ? CGFloat(viewport.width) * scale : geometry.size.width
            let height = viewport.isEnabled ? CGFloat(viewport.height) * scale : geometry.size.height
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    BrowserWebView(
                        session: session, paneMenu: paneMenu, host: host,
                        viewportSize: viewport.isEnabled
                            ? CGSize(width: viewport.width, height: viewport.height) : nil
                    )
                    .allowsHitTesting(!isSelectingRegion)
                    .accessibilityHidden(isSelectingRegion)
                    if let regionCapture {
                        BrowserRegionCaptureView(capture: regionCapture, cancel: cancelRegion, add: addRegion)
                    }
                }
                .frame(width: width, height: height)
                .overlay {
                    if viewport.isEnabled {
                        Rectangle().strokeBorder(Palette.border, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .leading) {
                    if viewport.isEnabled {
                        handle(.left, scale: scale, centred: width + padding * 2 < geometry.size.width)
                            .offset(x: -gutter)
                    }
                }
                .overlay(alignment: .trailing) {
                    if viewport.isEnabled {
                        handle(.right, scale: scale, centred: width + padding * 2 < geometry.size.width)
                            .offset(x: gutter)
                    }
                }
                .overlay(alignment: .bottom) {
                    if viewport.isEnabled {
                        handle(.bottom, scale: scale, centred: false).offset(y: gutter)
                    }
                }
                .padding(padding)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .top)
            }
            .scrollDisabled(!viewport.isEnabled || isSelectingRegion)
            .background(viewport.isEnabled ? Palette.surfaceSunken : Palette.surface)
        }
        .clipped()
    }

    private func handle(_ edge: Edge, scale: Double, centred: Bool) -> some View {
        Capsule()
            .fill(Palette.textTertiary)
            .frame(width: edge == .bottom ? 32 : 4, height: edge == .bottom ? 4 : 32)
            .frame(width: edge == .bottom ? 64 : gutter, height: edge == .bottom ? gutter : 64)
            .contentShape(Rectangle())
            .allowsHitTesting(!isSelectingRegion)
            .pointerStyle(edge == .bottom ? .rowResize : .columnResize)
            .help(edge == .bottom ? "Drag to resize viewport height" : "Drag to resize viewport width")
            .accessibilityLabel(edge == .bottom ? "Viewport height" : "Viewport width")
            .accessibilityValue("\(edge == .bottom ? session.viewport.height : session.viewport.width) pixels")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 10 : -10
                session.viewport.resize(
                    width: session.viewport.width + (edge == .bottom ? 0 : step),
                    height: session.viewport.height + (edge == .bottom ? step : 0)
                )
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if drag == nil {
                        drag = ResizeStart(viewport: session.viewport, scale: scale, centred: centred)
                    }
                    guard let drag else { return }
                    let horizontal = value.translation.width / drag.scale * (drag.centred ? 2 : 1)
                    session.viewport.resize(
                        width: drag.viewport.width + (edge == .bottom ? 0 : Int(horizontal * (edge == .left ? -1 : 1))),
                        height: drag.viewport.height + (edge == .bottom ? Int(value.translation.height / drag.scale) : 0)
                    )
                }
                .onEnded { _ in drag = nil })
    }

    private enum Edge { case left, right, bottom }
    private struct ResizeStart {
        var viewport: BrowserViewport
        var scale: Double
        var centred: Bool
    }
}
