import SwiftUI
import AppKit
import BloomCore

/// The strip when a pull request already exists: which one it is, what state it is in, and the one
/// button that finishes the job.
///
/// Reading left to right it is the same order as the question a user is asking: which pull
/// request is this, where do I read it, what is going on with it, and can I land it.
///
/// The headline is the STATE and not the title. The title is the workspace's name a few points to
/// the left and is on GitHub besides, while the state is the thing that changes, the thing you are
/// waiting for and the thing that says whether to press the button. It used to be the other way
/// round, with the state reduced to a grey capsule at the trailing edge, and the strip read as a
/// caption for something rather than as the top of the column.
///
/// The chip, the headline and the merge button all take the state's colour, and `PullRequestBar`
/// washes the bar behind them with it, because a red bar at the top of the inspector is visible
/// from across the room and a red word is not.
struct PullRequestSummary: View {
    var pullRequest: PullRequest
    var baseBranch: String
    var isWorking: Bool
    var onMerge: (GitHub.MergeMethod) -> Void

    /// Which method the user picked, held only for as long as the confirmation is up. Non-nil is
    /// what presents the dialog, so there is no way to reach `onMerge` without passing through it.
    @State private var pendingMerge: GitHub.MergeMethod?

    /// Non-nil for as long as it takes the sharing menu to open. See `SharePicker`.
    @State private var sharing: SharePayload?

    /// Merging deletes the branch on GitHub and nothing on this machine. It is named in the
    /// confirmation rather than left as a surprise. See `GitHub.merge` for why the local half of
    /// gh's own clean up is never asked for.
    private static let deletesBranch = true

    private var status: PullRequestStatus { pullRequest.status }

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            identity
            headline
            trailing
        }
        // Sharing lives here rather than as another control in the strip. The strip has one length
        // that can give way and it is already the headline, so a button added to it comes out of
        // the part the reader is trying to read. A right click costs no width at all, and it is
        // where a link is asked for everywhere else on this system.
        .contextMenu {
            Button("Open on GitHub") { GitHubBridge.open(pullRequest.url) }
            Button("Copy link", action: copyLink)
            if let url = URL(string: pullRequest.url) {
                Button("Share") { sharing = .link(url) }
            }
        }
        .sharePicker(payload: $sharing)
        // Attached to the merge button's own row, so the dialog animates out of the control that
        // asked for it.
        .confirmationDialog(
            pullRequest.mergeConfirmationTitle(base: baseBranch),
            isPresented: $pendingMerge.isPresent(),
            titleVisibility: .visible,
            presenting: pendingMerge
        ) { method in
            Button(method.label, role: .destructive) { onMerge(method) }
            Button("Keep the pull request open", role: .cancel) { pendingMerge = nil }
                .keyboardShortcut(.defaultAction)
        } message: { method in
            // Naming the pull request, the branch and the base, rather than asking "are you
            // sure?". Nothing in Bloom can put any of it back afterwards.
            Text(
                pullRequest.mergeConfirmation(
                    method: method, base: baseBranch, deletesBranch: Self.deletesBranch
                )
            )
        }
    }

    // MARK: - Parts

    /// The number and the way out to the browser, drawn as one cluster. They are the same subject,
    /// so they sit a tight gap apart rather than at the strip's own spacing.
    private var identity: some View {
        HStack(spacing: InspectorLayout.tight) {
            numberChip
            openButton
        }
        .fixedSize()
    }

    private var numberChip: some View {
        // The number alone. A pull request glyph here repeats what the arrow button beside it and
        // the whole column around it already say, and the chip is meant to be read at a glance as
        // an identifier rather than parsed as a badge.
        Chip(
            text: "#\(pullRequest.number)",
            tint: tint ?? Palette.accent,
            background: (tint ?? Palette.accent).opacity(InspectorLayout.tintOpacityStrong)
        )
        .help(pullRequest.title)
        .accessibilityLabel("Pull request \(pullRequest.number), \(pullRequest.title)")
    }

    /// A separate control rather than making the chip itself clickable: the chip is the label of
    /// the strip, and a label that silently launches a browser is the kind of thing people learn
    /// by accident.
    ///
    /// Opening a page in a browser needs no GitHub sign in of any kind, so this control is never
    /// gated on `gh`.
    private var openButton: some View {
        Button("Open on GitHub", systemImage: "arrow.up.forward.app") {
            GitHubBridge.open(pullRequest.url)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Open #\(pullRequest.number) on GitHub")
    }

    /// The state, in the state's colour, with its numbers under it.
    ///
    /// A flexible frame rather than a `Spacer` and a negative layout priority: this is the one
    /// thing in the strip that can be any length, so it takes whatever width is left and truncates
    /// inside it, which is a rule the layout cannot resolve any other way.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(status.text)
                .font(Typo.captionEmphasis)
                .foregroundStyle(tint ?? Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let detail = status.detail {
                Text(detail)
                    .font(Typo.micro)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var trailing: some View {
        if isWorking {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Merging")
        } else if pullRequest.isOpen {
            mergeButton
        }
        // A merged or closed pull request needs no control here. The headline says which of the
        // two it is and the strip carries its colour, so a capsule repeating the same word was
        // only ever taking the place of the button that used to be there.
    }

    /// The one prominent control in the inspector, and the only solid colour in the strip.
    ///
    /// A real `Button` rather than a `Menu` with a primary action. A menu styled `.button` ignores
    /// `.borderedProminent` and the tint under it on this SDK and comes out as the same neutral
    /// capsule as every other control in the bar, which is exactly the signal this control exists
    /// to carry. The other two methods moved to the chevron beside it, which stays a menu and stays
    /// quiet because it is not the thing being pointed at.
    ///
    /// Always explicitly tinted. An untinted `.borderedProminent` follows the SYSTEM accent on
    /// this platform, which is whatever blue or pink the user set in General, and on macOS 26 it
    /// renders as a grey glass capsule instead. Both are wrong: the fill is the state's own
    /// colour, so the strip is one decision from end to end and a red bar ends in a red button.
    /// Failing checks do not block merging, which is the whole reason that has to hold.
    ///
    /// Every path through it opens the confirmation. The button proposes a squash merge because
    /// that is what it says; nothing here ever performs one.
    private var mergeButton: some View {
        HStack(spacing: Metrics.spacingTight) {
            Button("Merge", systemImage: "arrow.triangle.merge") { pendingMerge = .squash }
                .buttonStyle(.borderedProminent)
                .tint(tint ?? Palette.accentFill)
                .controlSize(.regular)

            Menu {
                ForEach(GitHub.MergeMethod.allCases, id: \.self) { method in
                    Button(method.label) { pendingMerge = method }
                }
            } label: {
                Label("Choose a merge method", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(Palette.textSecondary)
            .controlSize(.small)
        }
        .fixedSize()
        .disabled(!status.canMerge)
        // Disabled controls do not explain themselves, and "why is this greyed out" is the whole
        // question a blocked pull request raises.
        .help(status.blockedReason ?? "Squash and merge, or choose another method")
    }

    // MARK: - Text

    /// The title belongs somewhere, and a tooltip on the state is where: it answers "which pull
    /// request is this" without spending any of the strip's width on an answer the reader already
    /// has from the workspace name.
    private var helpText: String {
        var text = "#\(pullRequest.number) \(pullRequest.title)"
        if let detail = status.detail { text += "\n\(detail)" }
        if let reason = status.blockedReason { text += "\n\(reason)" }
        return text
    }

    private var accessibilityText: String {
        [status.text, status.detail].compactMap { $0 }.joined(separator: ", ")
    }

    private func copyLink() {
        Clipboard.copy(pullRequest.url)
    }

    // MARK: - Tint

    /// The same colour `PullRequestBar` washes the strip with, so the parts and the bar under
    /// them cannot drift apart.
    private var tint: Color? {
        status.tone.color
    }
}
