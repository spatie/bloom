import SwiftUI
import BloomCore

/// The usage panel: a dashboard of every provider's limits, a Customize screen and a Settings
/// screen, with a footer that counts down to the next ask.
///
/// **Drawn after OpenUsage, deliberately and closely.** The owner asked for this panel to look like
/// that app's and to do what it does, so the geometry is its geometry (320 points wide, cards with
/// a 12 point radius on the text background, capsule meters coloured by pace rather than by level)
/// and the words are its words. Where Bloom has something OpenUsage does not, the workspaces and
/// the Keep Awake session, it is drawn in the same card language rather than in Bloom's window
/// palette, because this is one surface and has to read as one.
///
/// The height is the content's: this view reports how tall it would like to be and
/// `UsagePanelController` sizes the window to that, clamped to the screen, so the panel grows and
/// shrinks with what is in it and scrolls only once it runs out of room.
struct UsagePanelView: View {
    static let width: CGFloat = 320
    nonisolated static let coordinateSpace = "usagePanel"
    static let topBarHeight: CGFloat = 44

    let app: AppModel
    let model: UsagePanelModel
    let reportHeight: @MainActor (CGFloat) -> Void

    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if model.screen != .dashboard {
                UsagePanelTopBar()
            }
            ScrollView {
                screen
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            if model.screen != .customize {
                UsagePanelFooter(app: app)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(UsageInk.tray)
        .overlay(alignment: .bottom) { pill }
        .overlay { UsageTooltipLayer(tooltip: model.tooltip) }
        .coordinateSpace(.named(Self.coordinateSpace))
        .environment(model)
        .environment(\.usageScale, UsageScale.of(model.density))
        .onChange(of: idealHeight, initial: true) { _, height in reportHeight(height) }
    }

    private var idealHeight: CGFloat {
        (model.screen == .dashboard ? 0 : Self.topBarHeight)
            + contentHeight
            + (model.screen == .customize ? 0 : footerHeight)
    }

    @ViewBuilder
    private var screen: some View {
        ZStack(alignment: .top) {
            switch model.screen {
            case .dashboard:
                UsagePanelDashboard(app: app)
                    .transition(slide)
            case .customize:
                if let provider = model.customizing {
                    UsageCustomizeProviderView(app: app, provider: provider)
                        .id(provider)
                        .transition(slide)
                } else {
                    UsageCustomizeListView(app: app)
                        .transition(slide)
                }
            case .settings:
                UsageSettingsView()
                    .transition(slide)
            }
        }
    }

    private var slide: AnyTransition {
        .push(from: model.isMovingForward ? .trailing : .leading)
    }

    @ViewBuilder
    private var pill: some View {
        if let pill = model.pill {
            HStack(spacing: 5) {
                Image(systemName: pill.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(pill.text)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(pill.isWarning ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .padding(.bottom, footerHeight + 10)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
            .id(pill.id)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// The dashboard, fed from the app model and redrawn every thirty seconds so every countdown in
/// it moves without anybody touching it.
struct UsagePanelDashboard: View {
    let app: AppModel
    @Environment(UsagePanelModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            UsageDashboardView(
                metrics: UsageCatalogue.metrics(quotas: app.quotas, accounts: app.accounts, at: context.date),
                accounts: app.accounts,
                observedAt: UsageDashboardView.oldestReadings(app.quotas),
                isRefreshing: app.isAskingForQuotas,
                agentSections: MenuBarSummary.sections(
                    in: app.workspaces,
                    isRunning: { app.isRunning($0) },
                    isAwaitingPermission: { app.isAwaitingPermission($0) }
                ),
                runningCount: app.runningAgentCount,
                now: context.date,
                onOpenWorkspace: { id in
                    model.dismiss()
                    MainWindow.raise()
                    OpenWorkspaceNotification.post(id)
                }
            )
        }
    }
}

/// The bar across the top of Customize and Settings: back, the title, and a reset where there is
/// something to reset.
struct UsagePanelTopBar: View {
    @Environment(UsagePanelModel.self) private var model
    @State private var confirmsReset = false

    var body: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 0) {
                Button {
                    model.back()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .usageTooltip("Back")

                Spacer(minLength: 8)

                if model.screen == .customize {
                    resetButton
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: UsagePanelView.topBarHeight)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: Rectangle())
        .alert("Reset All Customization?", isPresented: $confirmsReset) {
            Button("Reset All", role: .destructive) { model.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turns every provider back on and resets its metrics, order and stars. Are you sure?")
        }
    }

    private var title: String {
        switch model.screen {
        case .dashboard: "Usage"
        case .customize: model.customizing?.label ?? "Customize"
        case .settings: "Settings"
        }
    }

    private var resetButton: some View {
        Button {
            if let provider = model.customizing {
                withAnimation(UsageMotion.spring) { model.update { $0.reset(provider) } }
            } else {
                confirmsReset = true
            }
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .usageTooltip(model.customizing.map { "Reset \($0.label)" } ?? "Reset All Customization")
    }
}
