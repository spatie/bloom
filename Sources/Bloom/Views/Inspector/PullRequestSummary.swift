import SwiftUI
import AppKit
import BloomCore

/// The strip when a pull request already exists: its number, how CI feels about it, and the one
/// button that finishes the job.
///
/// Reading left to right it is the same order as the question a user is asking: which pull
/// request is this, where do I read it, what is wrong with it, and can I land it. The chip, the
/// sentence and the merge button all take the state's colour, and `PullRequestBar` washes the bar
/// behind them with it, because a red bar at the top of the inspector is visible from across the
/// room and a red word is not.
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

    /// gh deletes the branch on the remote as part of merging. It is named in the confirmation
    /// rather than left as a surprise.
    private static let deletesBranch = true

    private var status: PullRequestStatus { pullRequest.status }

    var body: some View {
        HStack(spacing: InspectorLayout.gap) {
            numberChip
            openButton

            if pullRequest.isDraft {
                Chip(text: "Draft")
            }

            // The one thing in the strip that can be any length, so it is the one that gives way.
            // A flexible frame rather than a `Spacer` and a negative layout priority: it takes
            // whatever width is left and truncates inside it, which is a rule the layout cannot
            // resolve any other way, instead of a preference it weighs against the button's.
            Text(sentence)
                .font(Typo.caption)
                .foregroundStyle(tint ?? Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(sentence)

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Merging")
            } else if pullRequest.isOpen {
                mergeButton
            } else {
                Chip(text: status.text)
            }
        }
        // Sharing lives here rather than as another control in the strip. The strip has one length
        // that can give way and it is already the sentence, so a button added to it comes out of
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

    /// What the strip says in the middle. A closed or merged pull request has its state on the
    /// chip at the end of the strip already, so the sentence spends its width on the title
    /// instead of saying "Merged" twice.
    private var sentence: String {
        pullRequest.isOpen ? status.text : pullRequest.title
    }

    // MARK: - Parts

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
    private var openButton: some View {
        Button("Open on GitHub", systemImage: "arrow.up.forward.app") {
            GitHubBridge.open(pullRequest.url)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Open #\(pullRequest.number) on GitHub")
    }

    /// The one prominent control in the inspector, and the only solid colour in the strip.
    ///
    /// A real `Button` rather than a `Menu` with a primary action. A menu styled `.button` ignores
    /// `.borderedProminent` and the tint under it on this SDK and comes out as the same neutral
    /// capsule as every other control in the bar, which is exactly the signal this control exists
    /// to carry. The other two methods moved to the chevron beside it, which stays a menu and stays
    /// quiet because it is not the thing being pointed at.
    ///
    /// The fill is the state's colour rather than the accent, so the strip is one decision from end
    /// to end: failing checks do not block merging, so a red bar has to end in a red button.
    ///
    /// Every path through it opens the confirmation. The button proposes a squash merge because
    /// that is what it says; nothing here ever performs one.
    private var mergeButton: some View {
        HStack(spacing: Metrics.spacingTight) {
            Button("Merge", systemImage: "arrow.triangle.merge") { pendingMerge = .squash }
                .buttonStyle(.borderedProminent)
                .tint(tint ?? Palette.accent)

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
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(!status.canMerge)
        // Disabled controls do not explain themselves, and "why is this greyed out" is the whole
        // question a blocked pull request raises.
        .help(status.blockedReason ?? "Squash and merge, or choose another method")
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
