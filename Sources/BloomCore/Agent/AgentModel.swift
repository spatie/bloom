import Foundation

/// The part of a backend's model description that model selection needs. Wire-only fields stay
/// on the backend's decoded model, so adding a CLI does not add another model type to the UI.
public struct AgentModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let isDefault: Bool
    public let hidden: Bool
    public let supportedEfforts: [AgentModelEffort]
    public let defaultEffort: String

    public init(
        id: String,
        displayName: String,
        isDefault: Bool = false,
        hidden: Bool = false,
        supportedEfforts: [AgentModelEffort] = [],
        defaultEffort: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.isDefault = isDefault
        self.hidden = hidden
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
    }

    public func resolvedEffort(preferring wanted: String) -> String {
        if supportedEfforts.contains(where: { $0.id == wanted }) { return wanted }
        if !defaultEffort.isEmpty { return defaultEffort }
        return supportedEfforts.first?.id ?? ""
    }

    /// Explicit choices never silently fall back. An omitted choice uses the server's default,
    /// then its ranked list, and hidden models remain resolvable without becoming selectable.
    public static func selection(requested: String?, from models: [AgentModel]) -> AgentModel? {
        let visible = models.filter { !$0.hidden }
        if let requested { return visible.first { $0.id == requested } }
        return visible.first { $0.isDefault } ?? visible.first
    }
}

public struct AgentModelEffort: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}
