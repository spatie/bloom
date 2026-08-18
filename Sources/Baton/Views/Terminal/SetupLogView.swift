import SwiftUI
import BatonCore

/// The output of the repo's setup script.
///
/// Setup is the first thing that runs in a new workspace and the first thing that breaks, so this
/// tab shows the raw log rather than a summary, and stays out of the way once it has succeeded.
struct SetupLogView: View {
    @Bindable var model: WorkspaceModel

    @State private var lastRunSucceeded: Bool?

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            LogOutputView(text: model.setupOutput, isFollowing: model.isRunningSetup)
        }
        .background(Palette.surfaceSunken)
    }

    private var header: some View {
        HStack(spacing: Metrics.spacing) {
            statusIcon
            Text(statusText)
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textSecondary)

            Spacer(minLength: Metrics.spacing)

            Button(model.isRunningSetup ? "Running" : "Run setup again") {
                Task { await runSetup() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isRunningSetup || model.repo == nil)
            .help("Run this repository's setup script in the workspace again")
        }
        .padding(.horizontal, Metrics.gutter)
        // The fixed height the tab strip above it uses, rather than padding around whichever
        // control happens to be tallest, so the two bars line up whatever the tab is showing.
        .frame(height: Metrics.barHeight)
        .headerMaterial()
    }

    @ViewBuilder
    private var statusIcon: some View {
        if model.isRunningSetup {
            LoadingView()
        } else if succeeded {
            Image(systemName: "checkmark.circle.fill")
                .font(Typo.label)
                .foregroundStyle(Palette.positive)
        } else if failed {
            Image(systemName: "xmark.circle.fill")
                .font(Typo.label)
                .foregroundStyle(Palette.negative)
        } else {
            Image(systemName: "wrench.and.screwdriver")
                .font(Typo.label)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var succeeded: Bool {
        lastRunSucceeded ?? (model.workspace.setupState == .succeeded)
    }

    private var failed: Bool {
        if let lastRunSucceeded { return !lastRunSucceeded }
        return model.workspace.setupState == .failed
    }

    private var statusText: String {
        if model.isRunningSetup { return "Running setup" }
        if succeeded { return "Setup finished" }
        if failed { return "Setup failed" }
        return "Setup has not run yet"
    }

    /// Runs the script through the same `WorkspaceManager` path the first run uses, so the state
    /// and the stored log stay consistent with what happened at workspace creation.
    private func runSetup() async {
        guard let repo = model.repo, let store = model.store, !model.isRunningSetup else { return }

        model.isRunningSetup = true
        model.setupOutput = ""
        lastRunSucceeded = nil
        if model.port == 0 { model.port = (try? PortAllocator.allocate(taken: [])) ?? 0 }

        let manager = WorkspaceManager(store: store)

        // Batched for the same reason the first run is: a line at a time on the main actor is
        // enough to beachball the window on a verbose script. See `WorkspaceModel.appendSetupOutput`.
        let buffer = LineBuffer()
        let flusher = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                model.appendSetupOutput(buffer.drain())
            }
        }

        let succeeded = await manager.runSetup(
            workspace: model.workspace, repo: repo, port: model.port
        ) { line in
            buffer.append(line)
        }

        flusher.cancel()
        model.appendSetupOutput(buffer.drain())
        model.isRunningSetup = false
        lastRunSucceeded = succeeded
    }
}

/// The log surface shared by the Setup and Run tabs: monospaced, selectable, and pinned to the
/// bottom while something is still writing to it.
///
/// Lines are not wrapped. This is the output of the same shell the terminal in the next tab is
/// running, and a script that draws a table, a progress bar or a stack trace with aligned columns
/// has all of it folded into nonsense by a soft wrap. Scrolling sideways is what a log viewer
/// does, and it is what the tab beside this one does.
struct LogOutputView: View {
    var text: String
    var isFollowing: Bool
    var placeholder: String = "No output yet."

    private static let bottomAnchor = "baton.log.bottom"

    var body: some View {
        Group {
            if text.isEmpty {
                // Prose rather than output, so it is set in the app's own text rather than dressed
                // up as something the script printed, and it starts where the first line of a real
                // log would rather than in the middle of the pane.
                Text(placeholder)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textTertiary)
                    .gutter()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                log
            }
        }
        .background(Palette.surfaceSunken)
    }

    private var log: some View {
        // The viewport width, so a log whose longest line is shorter than the pane still starts at
        // the left edge. Content narrower than a scroll view that scrolls in both directions is
        // centred in it, which is what put a short log in the middle of the panel.
        GeometryReader { proxy in
            ScrollViewReader { anchor in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        // The same size the terminal in the next tab draws at, because two tabs of
                        // the same panel printing the same kind of output at two sizes reads as a
                        // bug.
                        Text(text)
                            .font(Typo.code)
                            .lineSpacing(Metrics.spacingTight)
                            .foregroundStyle(Palette.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .gutter()

                        // Outside the gutter on purpose: this is what the follow scrolls to, and
                        // an anchor indented by the gutter puts the gutter off the left edge.
                        Color.clear
                            .frame(width: Metrics.hairline, height: Metrics.hairline)
                            .id(Self.bottomAnchor)
                    }
                    .frame(
                        minWidth: proxy.size.width,
                        minHeight: proxy.size.height,
                        alignment: .topLeading
                    )
                }
                // Bottom left, not bottom. A scroll view that scrolls in both directions follows
                // both, so `.bottom` alone dragged the view to the right-hand end of the longest
                // line every time a line arrived, and the log was read from its last column.
                .onChange(of: text) {
                    guard isFollowing else { return }
                    anchor.scrollTo(Self.bottomAnchor, anchor: .bottomLeading)
                }
                .onAppear {
                    anchor.scrollTo(Self.bottomAnchor, anchor: .bottomLeading)
                }
            }
        }
    }
}

private extension View {
    /// The gutter the bar above the log uses, so the first character of a line starts on the same
    /// edge as the status beside it. It was six points, against the bar's twelve.
    func gutter() -> some View {
        padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.spacingWide)
    }
}
