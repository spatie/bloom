import SwiftUI
import BloomCore

/// Selection takes place on the snapshot itself. A live page can animate or reflow between a
/// drag and Add, which would otherwise attach a different region from the one the reader saw.
struct BrowserRegionCaptureView: View {
    @Bindable var capture: BrowserRegionCapture
    var cancel: @MainActor () -> Void
    var add: @MainActor () -> Void
    @FocusState private var commentFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            canvas
            Hairline()
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text(capture.selection == nil ? "Drag to select an area" : "Drag again to change the area")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                TextField("What should change?", text: $capture.comment, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .focused($commentFocused)
                    .accessibilityLabel("Comment about the selected area")
                if let failure = capture.failure {
                    Text(failure).font(Typo.caption).foregroundStyle(Palette.textPrimary)
                }
                Text("Adds to the draft in \(capture.conversation)")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .help(capture.conversation)
                HStack {
                    Button("Select All") {
                        capture.selection = CGRect(x: 0, y: 0, width: 1, height: 1)
                        commentFocused = true
                    }
                    Spacer(minLength: Metrics.spacingSmall)
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    Button(capture.isAdding ? "Adding…" : "Add to Draft", action: add)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!capture.canAdd)
                }
                .controlSize(.small)
            }
            .padding(Metrics.spacingWide)
            .disabled(capture.isAdding)
        }
        .background(Palette.surface)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let frame = BrowserRegion.imageFrame(image: capture.imageSize, canvas: proxy.size)
            let selected = capture.selection.map { BrowserRegion.rect($0, in: frame) }
            ZStack(alignment: .topLeading) {
                Palette.surfaceSunken
                Image(decorative: capture.image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                Path { path in
                    path.addRect(frame)
                    if let selected { path.addRect(selected) }
                }
                .fill(.black.opacity(0.4), style: FillStyle(eoFill: true))
                if let selected {
                    Rectangle()
                        .strokeBorder(.white, lineWidth: 2)
                        .background { Rectangle().stroke(.black, lineWidth: 1) }
                        .frame(width: selected.width, height: selected.height)
                        .offset(x: selected.minX, y: selected.minY)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        capture.selection = BrowserRegion.selection(
                            from: value.startLocation, to: value.location, in: frame
                        )
                    }
                    .onEnded { _ in
                        if capture.selection != nil { commentFocused = true }
                    }
            )
            .allowsHitTesting(!capture.isAdding)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page screenshot")
            .accessibilityValue(capture.selection == nil ? "No area selected" : "Area selected")
            .accessibilityHint("Drag to select an area, or use Select All to attach the visible page.")
        }
    }
}
