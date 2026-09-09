import SwiftUI
import BloomClient
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The default native adapter for shared code fences. Desktop injects its existing syntax cache.
public struct BloomCodeBlock: View {
    private let code: String
    private let language: Language
    private let isStreaming: Bool
    private static let lineCap = 2_000
    @State private var expanded = false
    @State private var copied = false
    @Environment(\.colorScheme) private var scheme

    public init(code: String, language: Language, isStreaming: Bool = false) {
        self.code = code
        self.language = language
        self.isStreaming = isStreaming
    }

    public var body: some View {
        let prepared = BloomCodeRendering.prepare(
            code: code, language: language, expanded: expanded, scheme: scheme, streaming: isStreaming
        )
        BloomCodeBlockFrame(
            surface: BloomColour.resolve(PaletteInk.surfaceSunken, scheme: scheme),
            border: BloomColour.resolve(PaletteInk.border, scheme: scheme),
            canFold: prepared.lineCount > Self.lineCap
        ) {
            Text(displayName).font(.caption).foregroundStyle(.secondary)
        } copy: {
            Button {
                copy()
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .task(id: copied) {
                guard copied else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                copied = false
            }
        } content: {
            Text(prepared.text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
        } fold: {
            Button {
                expanded.toggle()
            } label: {
                Text(expanded ? "Show fewer lines" : "Show all \(prepared.lineCount) lines")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .font(.caption)
            .buttonStyle(.plain)
        }
    }

    private var displayName: String {
        switch language {
        case .plainText: "Plain text"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .html, .css, .json, .yaml, .toml, .sql, .xml, .php: language.rawValue.uppercased()
        default: language.rawValue.capitalized
        }
    }

    private func copy() {
        #if os(iOS)
        UIPasteboard.general.string = code
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
    }
}
