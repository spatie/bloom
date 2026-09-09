import SwiftUI
import BloomClient

public extension BloomFileRow where Leading == BloomChangeBadge, Name == BloomChangedFileName, Trailing == EmptyView {
    init(file: ChangedFile) {
        self.init(spacing: 8, alignment: .top) {
            BloomChangeBadge(change: file.change)
        } name: {
            BloomChangedFileName(file: file)
        } trailing: {
            EmptyView()
        }
    }
}
