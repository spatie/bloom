import SwiftUI
import BloomCore

/// Where the work comes from: an open pull request, a branch somebody has already written on, or a
/// fresh branch cut off a base.
///
/// It replaced a `Menu` that listed "New branch from <name>" for every branch in the project and
/// filed "Open an existing branch" under all of them, with no way to search. A colleague's branch
/// was picked out of the top of that list, which cut a new branch off their head, and the
/// workspace came up empty with its Changes tab saying nothing differed.
///
/// The first fix drew the two verbs as two sections of one scrolling list, so the choice could be
/// made with both answers in view. That was right about the choice and wrong about the search. The
/// owner went looking for a branch to carry on, typed its name, and did not recognise the row he
/// got: half the offering was below the fold, the headings scrolled away, and the row that matched
/// was named after a pull request title rather than after the branch he had typed. So the sections
/// are tabs now, each carrying a sentence that says where a commit ends up, which is the only real
/// difference between them and the thing neither heading ever said. The other half of that fix is
/// `WorkspaceSource.name`, which names a pull request after the branch it lands on.
///
/// A `.popover` rather than a `Menu`, and not by preference. An `NSMenu` cannot contain a text
/// field, so a menu with a search box in it is not a thing macOS has; the panel is the app's own
/// filtered list instead, the one `FileMentionMenu` draws over the composer, with the same arrow
/// keys, the same Return and the same empty line when nothing matches.
struct WorkspaceSourcePicker: View {
    var offering: WorkspaceSourceOffering
    /// What is chosen now, which is what the button reports. Nil is the sheet's own route: a new
    /// branch off `baseBranch`.
    var checkout: WorkspaceCheckout?
    var baseBranch: String
    /// Why there are no pull requests, when there are none. Drawn at the foot of the panel rather
    /// than as a row, because "Sign in with gh" is not something to arrow onto and press Return on.
    var unavailable: String?
    var onPick: @MainActor (WorkspaceSource) -> Void

    @State private var isPresented = false
    @State private var query = ""
    /// Which verb is on screen. Opened on the tab the current choice belongs to, so a panel
    /// reopened after picking a pull request does not start by hiding it.
    @State private var tab: WorkspaceSourceTab = .newBranch
    /// The highlighted row, held as the row itself and never as an index into the list. A ranked
    /// list reorders under every keystroke, so an index highlights whatever has since moved into
    /// that slot and Return opens something other than what is drawn. `FileMentionMenu` carries
    /// the same note over the same failure.
    @State private var selected: WorkspaceSource?

    /// Wide enough for a pull request title beside its author without either being cut, which is
    /// what the old menu's 52 character truncation was working around.
    private static let width: CGFloat = 460
    /// Taller than `MenuLayout.maxHeight`, which is the cap a completion menu keeps because it
    /// floats over the composer it is filtering. This one hangs off a control at the top of a
    /// sheet with nothing underneath it worth reading, and it is a list people scan rather than a
    /// glance, so it gets about eleven rows instead of eight.
    private static let listHeight: CGFloat = 320

    private var matches: WorkspaceSourceMatches {
        offering.search(query: query)
    }

    private var label: String {
        WorkspaceSource.label(for: checkout, baseBranch: baseBranch)
    }

    /// The same three marks the rows carry, so the control shows the row that was picked. Cutting
    /// a new branch had the branch mark too, which left "from main" and "on main" telling the two
    /// apart on one word and no other difference at all.
    private var glyph: String {
        switch checkout {
        case .pullRequest: "arrow.triangle.pull"
        case .branch: "arrow.triangle.branch"
        case .none: "plus.circle"
        }
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            ComposerControlLabel(
                systemImage: glyph,
                text: label,
                isActive: isPresented,
                showsMenuIndicator: true
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Open a pull request or a branch, or cut a new branch")
        .accessibilityLabel("Start from")
        .accessibilityValue(label)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            panel
        }
    }

    private var panel: some View {
        // Ranked once for the whole pass, and everything below draws from that one value. The
        // panel asks several questions of it (is this tab empty, what goes in the list) and a
        // ranking run per question is the same list computed over a repository's worth of branches
        // several times, on every keystroke.
        let matches = self.matches
        return VStack(alignment: .leading, spacing: 0) {
            tabs
            explanation
            Hairline()
            searchRow
            Hairline()

            if matches.isEmpty(in: tab) {
                MenuEmptyRow(
                    text: query.isEmpty ? emptyTabText : "Nothing matches \(query)"
                )
            } else {
                list(matches)
            }

            if let unavailable, tab == .existingBranch {
                Hairline()
                Text(unavailable)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, Metrics.spacingWide)
            }
        }
        .frame(width: Self.width)
        .background { tabShortcuts }
        // A fresh query every time it opens. The panel is a way of finding one thing, not a filter
        // somebody set and left, and reopening it onto yesterday's word would hide the list that
        // has since loaded behind it.
        .onAppear {
            query = ""
            tab = checkout == nil ? .newBranch : .existingBranch
            selected = offering.search(query: "").rows(in: tab).first
        }
    }

    /// `PanelTabs` rather than a segmented picker, and its own note carries the three measurements
    /// that bought it. The one that shows here is the inset: `Metrics.gutter`, the same margin the
    /// sentence under it and the search row below that already keep, so the strip starts and ends
    /// on the panel's own lines. The segmented control could not do that at any inset, because it
    /// sized to its two labels and this stack aligns leading, which is what left it short of the
    /// right edge with a gap after it.
    private var tabs: some View {
        PanelTabs("Start from", tabs: WorkspaceSourceTab.allCases, selection: $tab) { $0.title }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, Metrics.spacingWide)
        .padding(.bottom, Metrics.spacingWide)
        .onChange(of: tab) { _, _ in
            // The highlight cannot stay in a tab nobody can see, so it settles into the new one.
            selected = matches.settled(after: selected, in: tab)
        }
    }

    private var explanation: some View {
        Text(tab.explanation)
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.spacingWide)
    }

    /// What an empty tab says, which differs because the two are empty for different reasons.
    private var emptyTabText: String {
        switch tab {
        case .newBranch: "No branches to start from yet"
        case .existingBranch: "No branches or pull requests to carry on yet"
        }
    }

    private var searchRow: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(Palette.textTertiary)

            MenuSearchField(
                text: $query,
                placeholder: tab.searchPlaceholder,
                onKey: handle(key:)
            )
            .frame(height: Metrics.rowHeight)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spacingSmall)
        .onChange(of: query) { _, _ in
            // The highlight follows the list rather than staying where it was: a highlight left
            // pointing at a row the new query filtered out is a Return that does nothing.
            selected = matches.settled(after: selected, in: tab)
        }
    }

    private func list(_ matches: WorkspaceSourceMatches) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches.rows(in: tab)) { row in
                        WorkspaceSourceRow(
                            source: row,
                            isSelected: row == selected,
                            onPick: { pick(row) },
                            onHover: { selected = row }
                        )
                        // Identity is the thing the row names, never its position. See `selected`.
                        .id(row.id)
                    }
                }
                .padding(Metrics.spacingSmall)
            }
            .frame(maxHeight: Self.listHeight)
            .onChange(of: selected) { _, row in
                guard let row else { return }
                proxy.scrollTo(row.id)
            }
        }
    }

    // MARK: - Keys

    /// Switching tab from the keyboard, on the keys macOS already uses for it.
    ///
    /// **Not the left and right arrows**, which was the first idea and is wrong: this panel has a
    /// search field, and in a text field those two move the insertion point. Claiming them would
    /// break correcting a typo in the very query the tabs exist to serve. Command+Shift+[ and
    /// Command+Shift+] are what Safari and Terminal use to move between tabs, and being command
    /// equivalents they reach the panel while the field holds the keyboard, which the arrows can
    /// only do by being taken away from the caret first.
    ///
    /// Drawn in a `.background` and never seen. A button is how SwiftUI registers a key equivalent
    /// for a window, and this one has nothing to show: the hint at the foot of the panel is what
    /// tells anybody the keys exist.
    private var tabShortcuts: some View {
        ZStack {
            Button("Previous tab") { tab = tab.stepped(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next tab") { tab = tab.stepped(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// The panel's whole keyboard. Where the highlight lands is `WorkspaceSourceMatches`, in the
    /// core, because it is a decision and a decision taken in a view is one nothing can test.
    private func handle(key: ComposerKey) -> Bool {
        switch key {
        case .up:
            selected = matches.stepped(from: selected, by: -1, in: tab)
            return true
        case .down:
            selected = matches.stepped(from: selected, by: 1, in: tab)
            return true
        case .returnKey, .commandReturn:
            guard let selected else { return false }
            pick(selected)
            return true
        case .escape:
            isPresented = false
            return true
        case .tab:
            return false
        }
    }

    private func pick(_ source: WorkspaceSource) {
        isPresented = false
        onPick(source)
    }
}
