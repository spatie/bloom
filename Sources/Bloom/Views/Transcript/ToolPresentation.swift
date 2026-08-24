import SwiftUI
import BloomCore

extension ToolTint {
    /// The one place a tool row's role becomes a colour.
    var colour: Color {
        switch self {
        case .neutral: Palette.textSecondary
        case .accent: Palette.accent
        case .positive: Palette.positive
        case .negative: Palette.negative
        case .warning: Palette.warning
        }
    }
}
