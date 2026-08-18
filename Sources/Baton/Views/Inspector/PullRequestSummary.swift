import SwiftUI
import BatonCore

/// The strip when a pull request already exists: its number, how CI feels about it, and the one
/// button that finishes the job.
///
/// Reading left to right it is the same order as the question a user is asking: which pull
/// request is this, where do I read it, what is wrong with it, and can I land it. The whole strip
/// carries the state's colour rather than only the sentence, because a red bar at the top of the
/// inspector is visible from across the room and a red word is not.
struct PullRequestSummary: View {
    var pullRequest: PullRequest
    var baseBranch: String
    var isWorking: Bool
    var onMerge: (GitHub.MergeMethod) -> Void

    /// Which method the user picked, held only for as long as the confirmation is up. Non-nil is
    /// what presents the dialog, so there is no way to reach `onMerge` without passing through it.
    @State private var pendingMerge: GitHub.MergeMethod?

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
        .background(alignment: .center) { tintWash }
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
        } message: { method in
            // Naming the pull request, the branch and the base, rather than asking "are you
            // sure?". Nothing in Baton can put any of it back afterwards.
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
        Chip(
            text: "#\(pullRequest.number)",
            systemImage: "arrow.triangle.pull",
            tint: tint ?? Palette.accent,
            background: (tint ?? Palette.accent).opacity(InspectorLayout.tintOpacity)
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

    /// The one prominent control in the inspector. It is a real bordered prominent button, so it
    /// carries the user's accent colour and the pressed and disabled states that come with it,
    /// rather than a rectangle painted to look like a button.
    ///
    /// Every path through it opens the confirmation. The primary action is a squash merge because
    /// that is what the button says, but it still only proposes it.
    private var mergeButton: some View {
        Menu {
            ForEach(GitHub.MergeMethod.allCases, id: \.self) { method in
                Button(method.label) { pendingMerge = method }
            }
        } label: {
            Label("Merge", systemImage: "arrow.triangle.merge")
        } primaryAction: {
            pendingMerge = .squash
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize()
        .disabled(!status.canMerge)
        // Disabled controls do not explain themselves, and "why is this greyed out" is the whole
        // question a blocked pull request raises.
        .help(status.blockedReason ?? "Squash and merge, or choose another method")
    }

    // MARK: - Tint

    /// Nil for the neutral state, so a pull request with nothing to report is a plain strip rather
    /// than a grey wash. Every colour comes from the palette, so it tracks appearance and contrast.
    private var tint: Color? {
        switch status.tone {
        case .neutral: nil
        case .positive: Palette.positive
        case .negative: Palette.negative
        case .warning: Palette.warning
        case .accent: Palette.accent
        }
    }

    /// The strip's own background, grown back out to the edges of the pane that insets it, so the
    /// state reads as a bar across the top of the inspector rather than as a card floating in one.
    @ViewBuilder
    private var tintWash: some View {
        if let tint {
            tint.opacity(InspectorLayout.tintOpacity)
                .frame(height: InspectorLayout.barHeight)
                .padding(.horizontal, -InspectorLayout.inset)
                .accessibilityHidden(true)
        }
    }
}
