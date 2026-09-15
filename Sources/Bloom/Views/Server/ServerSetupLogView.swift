import SwiftUI
import AppKit
import BloomCore

/// A bounded native log can sit inside a settings form without compressing neighbouring text.
struct ServerSetupLogView: View {
    let activity: ServerSetupActivity
    var height: CGFloat = 260
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack {
                Text("Server output").font(Typo.captionEmphasis)
                Spacer()
                Button(copied ? "Copied" : "Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(activity.output, forType: .string)
                    copied = true
                }.controlSize(.small)
            }
            ServerSetupOutputView(lines: activity.lines).frame(height: height)
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }
}
