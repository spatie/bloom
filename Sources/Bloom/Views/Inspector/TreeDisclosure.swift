import SwiftUI
import BloomCore

extension TreeDisclosureMotion {
    /// `easeOut`, the curve every reflow in this window travels on. See `SidebarView`, which spells
    /// the same line for `ProjectVisibilityMotion`.
    ///
    /// Nil is not "no opinion": handed to `withAnimation` it explicitly refuses the ambient
    /// transaction, which is what a change above `rowLimit` wants.
    var animation: Animation? {
        seconds.map { .easeOut(duration: $0) }
    }
}
