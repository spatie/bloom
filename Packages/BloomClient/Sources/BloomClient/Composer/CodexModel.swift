import Foundation

// MARK: - Model

/// One model Codex advertises through `model/list`.
///
/// This catalog is not an entitlement check. A model can appear here while the signed-in account
/// cannot use it.
///
/// **The efforts belong to the model, not to Bloom.** Claude Code takes the same five levels for
/// every model, so one flat list is right there. Codex does not: measured against codex-cli
/// 0.147.0, `gpt-5.6-sol` and `gpt-5.6-terra` accept six levels up to `ultra`, `gpt-5.6-luna`
/// five, and `gpt-5.5` and `gpt-5.2` four. A flat five-entry picker is wrong for three of the five
/// models on offer, in both directions: it hides a level two models have and offers levels three
/// models do not.
///
/// **Re-measured against codex-cli 0.153.0 on 2026-09-05, and every part of that list had moved.**
/// `gpt-6-astra` is there, as the account default, with the same six levels and a default of
/// `medium`; `gpt-5.2` has gone; `gpt-5.4-mini` and `gpt-5.3-codex-spark` have arrived with four
/// each. Not one line of Bloom changed to offer any of it, which is the whole case for fetching:
/// a generation nobody here had heard of was named, ranked and given its own effort picker on the
/// strength of what the CLI said. Both captures are kept as fixtures, and
/// `Tests/fixtures/codex-model-list-astra.json` is the newer one.
///
/// **What is on the wire and deliberately not read here.** Every model in that capture also
/// carries `serviceTiers` and `additionalSpeedTiers`: a `priority` tier the CLI calls "Fast",
/// worth 2x speed on `gpt-6-astra` and 1.5x on the `gpt-5.6` family, for more of the account's
/// usage allowance. `turn/start` takes it as `serviceTier` and `serviceTierForTurn`, so it is a
/// real control rather than an unreachable field, and Bloom sends neither, so every Codex turn
/// runs at standard speed. It is left out on purpose and not for want of a place to put it: it
/// spends the user's allowance faster, and Bloom's own "Fast mode" switch is already a different
/// thing on the other backend (Claude Code's `--thinking disabled`, see `AgentRunner`), so a
/// second control by that name needs a decision about both rather than a field being decoded.
public struct CodexModel: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let displayName: String
    public let description: String
    public let isDefault: Bool
    /// Not shown in a picker unless the user asked for hidden models. Kept rather than dropped, so
    /// a session already pinned to one still resolves its name.
    public let hidden: Bool
    public let supportedEfforts: [CodexReasoningEffort]
    public let defaultEffort: String
    public let inputModalities: [String]
    public let supportsPersonality: Bool

    public init(
        id: String,
        displayName: String,
        description: String = "",
        isDefault: Bool = false,
        hidden: Bool = false,
        supportedEfforts: [CodexReasoningEffort] = [],
        defaultEffort: String = "",
        inputModalities: [String] = [],
        supportsPersonality: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.isDefault = isDefault
        self.hidden = hidden
        self.supportedEfforts = supportedEfforts
        self.defaultEffort = defaultEffort
        self.inputModalities = inputModalities
        self.supportsPersonality = supportsPersonality
    }

    public var acceptsImages: Bool { inputModalities.contains("image") }

    public var effortIDs: [String] { supportedEfforts.map(\.id) }

    /// The effort to use when a session has one that this model does not take. Falls back to the
    /// model's own default, which is why the default is carried rather than assumed to be "high".
    public func resolvedEffort(preferring wanted: String) -> String {
        if effortIDs.contains(wanted) { return wanted }
        if !defaultEffort.isEmpty { return defaultEffort }
        return effortIDs.first ?? ""
    }

    public static func decode(_ json: JSONValue) -> CodexModel? {
        guard let id = json["id"]?.stringValue else { return nil }
        let efforts = (json["supportedReasoningEfforts"]?.arrayValue ?? [])
            .compactMap(CodexReasoningEffort.decode)
        return CodexModel(
            id: id,
            displayName: json["displayName"]?.stringValue ?? id,
            description: json["description"]?.stringValue ?? "",
            isDefault: json["isDefault"]?.boolValue ?? false,
            hidden: json["hidden"]?.boolValue ?? false,
            supportedEfforts: efforts,
            defaultEffort: json["defaultReasoningEffort"]?.stringValue ?? "",
            inputModalities: (json["inputModalities"] ?? .null).stringArray,
            supportsPersonality: json["supportsPersonality"]?.boolValue ?? false
        )
    }

    public static func decodeList(_ json: JSONValue) -> [CodexModel] {
        (json["data"]?.arrayValue ?? []).compactMap(CodexModel.decode)
    }
}

/// One reasoning level, with the sentence the server wrote for it. The description is worth
/// keeping: it is what a picker can put under the name instead of Bloom inventing one.
public struct CodexReasoningEffort: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let description: String

    public init(id: String, description: String = "") {
        self.id = id
        self.description = description
    }

    /// `xhigh` reads as Xhigh with a naive title case, which is why the label is built here rather
    /// than by the generic one the composer uses for open-set ids.
    public var label: String {
        switch id {
        case "xhigh": "Extra high"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    public static func decode(_ json: JSONValue) -> CodexReasoningEffort? {
        guard let id = json["reasoningEffort"]?.stringValue else { return nil }
        return CodexReasoningEffort(id: id, description: json["description"]?.stringValue ?? "")
    }
}
