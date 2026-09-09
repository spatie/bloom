import SwiftUI
import BloomClient

/// Native diff layouts share the same ruler and spoken line description.
public struct BloomDiffGutter: View {
    public enum Numbers: Sendable { case both, old, new }
    private let line: DiffLine?
    private let numbers: Numbers
    private let font: Font
    private let foreground: Color
    private let numberWidth: CGFloat
    private let padding: CGFloat

    public init(line: DiffLine?, numbers: Numbers = .both, font: Font = .caption2.monospaced(),
                foreground: Color = .secondary, numberWidth: CGFloat = 32, padding: CGFloat = 4) {
        self.line = line
        self.numbers = numbers
        self.font = font
        self.foreground = foreground
        self.numberWidth = numberWidth
        self.padding = padding
    }

    public var body: some View {
        HStack(spacing: 0) {
            if numbers != .new { number(line?.oldNumber) }
            if numbers != .old { number(line?.newNumber) }
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(font).monospacedDigit().foregroundStyle(foreground)
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.trailing, padding)
    }

    public static func speech(for line: DiffLine?) -> String {
        guard let line else { return "" }
        if line.kind == .noNewline { return "No newline at end of file" }
        let place = (line.newNumber ?? line.oldNumber).map { " \($0)" } ?? ""
        let state = switch line.kind {
        case .addition: "Added line\(place)"
        case .deletion: "Removed line\(place)"
        default: "Line\(place)"
        }
        let text = line.text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "\(state), empty" : "\(state), \(text)"
    }
}
