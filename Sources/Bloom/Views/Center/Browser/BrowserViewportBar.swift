import SwiftUI
import BloomCore

/// Compact controls shared by the toolbar popover and the interactive preview fixture.
struct BrowserViewportBar: View {
    @Binding var viewport: BrowserViewport

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metrics.spacingSmall) {
                presets
                dimensions
                actions
            }
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                HStack { presets; Spacer(); actions }
                dimensions
            }
        }
        .controlSize(.small)
        .font(Typo.label)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presets: some View {
        Menu {
            ForEach(BrowserViewport.Preset.allCases, id: \.self) { preset in
                Button("\(preset.rawValue) (\(preset.width) × \(preset.height))") {
                    viewport.select(preset)
                }
            }
            if !viewport.savedSizes.isEmpty {
                Section("Saved sizes") {
                    ForEach(viewport.savedSizes, id: \.self) { size in
                        Button("\(size.width) × \(size.height)") {
                            viewport.resize(width: size.width, height: size.height)
                        }
                    }
                }
            }
            Divider()
            Button("Save Current Size") { viewport.saveSize() }
                .disabled(!viewport.canSaveSize)
            if !viewport.savedSizes.isEmpty {
                Button("Remove Saved Sizes") { viewport.removeSavedSizes() }
            }
        } label: {
            Text(viewport.preset?.rawValue ?? "Custom")
        }
        // Native menu buttons derive their intrinsic size from the title, ignoring a frame on
        // the label. Constrain the control itself so Phone, Custom and Small phone align alike.
        .frame(width: 110, alignment: .leading)
        .help("Choose a viewport size")
        .accessibilityLabel("Viewport preset")
    }

    private var dimensions: some View {
        HStack(spacing: 4) {
            dimension("Width", value: viewport.width) {
                viewport.resize(width: $0, height: viewport.height)
            }
            Text("×").foregroundStyle(Palette.textSecondary)
            dimension("Height", value: viewport.height) {
                viewport.resize(width: viewport.width, height: $0)
            }
        }
        .help("Viewport dimensions in CSS pixels")
    }

    private var actions: some View {
        HStack(spacing: Metrics.spacingSmall) {
            Button("Rotate", systemImage: "rotate.right") {
                viewport.rotate()
            }
                .labelStyle(.iconOnly)
                .help("Swap viewport width and height")
            Picker("Preview scale", selection: $viewport.fitsPane) {
                Text("Fit").tag(true)
                Text("100%").tag(false)
            }
            .labelsHidden()
            .frame(width: 72)
            .help("Scale the preview to fit, or show it at actual size")
        }
    }

    private func dimension(_ name: String, value: Int, change: @escaping (Int) -> Void) -> some View {
        ViewportDimensionField(name: name, value: value, change: change)
    }
}

/// Commit a whole number on Return or focus loss. Clamping each keystroke would turn the first
/// digit of 1440 into 240 before the reader could finish typing.
private struct ViewportDimensionField: View {
    var name: String
    var value: Int
    var change: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(name, text: $text)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
            .focused($focused)
            .accessibilityLabel("Viewport \(name.lowercased()) in CSS pixels")
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
            .onChange(of: value, initial: true) { text = String(value) }
    }

    private func commit() {
        if let number = Int(text.trimmingCharacters(in: .whitespaces)), number != value { change(number) }
        text = String(value)
    }
}
