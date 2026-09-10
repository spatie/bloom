import SwiftUI
import AppKit

extension FocusedValues {
    @Entry var sourceFind: SourceFindAction?
}

struct SourceFindAction: Equatable {
    var path: String
    var perform: @MainActor (NSTextFinder.Action) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.path == rhs.path }
}
