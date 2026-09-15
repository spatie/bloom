import SwiftUI
import BloomCore

/// Settings > Servers: the alpha notice, then the switch.
///
/// A pane of its own rather than a section of General, because the switch sat between Open In and
/// software updates where nobody looking for servers would find it, and because the alpha warning
/// belongs next to the switch it is about rather than in a pane about everyday behaviour.
struct RemoteServersSettingsView: View {
    var body: some View {
        Form {
            Section {
                RemoteServersAlphaNotice()
            }

            RemoteServersSettingsSection()
        }
        .settingsForm()
    }
}

/// What alpha means here, and the way to say something about it.
///
/// **The button is Help's Send Feedback**, not a channel of its own: the sheet, its draft and its
/// endpoint are `FeedbackPresenter`'s. That sheet is presented by `RootView` on the main window,
/// so the main window is raised first; otherwise the form opens behind Settings and the press
/// looks like nothing happening, which is the same trap `WelcomeView.submitAPrompt` describes.
private struct RemoteServersAlphaNotice: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.gutter) {
            Image(systemName: "flask.fill")
                .foregroundStyle(Palette.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text(RemoteServerFeature.alphaTitle)
                    .font(Typo.labelEmphasis)
                Text(RemoteServerFeature.alphaDetail)
                    .settingsFootnote()
            }

            Spacer(minLength: Metrics.gutter)

            Button(RemoteServerFeature.alphaFeedback) {
                MainWindow.raise()
                FeedbackPresenter.shared.open(.report)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
