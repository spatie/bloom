import SwiftUI
import BatonCore

/// The three column layout: workspace list, the session, and the inspector.
///
/// Deliberately not `NavigationSplitView`. That control owns its own sidebar chrome, animation
/// and collapse behaviour, and fighting it costs more than laying out three panes by hand does.
struct RootView: View {
    @Environment(AppModel.self) private var app

    @State private var sidebarWidth: CGFloat = Metrics.sidebarWidth
    @State private var inspectorWidth: CGFloat = Metrics.inspectorWidth
    @State private var isSidebarVisible = true
    @State private var isCreateSheetPresented = false
    @State private var createTargetRepo: Repo?

    var body: some View {
        GeometryReader { proxy in
            layout(containerWidth: proxy.size.width)
        }
        .background(Palette.windowBackground)
        .animation(.easeOut(duration: 0.16), value: isSidebarVisible)
        .animation(.easeOut(duration: 0.16), value: app.selectedModel?.isInspectorVisible)
        .task { await app.bootstrap() }
        .sheet(isPresented: $isCreateSheetPresented) {
            CreateWorkspaceSheet(initialRepo: createTargetRepo)
        }
        .alert(item: alertBinding) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .batonOpenWorkspace)) { note in
            if let id = note.object as? String { app.selection = .workspace(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .batonToggleSidebar)) { _ in
            isSidebarVisible.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .batonNewWorkspace)) { note in
            createTargetRepo = note.object as? Repo ?? app.selectedWorkspace.flatMap(app.repo(for:))
            isCreateSheetPresented = true
        }
    }

    private func layout(containerWidth: CGFloat) -> some View {
        let inspectorVisible = app.selectedModel?.isInspectorVisible == true
        let sidebarRange = paneRange(
            minimum: 200,
            maximum: 420,
            containerWidth: containerWidth,
            otherPaneWidth: inspectorVisible ? max(inspectorWidth, 280) : 0,
            visibleHandleCount: (isSidebarVisible ? 1 : 0) + (inspectorVisible ? 1 : 0)
        )
        let visibleSidebarWidth = isSidebarVisible
            ? min(max(sidebarWidth, sidebarRange.lowerBound), sidebarRange.upperBound)
            : 0
        let inspectorRange = paneRange(
            minimum: 280,
            maximum: 760,
            containerWidth: containerWidth,
            otherPaneWidth: visibleSidebarWidth,
            visibleHandleCount: (isSidebarVisible ? 1 : 0) + (inspectorVisible ? 1 : 0)
        )
        let visibleInspectorWidth = inspectorVisible
            ? min(max(inspectorWidth, inspectorRange.lowerBound), inspectorRange.upperBound)
            : 0

        return HStack(spacing: 0) {
            if isSidebarVisible {
                SidebarView()
                    .frame(width: visibleSidebarWidth)
                    .background(Palette.sidebar)
                    .transition(.move(edge: .leading))

                ResizeHandle(width: $sidebarWidth, range: sidebarRange, edge: .leading)
            }

            center
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surface)

            if let model = app.selectedModel, model.isInspectorVisible {
                ResizeHandle(width: $inspectorWidth, range: inspectorRange, edge: .trailing)

                InspectorView(model: model)
                    .id(model.workspace.id)
                    .frame(width: visibleInspectorWidth)
                    .background(Palette.surface)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    /// Pane limits depend on the live window size so neither drag handle can consume the space
    /// reserved for the session.
    private func paneRange(
        minimum: CGFloat,
        maximum: CGFloat,
        containerWidth: CGFloat,
        otherPaneWidth: CGFloat,
        visibleHandleCount: Int
    ) -> ClosedRange<CGFloat> {
        let available = containerWidth
            - 420
            - otherPaneWidth
            - CGFloat(visibleHandleCount) * Metrics.hairline
        return minimum...max(minimum, min(maximum, available))
    }

    @ViewBuilder
    private var center: some View {
        if !app.isLoaded {
            LoadingView()
        } else {
            switch app.selection {
            case .home:
                HomeView()
            case .search:
                SearchView()
            case .workspace:
                if let workspace = app.selectedWorkspace {
                    WorkspaceDetailView(model: app.model(for: workspace))
                } else {
                    HomeView()
                }
            }
        }
    }

    private var alertBinding: Binding<BatonAlert?> {
        Binding(
            get: { app.alert },
            set: { newValue in
                let model = app
                model.alert = newValue
            }
        )
    }
}

/// A draggable one-pixel divider. Uses a wider invisible hit area than it draws, because a
/// one-pixel drag target is unusable.
struct ResizeHandle: View {
    @Binding var width: CGFloat
    var range: ClosedRange<CGFloat>
    var edge: HorizontalEdge

    @State private var startWidth: CGFloat?
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(isHovered ? Palette.borderStrong : Palette.border)
            .frame(width: Metrics.hairline)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHovered = hovering
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let base = startWidth ?? width
                                if startWidth == nil { startWidth = base }
                                let delta = edge == .leading ? value.translation.width : -value.translation.width
                                width = min(max(base + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}

extension Notification.Name {
    // batonOpenWorkspace is declared in AppChrome.swift, next to the notification delegate that
    // posts it. These two are only ever posted by views, so they live here.
    static let batonToggleSidebar = Notification.Name("baton.toggleSidebar")
    static let batonNewWorkspace = Notification.Name("baton.newWorkspace")
}
