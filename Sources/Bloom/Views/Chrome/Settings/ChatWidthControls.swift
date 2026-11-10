import BloomCore
import SwiftUI

struct ChatWidthControls: View {
    @Binding var choice: ChatWidth
    @Binding var limitsProse: Bool

    var body: some View {
        Picker("Chat width", selection: $choice) {
            ForEach(ChatWidth.allCases) { width in Text(width.title).tag(width) }
        }
        .pickerStyle(.segmented)
        Toggle("Limit paragraph width for easier reading", isOn: $limitsProse)
        Text("Tables, code blocks and command output use the full chat column. Changes apply to open conversations.")
            .settingsFootnote()
    }
}
