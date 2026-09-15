import SwiftUI
import BloomClient

/// A change is stated by its marker as well as its wash, including without colour perception.
public struct BloomDiffMarker: View {
    private let line: DiffLine?
    private let font: Font
    private let foreground: Color
    private let width: CGFloat

    public init(line: DiffLine?, font: Font = .caption2.monospaced(), foreground: Color = .secondary, width: CGFloat = 14) {
        self.line = line
        self.font = font
        self.foreground = foreground
        self.width = width
    }

    public var body: some View {
        Text(marker).font(font).foregroundStyle(foreground).frame(width: width, alignment: .center)
    }

    private var marker: String {
        switch line?.kind {
        case .addition: "+"
        case .deletion: "-"
        case .noNewline: "\\"
        default: " "
        }
    }
}
