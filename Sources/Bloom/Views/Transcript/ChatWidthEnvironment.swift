import BloomCore
import SwiftUI

extension EnvironmentValues {
    @Entry var chatMeasures = ChatWidth.comfortable.measures()
}

private struct ChatReadingColumn: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: ChatWidthPreference.shared.measures.conversation, alignment: .leading)
    }
}

extension View {
    func chatReadingColumn() -> some View { modifier(ChatReadingColumn()) }
}
