import Foundation

/// What the usage panel shows, in which order, and what is starred for the menu bar.
///
/// **A record of choices, not of metrics.** The metrics come and go with what the providers report:
/// a model scoped weekly appears the week a plan gains one, Codex's Spark windows appear on the
/// accounts that have them. So nothing here lists every metric. It lists what somebody decided
/// (an order, a section, a hidden row, a star), and every metric nobody has decided about falls
/// back to `UsageCatalogue`'s defaults. A metric seen for the first time is *adopted*: its default
/// star is applied once, so unstarring it later sticks rather than being undone on the next poll.
///
/// Persisted as JSON under one `UserDefaults` key, `UsagePreferenceKey.layout`.
public struct UsageLayout: Codable, Sendable, Hashable {
    /// Which side of the caret a metric sits on. Hiding is separate (`hidden`), so a row switched
    /// off in Customize stays in its section there and comes back where it was.
    public enum Placement: String, Codable, Sendable, Hashable {
        case alwaysVisible
        case onDemand
    }

    /// At most two stars per provider, as OpenUsage caps it: two figures stack into the height of
    /// the menu bar, and a third would need a second row the bar does not have.
    public static let maximumPinsPerProvider = 2
    public static let pinDenial = "Up to 2 stars per provider"

    public var providerOrder: [AgentKind]
    public var disabledProviders: Set<AgentKind>
    public var metricOrder: [UsageMetricID]
    public var placements: [UsageMetricID: Placement]
    public var hidden: Set<UsageMetricID>
    public var pins: [UsageMetricID]
    public var adopted: Set<UsageMetricID>
    public var expandedProviders: Set<AgentKind>

    public init(
        providerOrder: [AgentKind] = UsageLayout.defaultProviderOrder,
        disabledProviders: Set<AgentKind> = [],
        metricOrder: [UsageMetricID] = [],
        placements: [UsageMetricID: Placement] = [:],
        hidden: Set<UsageMetricID> = [],
        pins: [UsageMetricID] = [],
        adopted: Set<UsageMetricID> = [],
        expandedProviders: Set<AgentKind> = []
    ) {
        self.providerOrder = providerOrder
        self.disabledProviders = disabledProviders
        self.metricOrder = metricOrder
        self.placements = placements
        self.hidden = hidden
        self.pins = pins
        self.adopted = adopted
        self.expandedProviders = expandedProviders
    }

    /// Every field optional on the way in, so a layout written by an older build, or by a newer
    /// one that added a field, loses nothing it does carry instead of falling back to the defaults
    /// wholesale and taking somebody's stars with it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerOrder = try container.decodeIfPresent([AgentKind].self, forKey: .providerOrder)
            ?? UsageLayout.defaultProviderOrder
        disabledProviders = try container.decodeIfPresent(Set<AgentKind>.self, forKey: .disabledProviders) ?? []
        metricOrder = try container.decodeIfPresent([UsageMetricID].self, forKey: .metricOrder) ?? []
        placements = try container.decodeIfPresent([UsageMetricID: Placement].self, forKey: .placements) ?? [:]
        hidden = try container.decodeIfPresent(Set<UsageMetricID>.self, forKey: .hidden) ?? []
        pins = try container.decodeIfPresent([UsageMetricID].self, forKey: .pins) ?? []
        adopted = try container.decodeIfPresent(Set<UsageMetricID>.self, forKey: .adopted) ?? []
        expandedProviders = try container.decodeIfPresent(Set<AgentKind>.self, forKey: .expandedProviders) ?? []
    }

    /// The two providers that publish an allowance, in the order `AgentKind` declares them.
    public static let defaultProviderOrder: [AgentKind] = AgentKind.allCases.filter(\.publishesUsage)

    // MARK: - Reading

    /// One provider as the panel draws it.
    public struct Section: Sendable, Hashable, Identifiable {
        public var provider: AgentKind
        public var alwaysVisible: [UsageMetric]
        public var onDemand: [UsageMetric]
        public var isExpanded: Bool
        public var id: AgentKind { provider }

        /// What the card shows right now.
        public var visible: [UsageMetric] { isExpanded ? alwaysVisible + onDemand : alwaysVisible }
    }

    /// The enabled providers that have something to show, each with its rows split by section.
    ///
    /// A provider whose every enabled metric is On Demand has them promoted into the card, so a
    /// card is never a header over a caret and nothing else.
    public func sections(for metrics: [AgentKind: [UsageMetric]]) -> [Section] {
        orderedProviders(among: Set(metrics.keys)).compactMap { provider in
            guard !disabledProviders.contains(provider) else { return nil }
            let ordered = orderedMetrics(metrics[provider] ?? []).filter { !isHidden($0.id) }
            var always = ordered.filter { placement(of: $0.id) == .alwaysVisible }
            var demand = ordered.filter { placement(of: $0.id) == .onDemand }
            if always.isEmpty, !demand.isEmpty {
                always = demand
                demand = []
            }
            guard !always.isEmpty else { return nil }
            return Section(
                provider: provider,
                alwaysVisible: always,
                onDemand: demand,
                isExpanded: expandedProviders.contains(provider)
            )
        }
    }

    /// Every metric of one provider in the order Customize lists it, hidden ones included.
    public func orderedMetrics(_ metrics: [UsageMetric]) -> [UsageMetric] {
        let positions = Dictionary(metricOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return metrics.enumerated().sorted { lhs, rhs in
            switch (positions[lhs.element.id], positions[rhs.element.id]) {
            case (let left?, let right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Every known provider in the saved order, then any the order does not name yet.
    public func orderedProviders(among available: Set<AgentKind>? = nil) -> [AgentKind] {
        let known = providerOrder + UsageLayout.defaultProviderOrder.filter { !providerOrder.contains($0) }
        guard let available else { return known }
        return known.filter(available.contains)
    }

    public func placement(of id: UsageMetricID) -> Placement {
        placements[id] ?? (UsageCatalogue.isOnDemandByDefault(id) ? .onDemand : .alwaysVisible)
    }

    public func isPinned(_ id: UsageMetricID) -> Bool { pins.contains(id) }

    public func isHidden(_ id: UsageMetricID) -> Bool { hidden.contains(id) }

    public func isEnabled(_ provider: AgentKind) -> Bool { !disabledProviders.contains(provider) }

    /// The starred metrics the menu bar shows, grouped by provider, in the panel's order. Hidden
    /// metrics and disabled providers keep their stars and show nothing.
    public func pinnedMetrics(in metrics: [AgentKind: [UsageMetric]]) -> [(provider: AgentKind, metrics: [UsageMetric])] {
        orderedProviders(among: Set(metrics.keys)).compactMap { provider in
            guard isEnabled(provider) else { return nil }
            let starred = orderedMetrics(metrics[provider] ?? []).filter { isPinned($0.id) && !isHidden($0.id) }
            return starred.isEmpty ? nil : (provider, starred)
        }
    }

    // MARK: - Changing

    /// Applies the default star to every metric seen for the first time. Returns whether anything
    /// changed, so the caller writes only when it has to.
    @discardableResult
    public mutating func adopt(_ metrics: [AgentKind: [UsageMetric]]) -> Bool {
        var changed = false
        for (provider, list) in metrics {
            for metric in list where !adopted.contains(metric.id) {
                adopted.insert(metric.id)
                changed = true
                if UsageCatalogue.isPinnedByDefault(metric.id),
                   pinCount(for: provider) < Self.maximumPinsPerProvider {
                    pins.append(metric.id)
                }
            }
        }
        return changed
    }

    public enum PinOutcome: Sendable, Equatable {
        case pinned
        case unpinned
        /// The provider already has two.
        case denied
    }

    public mutating func togglePin(_ metric: UsageMetric) -> PinOutcome {
        if let index = pins.firstIndex(of: metric.id) {
            pins.remove(at: index)
            return .unpinned
        }
        guard pinCount(for: metric.provider) < Self.maximumPinsPerProvider else { return .denied }
        pins.append(metric.id)
        return .pinned
    }

    func pinCount(for provider: AgentKind) -> Int {
        pins.filter { UsageCatalogue.providerPart(of: $0) == provider.rawValue }.count
    }

    public mutating func setPlacement(_ placement: Placement, for id: UsageMetricID) {
        placements[id] = placement
    }

    public mutating func setHidden(_ isHidden: Bool, for id: UsageMetricID) {
        if isHidden { hidden.insert(id) } else { hidden.remove(id) }
    }

    /// Moves a metric to sit before another one (or at the end when `target` is nil), and into the
    /// section the drop landed in.
    ///
    /// The whole provider's order is written back, not just the moved row, because an order that
    /// names some rows and not others is sorted against defaults the next time, and the row the
    /// person placed would drift.
    public mutating func move(
        _ id: UsageMetricID,
        before target: UsageMetricID?,
        into placement: Placement,
        among metrics: [UsageMetric]
    ) {
        var ids = orderedMetrics(metrics).map(\.id).filter { $0 != id }
        if let target, let index = ids.firstIndex(of: target) {
            ids.insert(id, at: index)
        } else {
            ids.append(id)
        }
        let others = metricOrder.filter { !ids.contains($0) && $0 != id }
        metricOrder = others + ids
        placements[id] = placement
    }

    public mutating func moveProvider(_ provider: AgentKind, before target: AgentKind?) {
        var order = orderedProviders().filter { $0 != provider }
        if let target, let index = order.firstIndex(of: target) {
            order.insert(provider, at: index)
        } else {
            order.append(provider)
        }
        providerOrder = order
    }

    /// Moves a provider to where another one sits, in the direction the drag went.
    ///
    /// Dropping a provider on one below it puts it after that one; on one above it, before. A
    /// plain `before` in both directions makes a downward drag look like it did nothing, because
    /// inserting a row before the neighbour it already sits above is where it already was.
    public mutating func moveProvider(_ provider: AgentKind, toward target: AgentKind) {
        let order = orderedProviders()
        guard provider != target,
              let from = order.firstIndex(of: provider),
              let to = order.firstIndex(of: target)
        else { return }
        guard from < to else { return moveProvider(provider, before: target) }
        let after = order.index(after: to)
        moveProvider(provider, before: after < order.endIndex ? order[after] : nil)
    }

    /// Moves providers the way a `List` reports a drag: a set of offsets into the current order,
    /// and the offset they were dropped before.
    public mutating func moveProviders(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var order = orderedProviders()
        let moved = offsets.sorted().compactMap { order.indices.contains($0) ? order[$0] : nil }
        guard !moved.isEmpty else { return }
        // Back to front, so the indices still to be removed stay valid.
        for index in offsets.sorted(by: >) where order.indices.contains(index) {
            order.remove(at: index)
        }
        let landing = destination - offsets.filter { $0 < destination }.count
        order.insert(contentsOf: moved, at: min(max(landing, 0), order.count))
        providerOrder = order
    }

    public mutating func setEnabled(_ isEnabled: Bool, for provider: AgentKind) {
        if isEnabled { disabledProviders.remove(provider) } else { disabledProviders.insert(provider) }
    }

    public mutating func toggleExpanded(_ provider: AgentKind) {
        if expandedProviders.contains(provider) {
            expandedProviders.remove(provider)
        } else {
            expandedProviders.insert(provider)
        }
    }

    /// Puts one provider's rows, order and stars back to the defaults, and turns it back on.
    public mutating func reset(_ provider: AgentKind) {
        let belongs: (UsageMetricID) -> Bool = { UsageCatalogue.providerPart(of: $0) == provider.rawValue }
        metricOrder.removeAll(where: belongs)
        placements = placements.filter { !belongs($0.key) }
        hidden = hidden.filter { !belongs($0) }
        pins.removeAll(where: belongs)
        adopted = adopted.filter { !belongs($0) }
        disabledProviders.remove(provider)
    }

    // MARK: - Storage

    public static func load(from defaults: UserDefaults = .standard) -> UsageLayout {
        guard let data = defaults.data(forKey: UsagePreferenceKey.layout),
              let layout = try? JSONDecoder().decode(UsageLayout.self, from: data)
        else { return UsageLayout() }
        return layout
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: UsagePreferenceKey.layout)
    }
}

extension AgentKind {
    /// Whether Bloom can ask this provider how much of its allowance is left. See
    /// `AgentQuotaSources`, which is the list this has to agree with.
    public var publishesUsage: Bool {
        switch self {
        case .claudeCode, .codex: true
        case .grok, .cursor, .openCode: false
        }
    }
}
