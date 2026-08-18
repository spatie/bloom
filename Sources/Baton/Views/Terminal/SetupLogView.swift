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
        HStack(spacing: Metrics.corner) {
            statusIcon
            Text(statusText)
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textSecondary)

            Spacer(minLength: Metrics.corner)

            Button(model.isRunningSetup ? "Running" : "Run setup again") {
                Task { await runSetup() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isRunningSetup || model.repo == nil)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.cornerSmall)
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
        let succeeded = await manager.runSetup(
            workspace: model.workspace, repo: repo, port: model.port
        ) { line in
            Task { @MainActor in
                model.setupOutput += line + "\n"
            }
        }

        model.isRunningSetup = false
        lastRunSucceeded = succeeded
    }
}

/// The log surface shared by the Setup and Run tabs: monospaced, selectable, and pinned to the
/// bottom while something is still writing to it.
struct LogOutputView: View {
    var text: String
    var isFollowing: Bool
    var placeholder: String = "No output yet."

    private static let bottomAnchor = "baton.log.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? placeholder : text)
                        .font(Typo.codeSmall)
                        .foregroundStyle(text.isEmpty ? Palette.textTertiary : Palette.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Metrics.gutter)
                        .padding(.vertical, Metrics.corner)

                    Color.clear
                        .frame(height: Metrics.hairline)
                        .id(Self.bottomAnchor)
                }
            }
            .onChange(of: text) {
                guard isFollowing else { return }
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surfaceSunken)
    }
}
