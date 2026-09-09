import SwiftUI
import BloomCore

/// All drag coordinates belong to the canvas, including the moving handles. A handle's own
/// coordinate space moves during a drag and would otherwise make the crop jump back and forth.
struct BrowserRegionCanvas: View {
    @Bindable var capture: BrowserRegionCapture
    var finishSelection: @MainActor () -> Void
    @State private var moveStart: CGRect?
    @State private var resizeStart: CGRect?

    private let coordinateSpace = "browser-region-canvas"

    var body: some View {
        GeometryReader { proxy in
            let frame = BrowserRegion.rect(capture.pageRect, in: CGRect(origin: .zero, size: proxy.size))
            let selected = capture.selection.map { BrowserRegion.rect($0, in: frame) }
            ZStack(alignment: .topLeading) {
                Image(decorative: capture.image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
                Path { path in
                    path.addRect(frame)
                    if let selected { path.addRect(selected) }
                }
                .fill(.black.opacity(selected == nil ? 0 : 0.38), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Color.clear
                    .contentShape(Rectangle())
                    .pointerStyle(.rectSelection)
                    .gesture(select(in: frame))
                if let selected {
                    selectionOutline(selected, frame: frame)
                    dimensions(selected, canvas: proxy.size)
                    ForEach(BrowserRegion.Corner.allCases, id: \.self) { corner in
                        handle(corner, selection: selected, frame: frame)
                    }
                }
            }
            .coordinateSpace(name: coordinateSpace)
            .clipped()
            .allowsHitTesting(!capture.isAdding)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Selected area of the page")
            .accessibilityValue(sizeLabel)
            .accessibilityHint("Drag to select. Drag inside to move, or drag a corner to resize.")
            .accessibilityAction(named: "Move left") { nudge(x: -1, y: 0) }
            .accessibilityAction(named: "Move right") { nudge(x: 1, y: 0) }
            .accessibilityAction(named: "Move up") { nudge(x: 0, y: -1) }
            .accessibilityAction(named: "Move down") { nudge(x: 0, y: 1) }
        }
    }

    private var sizeLabel: String {
        guard let selection = capture.selection,
              let pixels = BrowserRegion.pixels(selection, image: capture.imageSize) else { return "No area selected" }
        return "\(Int(pixels.width)) × \(Int(pixels.height)) px"
    }

    private func select(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                guard frame.contains(value.startLocation) else { return }
                capture.selection = BrowserRegion.selection(from: value.startLocation, to: value.location, in: frame)
            }
            .onEnded { _ in
                if capture.selection != nil { finishSelection() }
            }
    }

    private func selectionOutline(_ selected: CGRect, frame: CGRect) -> some View {
        Rectangle()
            .fill(.clear)
            .overlay { Rectangle().strokeBorder(.white, lineWidth: 2) }
            .overlay { Rectangle().stroke(Palette.accent, lineWidth: 1) }
            .contentShape(Rectangle())
            .frame(width: selected.width, height: selected.height)
            .offset(x: selected.minX, y: selected.minY)
            .pointerStyle(moveStart == nil ? .grabIdle : .grabActive)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                .onChanged { value in
                    if moveStart == nil { moveStart = capture.selection }
                    guard let moveStart, frame.width > 0, frame.height > 0 else { return }
                    capture.selection = BrowserRegion.moved(moveStart, by: CGSize(
                        width: value.translation.width / frame.width,
                        height: value.translation.height / frame.height
                    ))
                }
                .onEnded { _ in
                    moveStart = nil
                    finishSelection()
                })
    }

    private func handle(_ corner: BrowserRegion.Corner, selection: CGRect, frame: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white)
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Palette.accent, lineWidth: 1.5) }
            .frame(width: 8, height: 8)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .frame(width: min(20, selection.width), height: min(20, selection.height))
            .contentShape(Rectangle())
            .position(x: corner.isLeft ? selection.minX : selection.maxX, y: corner.isTop ? selection.minY : selection.maxY)
            .pointerStyle(.frameResize(position: resizePosition(corner)))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                .onChanged { value in
                    if resizeStart == nil { resizeStart = capture.selection }
                    guard let resizeStart, frame.width > 0, frame.height > 0 else { return }
                    capture.selection = BrowserRegion.resized(resizeStart, corner: corner, to: CGPoint(
                        x: (value.location.x - frame.minX) / frame.width,
                        y: (value.location.y - frame.minY) / frame.height
                    ))
                }
                .onEnded { _ in
                    resizeStart = nil
                    finishSelection()
                })
    }

    private func resizePosition(_ corner: BrowserRegion.Corner) -> FrameResizePosition {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    private func dimensions(_ selected: CGRect, canvas: CGSize) -> some View {
        Text(sizeLabel)
            .font(Typo.codeTiny)
            .monospacedDigit()
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Palette.surfaceRaised, in: Capsule())
            .overlay { Capsule().strokeBorder(Palette.border, lineWidth: Metrics.outline) }
            .fixedSize()
            .position(
                x: min(max(selected.midX, 80), max(80, canvas.width - 80)),
                y: min(selected.maxY + 20, max(14, canvas.height - 14))
            )
            .allowsHitTesting(false)
    }

    private func nudge(x: CGFloat, y: CGFloat) {
        guard let selection = capture.selection, !capture.isAdding else { return }
        capture.selection = BrowserRegion.moved(selection, by: CGSize(
            width: x * 10 / capture.imageSize.width, height: y * 10 / capture.imageSize.height
        ))
    }
}
