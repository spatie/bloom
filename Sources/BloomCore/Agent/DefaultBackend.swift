import Foundation
import BloomClient

public typealias DefaultBackend = BloomClient.DefaultBackend

extension DefaultBackend {
    /// The three questions above, answered together with the effort that follows from them.
    ///
    /// - Parameters:
    ///   - model: the model actually in force, which is not always `app.model`: a repository's
    ///     settings file outranks the Models screen. See `ComposerDefaults.resolve`.
    ///   - running: the backend to keep when nothing recognises the model, which is question 3.
    ///   - models: the last fetched lists, empty when discovery has not answered yet.
    public static func resolve(
        model: String,
        effort: String,
        app: AppDefaults,
        running: AgentKind = .claudeCode,
        models: [AgentKind: [AgentModel]] = [:]
    ) -> DefaultBackend {
        let identity = ModelIdentifier.resolve(model, models: models)
        let kind: AgentKind
        if identity.namesBackend, let named = identity.kind {
            kind = named
        } else if model == app.model {
            kind = app.backend
        } else {
            kind = identity.kind ?? running
        }
        return DefaultBackend(
            kind: kind,
            model: identity.model,
            effort: self.effort(
                effort,
                on: kind,
                model: identity.model,
                models: models
            )
        )
    }

    public static func resolve(model: String, effort: String, app: AppDefaults,
                               running: AgentKind = .claudeCode, codexModels: [CodexModel]) -> DefaultBackend {
        resolve(model: model, effort: effort, app: app, running: running, models: [.codex: codexModels.map(\.agentModel)])
    }
}
