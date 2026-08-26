import SwiftUI
import BloomCore

/// The centre column's tab strip: what its tabs are called and what they wear.
///
/// It exists because `--snapshot` cannot photograph this. The strip's ground is a material, and
/// an offscreen `ImageRenderer` paints SwiftUI's yellow placeholder over any `NSViewRepresentable`,
/// which is what a material is; the tabs would come out on a yellow bar. This page is captured in
/// a real window instead. See `Snapshot`.
///
/// Photograph it with `Bloom --snapshot-gallery <dir> --gallery pane-tabs`.
///
/// The tabs here are `TabItemView`, the same view the strip draws, at the same size, so the
/// picture cannot disagree with the app about what a tab looks like. What is faked is only the
/// state behind them: there is no workspace, no session and no web view in a capture.
struct PaneTabsGallery: View {
    /// Only so the strip has one to read. `TabStrip` puts the busy signal on the rule under the
    /// title bar and asks the app model whether anything is running, so a strip drawn without one
    /// in the environment traps rather than draws.
    var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Pane tabs")
                .font(Typo.title)

            row("One chat, a browser and a terminal", tabs: [
                fixture("Chat", PaneGlyph.chat, active: true),
                fixture(
                    BrowserTabTitle.title(page: "Spatie", address: "https://spatie.be/", fallback: "Browser"),
                    PaneGlyph.browser
                ),
                fixture("Terminal", PaneGlyph.terminal),
            ])

            row("Several chats, numbered", tabs: [
                fixture("Chat", PaneGlyph.chat),
                fixture("Chat 2", PaneGlyph.chat, active: true),
                fixture("Chat 3", PaneGlyph.chat),
                fixture("Terminal", PaneGlyph.terminal),
            ])

            row("A workspace running two backends", tabs: [
                fixture("Chat", PaneGlyph.agentMark(for: .claudeCode), active: true),
                fixture("Chat 2", PaneGlyph.agentMark(for: .codex)),
                fixture("Terminal", PaneGlyph.terminal),
            ])

            row("A page with a long title, beside its neighbours", tabs: [
                fixture("Chat", PaneGlyph.chat),
                fixture(
                    BrowserTabTitle.title(
                        page: Self.longTitle, address: "https://developer.apple.com/documentation/webkit",
                        fallback: "Browser"
                    ),
                    PaneGlyph.browser,
                    active: true
                ),
                fixture("Terminal", PaneGlyph.terminal),
            ])

            row("A browser mid load: the name it came from, then the host it went to", tabs: [
                fixture(
                    BrowserTabTitle.title(
                        page: BrowserTabTitle.advance(
                            from: .init(address: "https://spatie.be/", title: "Spatie"),
                            to: .init(address: "https://spatie.be/open-source")
                        ).title,
                        address: "https://spatie.be/open-source",
                        fallback: "Browser"
                    ),
                    PaneGlyph.browser,
                    active: true
                ),
                fixture(
                    BrowserTabTitle.title(
                        page: BrowserTabTitle.advance(
                            from: .init(address: "https://spatie.be/", title: "Spatie"),
                            to: .init(address: "https://github.com/spatie")
                        ).title,
                        address: "https://github.com/spatie",
                        fallback: "Browser"
                    ),
                    PaneGlyph.browser
                ),
                fixture(
                    BrowserTabTitle.title(page: "", address: "http://localhost:3000/", fallback: "Browser"),
                    PaneGlyph.browser
                ),
                fixture(
                    BrowserTabTitle.title(page: "", address: "about:blank", fallback: "Browser 2"),
                    PaneGlyph.browser
                ),
            ])

            // The one thing on this page that is a question rather than a record. `.glass` is a
            // system style, so what it draws for a `.button` toggle's ON state is Apple's decision
            // and not ours, and the whole reason the control used to be `.accessoryBar` was to keep
            // that state off the saturated accent. Both states, side by side, is the answer.
            row(
                "The inspector toggle, hidden and shown",
                tabs: [fixture("Chat", PaneGlyph.chat, active: true), fixture("Terminal", PaneGlyph.terminal)],
                inspectorVisible: false
            )
            row(
                "The same strip with the inspector open",
                tabs: [fixture("Chat", PaneGlyph.chat, active: true), fixture("Terminal", PaneGlyph.terminal)],
                inspectorVisible: true
            )

            VStack(alignment: .leading, spacing: 8) {
                caption("The three glyphs at the size they are read at")
                HStack(spacing: 20) {
                    ForEach([PaneGlyph.chat, PaneGlyph.terminal, PaneGlyph.browser], id: \.self) {
                        Image(systemName: $0)
                            .imageScale(.small)
                            .font(Typo.label)
                            .foregroundStyle(Palette.textPrimary)
                    }
                }
                .padding(.horizontal, Metrics.inset)
                .frame(height: Metrics.barHeight)
                .background(Palette.surface)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(app)
    }

    /// Long enough to run past a tab's 200 points several times over, so the picture shows what
    /// the strip does with one rather than what a comfortable title does.
    private static let longTitle =
        "WKWebView | Apple Developer Documentation | Displaying web content in a view"

    private func row(_ title: String, tabs: [Fixture], inspectorVisible: Bool? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            caption(title)
            StripRow(tabs: tabs, inspectorVisible: inspectorVisible)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Typo.label)
            .foregroundStyle(Palette.textSecondary)
    }

    private func fixture(_ title: String, _ icon: String, active: Bool = false) -> Fixture {
        Fixture(title: title, icon: icon, isActive: active)
    }
}

/// One strip, with a selection namespace of its own.
///
/// A view rather than a function, because `matchedGeometryEffect` matches within one namespace and
/// the page holds five strips: sharing one left the selected fill in whichever strip drew it last
/// and the other four reading as though nothing in them were selected.
private struct StripRow: View {
    var tabs: [Fixture]
    /// Whether the strip ends in the inspector's toggle, and which way it is thrown. Nil for the
    /// rows that are about the tabs.
    var inspectorVisible: Bool?

    @Namespace private var selection

    var body: some View {
        // The real `TabStrip`, not a row of tabs laid out by hand: it is the scroller that gives
        // each tab its ideal width rather than a share of the row, so a strip drawn any other way
        // shows every tab at the 200 point cap and says nothing about how wide these titles are.
        TabStrip(pane: .content) {
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                    if index > 0 {
                        TabStripSeparator(isHidden: tab.isActive || tabs[index - 1].isActive)
                    }
                    item(tab, isFirst: index == 0)
                }
            }
        } append: {
            EmptyView()
        } trailing: {
            if let inspectorVisible {
                TabStripSeparator()
                InspectorToggle(isVisible: .constant(inspectorVisible))
            }
        }
        .frame(width: 620)
        .background(Palette.surface)
    }

    private func item(_ fixture: Fixture, isFirst: Bool) -> some View {
        TabItemView(
            title: fixture.title,
            icon: fixture.icon,
            isActive: fixture.isActive,
            isAtPaneEdge: isFirst,
            surface: TabPane.content.surface,
            isRenaming: false,
            editableTitle: fixture.title,
            canClose: true,
            closeTitle: "Close",
            onSelect: {},
            onStartRename: {},
            onCommitRename: { _ in },
            onCancelRename: {},
            onClose: {},
            namespace: selection
        )
    }
}

private struct Fixture {
    var title: String
    var icon: String
    var isActive: Bool
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// No field on this page: every tab on it is drawn as a label.
    static let paneTabs = Gallery(
        name: "pane-tabs",
        title: "Pane tabs",
        size: CGSize(width: 700, height: 880),
        needsFocus: false,
        view: { app in AnyView(PaneTabsGallery(app: app)) }
    )
}
