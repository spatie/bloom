import Foundation

/// One model Grok advertises through ACP `initialize` / `session/new`.
///
/// Fetched, never hardcoded. Grok 4.6 arrived as the account default with an `xhigh` effort that
/// 4.5 does not have; a list in the source would have offered the wrong levels the day it shipped.
public struct GrokModel: Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let description: String
    public let isDefault: Bool
    public let supportedEfforts: [GrokReasoningEffort]
    public let defaultEffort: String
    public let contextTokens: Int

    public init(
        id: String,
        displayName: String,
        description: String = "",
        isDefault: Bool = false,
        supportedEfforts: [GrokReasoningEffort] = [],
        defaultEffort: String = "",
        contextTokens: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.isDefault = isDefault
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
        self.contextTokens = contextTokens
    }

    public var effortIDs: [String] { supportedEfforts.map(\.id) }

    public var agentModel: AgentModel {
        AgentModel(
            id: id,
            displayName: displayName,
            isDefault: isDefault,
            supportedEfforts: supportedEfforts.map { AgentModelEffort(id: $0.id, label: $0.label) },
            defaultEffort: defaultEffort
        )
    }

    public func resolvedEffort(preferring wanted: String) -> String {
        agentModel.resolvedEffort(preferring: wanted)
    }

    public static func decode(_ json: JSONValue, currentModelID: String) -> GrokModel? {
        let id = json["modelId"]?.stringValue ?? json["id"]?.stringValue
        guard let id, !id.isEmpty else { return nil }
        let meta = json["_meta"] ?? .null
        let effortsJSON = meta["reasoningEfforts"] ?? json["reasoningEfforts"] ?? .null
        let efforts = (effortsJSON.arrayValue ?? []).compactMap(GrokReasoningEffort.decode)
        let defaultEffort = efforts.first(where: \.isDefault)?.id
            ?? meta["reasoningEffort"]?.stringValue
            ?? json["reasoningEffort"]?.stringValue
            ?? ""
        return GrokModel(
            id: id,
            displayName: json["name"]?.stringValue ?? json["displayName"]?.stringValue ?? id,
            description: json["description"]?.stringValue ?? "",
            isDefault: id == currentModelID,
            supportedEfforts: efforts,
            defaultEffort: defaultEffort,
            contextTokens: meta["totalContextTokens"]?.intValue ?? 0
        )
    }

    public static func decodeList(_ json: JSONValue) -> [GrokModel] {
        let current = json["currentModelId"]?.stringValue ?? ""
        let items = json["availableModels"]?.arrayValue
            ?? json["data"]?.arrayValue
            ?? json.arrayValue
            ?? []
        return items.compactMap { decode($0, currentModelID: current) }
    }
}

public struct GrokReasoningEffort: Sendable, Hashable, Identifiable {
    public let id: String
    public let description: String
    public let isDefault: Bool

    public init(id: String, description: String = "", isDefault: Bool = false) {
        self.id = id
        self.description = description
        self.isDefault = isDefault
    }

    /// `xhigh` reads as Xhigh with a naive title case, which is why the label is built here.
    public var label: String {
        switch id {
        case "xhigh": "Extra high"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    public static func decode(_ json: JSONValue) -> GrokReasoningEffort? {
        let id = json["id"]?.stringValue ?? json["value"]?.stringValue
        guard let id, !id.isEmpty else { return nil }
        return GrokReasoningEffort(
            id: id,
            description: json["description"]?.stringValue ?? "",
            isDefault: json["default"]?.boolValue ?? false
        )
    }
}
