import SwiftUI

/// Platform typography can vary without duplicating paragraph, list, quote or table layout.
public struct BloomMarkdownStyle {
    public var foreground: Color = .primary
    public var secondary: Color = .secondary
    public var tertiary: Color = .secondary
    public var border: Color = Color.primary.opacity(0.15)
    public var surface: Color = Color.primary.opacity(0.035)
    public var positive: Color = .green
    public var markerFont: Font = .body
    public var markerWidth: CGFloat = 24
    /// Zero retains the desktop reading-column layout. Mobile sets a Dynamic Type minimum.
    public var minimumTableColumnWidth: CGFloat = 0
    public var proseListSpacing: CGFloat = 3
    public var taskLineSpacing: CGFloat = 2
    public var tightListGap: CGFloat = 6
    public var looseListGap: CGFloat = 12
    public var taskGap: CGFloat = 4

    public init() {}
}

/// A typography request for the platform's selectable inline text adapter.
public enum BloomMarkdownInlineRole {
    case body
    case heading(Int)
    case tableHeader
    case tableCell
}
