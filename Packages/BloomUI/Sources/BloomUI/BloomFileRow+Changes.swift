import SwiftUI
import BloomClient

public extension BloomFileRow where Leading == BloomChangeBadge, Name == BloomChangedFileName, Trailing == EmptyView {
    init(file: ChangedFile, showsDirectory: Bool = true) {
        self.init(spacing: 8, alignment: .top) {
            BloomChangeBadge(change: file.change)
        } name: {
            BloomChangedFileName(file: file, showsDirectory: showsDirectory)
        } trailing: {
            EmptyView()
        }
    }
}
