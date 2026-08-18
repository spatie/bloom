import SwiftUI

/// A sentence of prose inside an expanded row, such as the description an agent wrote for the task
/// it was handing off.
struct DetailCaption: View {
    var text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}
