import SwiftUI

/// Shared file-row content. UIKit and AppKit keep ownership of selection, menus and navigation.
public struct BloomFileRow<Leading: View, Name: View, Trailing: View>: View {
    private let spacing: CGFloat
    private let alignment: VerticalAlignment
    private let leading: Leading
    private let name: Name
    private let trailing: Trailing

    public init(spacing: CGFloat = 6, alignment: VerticalAlignment = .center, @ViewBuilder leading: () -> Leading,
                @ViewBuilder name: () -> Name, @ViewBuilder trailing: () -> Trailing) {
        self.spacing = spacing
        self.alignment = alignment
        self.leading = leading()
        self.name = name()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: alignment, spacing: spacing) {
            leading
            name.lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            trailing
        }
    }
}

public extension BloomFileRow where Leading == BloomFileIcon, Name == Text, Trailing == EmptyView {
    init(path: String, isDirectory: Bool = false) {
        self.init {
            BloomFileIcon(isDirectory: isDirectory)
        } name: {
            Text(verbatim: (path as NSString).lastPathComponent)
        } trailing: {
            EmptyView()
        }
    }
}
