import SwiftUI

/// App and server settings share sizing, sidebar treatment and the same readable detail width.
struct SettingsLayout<Sidebar: View, Detail: View>: View {
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        // A fixed sidebar avoids the split view's collapsible toolbar and reserved top inset.
        HStack(spacing: 0) {
            sidebar()
                .listStyle(.sidebar)
                .frame(width: 185)
            Divider()
            detail()
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Palette.windowBackground)
        }
        .frame(minWidth: 780, idealWidth: 850, minHeight: 560, idealHeight: 700)
    }
}
