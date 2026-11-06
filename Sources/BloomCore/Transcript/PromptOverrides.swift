import Foundation

/// Where a customised prompt lives, and what happens when there is not one.
///
/// User defaults rather than the `SettingsLoader` chain, deliberately. That chain reads TOML files
/// and has no writer at all: everything it surfaces was typed into a file by hand, and the Settings
/// window only ever displays it. A prompt is edited in the window, so putting it there would mean
/// building a TOML writer and then deciding which of the four layers the window is allowed to
/// rewrite. A prompt is also a fact about how this person likes to work rather than about a
/// repository, which is the same reason `AppDefaults` sits outside the chain.
///
/// `@unchecked Sendable` because `UserDefaults` is documented as thread safe but is not annotated
/// as such. Nothing else is stored here, so there is no other state to reason about.
public struct PromptOverrides: @unchecked Sendable {
    public static let keyPrefix = "prompts."

    public static func key(for id: PromptID) -> String {
        keyPrefix + id.rawValue
    }

    /// GitLab's overrides live apart, so a GitHub template saying `gh pr merge` never reaches a
    /// GitLab project.
    public static func key(for id: PromptID, forge: Forge) -> String {
        forge == .gitHub ? key(for: id) : keyPrefix + "gitLab." + id.rawValue
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Exactly what is stored, including an override the user has emptied. Distinguishing "never
    /// customised" from "customised, then cleared" is what lets the settings form show an empty box
    /// to somebody who deliberately emptied one.
    public func stored(for id: PromptID) -> String? {
        defaults.string(forKey: Self.key(for: id))
    }

    public func set(_ text: String?, for id: PromptID) {
        let key = Self.key(for: id)
        if let text {
            defaults.set(text, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func isCustomised(for id: PromptID) -> Bool {
        stored(for: id) != nil
    }

    /// What actually gets sent. An override that is empty, or is nothing but whitespace, falls back
    /// to the built-in: the alternative is handing the agent a blank turn, which it can only answer
    /// with a question.
    public func template(for id: PromptID) -> String {
        let override = stored(for: id) ?? ""
        guard !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PromptRegistry.definition(for: id).defaultTemplate
        }
        return override
    }

    /// The built-in a forge starts from. Prompts with no GitLab variant are shared, overrides too.
    public static func defaultTemplate(for id: PromptID, forge: Forge) -> String {
        let shared = PromptRegistry.definition(for: id).defaultTemplate
        return forge == .gitLab ? GitLabInstructions.defaultTemplate(for: id) ?? shared : shared
    }

    public static func hasVariant(_ id: PromptID, for forge: Forge) -> Bool {
        forge == .gitHub || GitLabInstructions.defaultTemplate(for: id) != nil
    }

    public func stored(for id: PromptID, forge: Forge) -> String? {
        guard Self.hasVariant(id, for: forge), forge == .gitLab else { return stored(for: id) }
        return defaults.string(forKey: Self.key(for: id, forge: forge))
    }

    public func set(_ text: String?, for id: PromptID, forge: Forge) {
        guard Self.hasVariant(id, for: forge), forge == .gitLab else { return set(text, for: id) }
        let key = Self.key(for: id, forge: forge)
        if let text { defaults.set(text, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    public func template(for id: PromptID, forge: Forge) -> String {
        guard forge == .gitLab, Self.hasVariant(id, for: .gitLab) else { return template(for: id) }
        let override = stored(for: id, forge: forge) ?? ""
        guard !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.defaultTemplate(for: id, forge: forge)
        }
        return override
    }
}
