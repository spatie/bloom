import Foundation
import SwiftUI

/// How large the conversation is set.
///
/// Named steps rather than a slider or a point size, for two reasons. A rung is not a point size:
/// one setting moves twelve of them at once, and the only number that would mean anything to a
/// person is the one prose ends up at. And a fixed set of steps is its own bounds and its own way
/// back: "Default" is a place on the control, not a number somebody has to remember.
///
/// The multipliers are chosen so that every rung of `Typo` still lands on a different whole point
/// at every step. At 0.85 the caption and the micro rung both round to 9 and the transcript loses
/// a level of hierarchy, which is why the small step is 0.9.
enum ChatTextSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case standard
    case large
    case extraLarge
    case largest

    static let defaultsKey = "chat.textSize"

    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .small: 0.9
        case .standard: 1
        case .large: 1.15
        case .extraLarge: 1.3
        case .largest: 1.5
        }
    }

    var title: String {
        switch self {
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .extraLarge: "Larger"
        case .largest: "Largest"
        }
    }
}
