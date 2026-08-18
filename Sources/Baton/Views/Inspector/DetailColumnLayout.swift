import Foundation

/// What the detail column refuses to go below.
///
/// Named and shared rather than a literal in `RootView`, because the inspector's ceiling is
/// derived from it: the inspector may take everything except this. When the two disagreed, their
/// sum could exceed the window and `NavigationSplitView` balanced the books by squeezing the
/// sidebar, which is the one column neither of them owns.
enum DetailColumnLayout {
    static let minimum: Double = 420
}
