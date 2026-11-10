import SwiftUI
import BloomCore

/// Real settings and transcript renderers. Supply -transcript.allowedAppLinkSchemes on launch
/// to capture the same page with an empty allowlist and with explicitly enabled app schemes.
struct AppLinksGallery: View {
    let app: AppModel

    private static let sample = """
    [Linear issue T-123](linear://team/issue/T-123) and [Slack channel](slack://channel?team=T1&id=C1).

    Bare app link: linear://team/issue/T-123

    [Zoom meeting](zoommtg://zoom.us/join?confno=123) stays plain unless allowed.

    Always blocked: [File](file:///tmp/private), [JavaScript](javascript:alert), [Bloom](bloom://workspace/123), [Bloom Dev](bloomdev://workspace/123), [Bloom source](bloom-source://file?path=/tmp/private).

    [Web link](https://example.com) keeps working.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Form { ChatLinkSettingsSection() }
                .settingsForm()
                .frame(height: 235)

            Group {
                Text("Assistant transcript").font(Typo.title)
                MarkdownView(Self.sample)
                Divider()
                Text("Streaming transcript").font(Typo.title)
                StreamingMarkdownView("[Linear issue](linear://team/issue/T-123), [Zoom](zoommtg://zoom.us/join?confno=123), [JavaScript](javascript:alert).")
                Divider()
                Text("User transcript").font(Typo.title)
                UserTurnRowView(
                    text: "Open linear://team/issue/T-123 or zoommtg://zoom.us/join?confno=123. Never bloom://workspace/123 or file:///tmp/private.",
                    home: TranscriptHome()
                )
                Divider()
                Text("Queued transcript").font(Typo.title)
                PendingTurnRowView(
                    delivery: Delivery(
                        targetSessionID: SessionID("app-links-gallery"),
                        body: "Follow up on linear://team/issue/T-123. Blocked: bloom://workspace/123."
                    ),
                    holdSentence: nil, onEdit: {}, onDelete: {}
                )
            }
            .padding(.horizontal, Metrics.inset)
        }
        .padding(Metrics.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(app)
        .markdownLinkActions(TranscriptLink.actions(for: nil))
    }
}

extension Gallery {
    static let appLinks = Gallery(
        name: "app-links", title: "App links in chat",
        size: CGSize(width: 800, height: 850), needsFocus: false,
        view: { AnyView(AppLinksGallery(app: $0)) }
    )
}
