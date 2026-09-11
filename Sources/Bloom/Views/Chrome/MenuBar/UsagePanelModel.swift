import AppKit
import SwiftUI
import BloomCore

/// The usage panel's own state: which screen is showing, the layout somebody arranged, the display
/// choices from its Settings screen, and the transient things (a tooltip, a confirmation pill).
///
/// One instance for the life of the process, shared by the panel and the status item, because the
/// status item draws the starred metrics out of the same layout the panel edits.
@MainActor
@Observable
final class UsagePanelModel {
    static let shared = UsagePanelModel()

    enum Screen: Int {
        case dashboard
        case customize
        case settings
    }

    struct Pill: Equatable {
        var symbol: String
        var text: String
        var isWarning: Bool
        var id = UUID()
    }

    struct Tooltip: Equatable {
        var text: String
        var anchor: CGRect
    }

    private(set) var screen: Screen = .dashboard
    /// The provider whose metrics Customize is showing, or nothing for the provider list.
    private(set) var customizing: AgentKind?
    /// Which way the last navigation went, so the page slides in from the matching edge.
    private(set) var isMovingForward = true
    var pill: Pill?
    var tooltip: Tooltip?
    private(set) var layout: UsageLayout

    var meterStyle: UsageMeterStyle {
        didSet { defaults.set(meterStyle.rawValue, forKey: UsagePreferenceKey.meterStyle) }
    }
    var resetDisplay: UsageResetDisplay {
        didSet { defaults.set(resetDisplay.rawValue, forKey: UsagePreferenceKey.resetDisplay) }
    }
    var alwaysShowsPacing: Bool {
        didSet { defaults.set(alwaysShowsPacing, forKey: UsagePreferenceKey.alwaysShowsPacing) }
    }
    var iconStyle: MenuBarIconStyle {
        didSet { defaults.set(iconStyle.rawValue, forKey: UsagePreferenceKey.iconStyle) }
    }
    var density: UsageDensity {
        didSet { defaults.set(density.rawValue, forKey: UsagePreferenceKey.density) }
    }
    var timeFormat: UsageTimeFormat {
        didSet { defaults.set(timeFormat.rawValue, forKey: UsagePreferenceKey.timeFormat) }
    }
    var theme: UsagePanelTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: UsagePreferenceKey.theme)
            themeDidChange()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Set by the panel controller: close the panel, ask again now, and follow a theme change.
    @ObservationIgnored var dismiss: () -> Void = {}
    @ObservationIgnored var refresh: () -> Void = {}
    @ObservationIgnored var themeDidChange: () -> Void = {}
    @ObservationIgnored private var pillTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = UsageLayout.load(from: defaults)
        meterStyle = Self.read(UsageMeterStyle.self, UsagePreferenceKey.meterStyle, defaults) ?? .left
        resetDisplay = Self.read(UsageResetDisplay.self, UsagePreferenceKey.resetDisplay, defaults) ?? .countdown
        alwaysShowsPacing = defaults.bool(forKey: UsagePreferenceKey.alwaysShowsPacing)
        iconStyle = Self.read(MenuBarIconStyle.self, UsagePreferenceKey.iconStyle, defaults) ?? .text
        density = Self.read(UsageDensity.self, UsagePreferenceKey.density, defaults) ?? .regular
        timeFormat = Self.read(UsageTimeFormat.self, UsagePreferenceKey.timeFormat, defaults) ?? .automatic
        theme = Self.read(UsagePanelTheme.self, UsagePreferenceKey.theme, defaults) ?? .system
    }

    private nonisolated static func read<Choice: RawRepresentable>(
        _ type: Choice.Type, _ key: String, _ defaults: UserDefaults
    ) -> Choice? where Choice.RawValue == String {
        defaults.string(forKey: key).flatMap(Choice.init(rawValue:))
    }

    var options: UsageDisplayOptions {
        UsageDisplayOptions(
            meterStyle: meterStyle,
            resetDisplay: resetDisplay,
            alwaysShowsPacing: alwaysShowsPacing,
            timeFormat: timeFormat
        )
    }

    var appearance: NSAppearance? {
        switch theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Navigation

    func navigate(to screen: Screen, provider: AgentKind? = nil, forward: Bool? = nil, animated: Bool = true) {
        let isForward = forward ?? (screen.rawValue > self.screen.rawValue || provider != nil)
        let change = {
            self.isMovingForward = isForward
            self.screen = screen
            self.customizing = provider
            self.tooltip = nil
        }
        if animated {
            withAnimation(UsageMotion.spring, change)
        } else {
            change()
        }
    }

    /// One step back, or false when there is nowhere further back than the dashboard.
    @discardableResult
    func back() -> Bool {
        if customizing != nil {
            navigate(to: .customize, forward: false)
        } else if screen != .dashboard {
            navigate(to: .dashboard, forward: false)
        } else {
            return false
        }
        return true
    }

    // MARK: - Layout

    func update(_ change: (inout UsageLayout) -> Void) {
        var copy = layout
        change(&copy)
        guard copy != layout else { return }
        layout = copy
        layout.save(to: defaults)
    }

    func adopt(_ metrics: [AgentKind: [UsageMetric]]) {
        update { $0.adopt(metrics) }
    }

    func togglePin(_ metric: UsageMetric) {
        var outcome = UsageLayout.PinOutcome.unpinned
        update { outcome = $0.togglePin(metric) }
        switch outcome {
        case .pinned: show(Pill(symbol: "star.fill", text: "Starred for menu bar", isWarning: false))
        case .unpinned: show(Pill(symbol: "star.slash", text: "Removed from menu bar", isWarning: false))
        case .denied: show(Pill(symbol: "exclamationmark.triangle.fill", text: UsageLayout.pinDenial, isWarning: true))
        }
    }

    func resetAll() {
        layout = UsageLayout()
        layout.save(to: defaults)
    }

    func show(_ pill: Pill) {
        withAnimation(UsageMotion.spring) { self.pill = pill }
        pillTask?.cancel()
        pillTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(UsageMotion.spring) { self?.pill = nil }
        }
    }

    // MARK: - Screenshots

    /// One provider's card as a PNG on the pasteboard, drawn at four times so it survives being
    /// pasted into a chat and zoomed.
    func copyScreenshot(of section: UsageLayout.Section, account: AgentAccount?, now: Date) {
        let card = UsageShareCard(section: section, account: account, now: now)
            .environment(self)
            .environment(\.usageScale, UsageScale.of(.regular))
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 4
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        show(Pill(symbol: "checkmark.circle.fill", text: "Copied to clipboard", isWarning: false))
    }

    private var colorScheme: ColorScheme {
        let appearance = self.appearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}
