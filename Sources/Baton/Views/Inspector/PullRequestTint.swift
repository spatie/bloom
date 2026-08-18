import SwiftUI
import BatonCore

extension PullRequestStatus.Tone {
    /// The palette colour a tone resolves to, or nil for the neutral one.
    ///
    /// Nil rather than grey, so a pull request with nothing to report leaves a plain strip instead
    /// of a wash that looks like a state. Shared by the bar's background and the parts drawn on
    /// it, which is the point of it living here: the sentence, the chip and the merge button all
    /// have to land on the same colour or the strip reads as three unrelated things.
    var color: Color? {
        switch self {
        case .neutral: nil
        case .positive: Palette.positive
        case .negative: Palette.negative
        case .warning: Palette.warning
        case .accent: Palette.accent
        }
    }
}
