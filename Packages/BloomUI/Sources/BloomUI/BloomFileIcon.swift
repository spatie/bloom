import SwiftUI

/// File browser decoration stays out of VoiceOver's path announcement.
public struct BloomFileIcon: View {
    private let isDirectory: Bool
    public init(isDirectory: Bool) { self.isDirectory = isDirectory }
    public var body: some View {
        Image(systemName: isDirectory ? "folder.fill" : "doc.text")
            .foregroundStyle(isDirectory ? Color.accentColor : Color.secondary)
            .frame(width: 22)
            .accessibilityHidden(true)
    }
}
