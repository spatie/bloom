import SwiftUI
import BloomClient

/// Read-only unified review content. Native navigation and loading remain in the host controller.
public struct BloomDiffFile: View {
    private let file: FileDiff
    private let scrollsVertically: Bool
    @State private var expanded = false
    private static let lineCap = 2_000
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .callout) private var rowHeight = 23.0
    @ScaledMetric(relativeTo: .callout) private var characterWidth = 10.0
    @ScaledMetric(relativeTo: .caption2) private var numberWidth = 32.0
    @State private var viewportWidth: CGFloat = 320

    public init(file: FileDiff, scrollsVertically: Bool = true) {
        self.file = file
        self.scrollsVertically = scrollsVertically
    }

    public var body: some View {
        let visible = visibleFile
        let prepared = BloomDiffPreparation.prepare(visible, scheme: scheme)
        let width = max(viewportWidth, CGFloat(prepared.longestLine) * characterWidth + numberWidth * 2 + 38)
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if file.isBinary {
                unavailable("Binary file", detail: "This file cannot be displayed as a text diff.")
            } else if file.hunks.isEmpty {
                unavailable(file.isModeChangeOnly ? "File permissions changed" : "No text changes",
                            detail: file.isModeChangeOnly ? "\(file.oldMode ?? "") → \(file.newMode ?? "")" : "This change has no text hunks.")
            } else {
                if scrollsVertically {
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            diffRows(visible, prepared: prepared, width: width)
                        }
                    }
                } else {
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            diffRows(visible, prepared: prepared, width: width)
                        }
                    }
                }
                if lineCount > Self.lineCap {
                    Divider()
                    Button {
                        expanded.toggle()
                    } label: {
                        Text(expanded ? "Show fewer lines" : "Show all \(lineCount) lines")
                            .font(.callout)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .onChange(of: file.id) { expanded = false }
    }

    private var lineCount: Int { file.hunks.reduce(0) { $0 + $1.lines.count } }

    private var visibleFile: FileDiff {
        guard !expanded, lineCount > Self.lineCap else { return file }
        var copy = file
        var remaining = Self.lineCap
        copy.hunks = file.hunks.compactMap { hunk in
            guard remaining > 0 else { return nil }
            var visible = hunk
            visible.lines = Array(hunk.lines.prefix(remaining))
            remaining -= visible.lines.count
            return visible
        }
        return copy
    }

    @ViewBuilder
    private func diffRows(_ visible: FileDiff, prepared: BloomDiffPreparation.Prepared, width: CGFloat) -> some View {
        ForEach(visible.hunks.indices, id: \.self) { hunkIndex in
            let hunk = visible.hunks[hunkIndex]
            BloomDiffHunkHeader(width: width, height: rowHeight + 8,
                                foreground: tertiary, surface: surface) {
                Image(systemName: "curlybraces").font(.caption)
            } title: {
                Text(hunk.header.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
                     : hunk.header.trimmingCharacters(in: .whitespaces))
                    .font(.caption.monospaced())
            }
            ForEach(hunk.lines.indices, id: \.self) { lineIndex in
                line(hunk.lines[lineIndex], text: prepared.lines[hunkIndex][lineIndex], width: width)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            BloomFilePath {
                let directory = (file.displayPath as NSString).deletingLastPathComponent
                if !directory.isEmpty { Text(directory + "/").foregroundStyle(.secondary) }
            } name: {
                Text((file.displayPath as NSString).lastPathComponent).fontWeight(.semibold)
            }
            .font(.callout)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(file.displayPath)
            BloomDiffStats(additions: file.additions, deletions: file.deletions, isBinary: file.isBinary)
        }
        .padding(12)
    }

    private func line(_ line: DiffLine, text: AttributedString, width: CGFloat) -> some View {
        BloomDiffLineFrame(width: width, height: rowHeight) {
            BloomDiffGutter(line: line, foreground: tertiary, numberWidth: numberWidth)
        } content: {
            HStack(spacing: 0) {
                BloomDiffMarker(line: line, foreground: tertiary)
                Text(text).font(.callout.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
            }
        }
        .background(wash(line.kind))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BloomDiffGutter.speech(for: line))
    }

    private func unavailable(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: scrollsVertically ? .infinity : nil, alignment: .topLeading)
    }

    private var tertiary: Color { BloomColour.resolve(PaletteInk.textTertiary, scheme: scheme) }
    private var surface: Color { BloomColour.resolve(PaletteInk.surfaceSunken, scheme: scheme) }
    private func wash(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: BloomColour.resolve(PaletteInk.diffPositive, scheme: scheme).opacity(0.13)
        case .deletion: BloomColour.resolve(PaletteInk.negative, scheme: scheme).opacity(0.14)
        default: .clear
        }
    }
}
