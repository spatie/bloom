import SwiftUI

/// A quiet directory and a prominent filename, with truncation spending the directory first.
public struct BloomFilePath<Folder: View, Name: View>: View {
    private let folder: Folder
    private let name: Name

    public init(@ViewBuilder folder: () -> Folder, @ViewBuilder name: () -> Name) {
        self.folder = folder()
        self.name = name()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            folder.lineLimit(1).truncationMode(.head).layoutPriority(-1)
            name.lineLimit(1).truncationMode(.middle)
        }
    }
}
