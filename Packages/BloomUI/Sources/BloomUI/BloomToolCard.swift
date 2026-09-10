import SwiftUI
import BloomClient

/// Inspection stays collapsible, while tool names, target summaries and code surfaces match the Mac.
public struct BloomToolCard: View {
    private let inspection: RemoteToolInspection
    @State private var expanded = false
    @Environment(\.colorScheme) private var scheme
    public init(inspection: RemoteToolInspection) { self.inspection = inspection }

    public var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(inspection.status).font(.caption).foregroundStyle(.secondary)
                if let arguments = inspection.arguments {
                    BloomCodeBlock(code: bounded(arguments), language: .json)
                }
                if let output = inspection.output {
                    BloomCodeBlock(code: bounded(output), language: .plainText)
                }
                if inspection.hasImages {
                    Label("This result also contains images.", systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if (inspection.arguments?.count ?? 0) > 100_000 || (inspection.output?.count ?? 0) > 100_000 {
                    Text("Showing the first 100,000 characters.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: inspection.presentation.glyph).foregroundStyle(tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(inspection.presentation.label).font(.callout)
                    if inspection.arguments != nil, inspection.output != nil, inspection.status != "Completed" {
                        Text(inspection.status).font(.caption)
                            .foregroundStyle(BloomColour.resolve(inspection.isError ? PaletteInk.negative : PaletteInk.warning, scheme: scheme))
                    }
                    if !inspection.presentation.detailLine.isEmpty {
                        Text(inspection.presentation.detailLine)
                            .font(inspection.presentation.detailIsCode ? .caption.monospaced() : .caption)
                            .foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if let duration = inspection.durationMS {
                    Text(String(format: "%.1fs", Double(duration) / 1_000)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .tint(tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func bounded(_ value: String) -> String { String(value.prefix(100_000)) }
    private var tint: Color {
        let pair: PaletteInk.Pair = switch inspection.presentation.tint {
        case .neutral: PaletteInk.textTertiary
        case .accent, .positive: PaletteInk.accent
        case .negative: PaletteInk.negative
        case .warning: PaletteInk.warning
        }
        return BloomColour.resolve(pair, scheme: scheme)
    }
}
