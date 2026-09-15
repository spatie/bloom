import Foundation

/// Codex's service tier is independent of Claude's thinking switch. Missing session state means
/// inherit Codex's merged configuration; an explicit false must survive as standard speed.
///
/// Here rather than beside the Codex client because a server reports it: only the machine that
/// runs the turn can read the configuration and catalogue that decide it, and a client that read
/// its own drew a switch describing a Codex it was never going to use.
public struct CodexSpeed: Codable, Equatable, Sendable {
    public let isFast: Bool
    public let supportsFast: Bool

    public init(isFast: Bool, supportsFast: Bool) {
        self.isFast = isFast
        self.supportsFast = supportsFast
    }

    public init(config: JSONValue, model: CodexModel) {
        supportsFast = config["features"]?["fast_mode"]?.boolValue != false && model.fastServiceTier != nil
        let tier = config["service_tier"]?.stringValue ?? model.defaultServiceTier
        isFast = supportsFast && (tier == "fast" || tier == "priority" || tier == model.fastServiceTier)
    }

    public func isFast(override: Bool?) -> Bool {
        supportsFast && (override ?? isFast)
    }

    public static func key(sessionID: SessionID) -> String { "session.\(sessionID).codexFastMode" }

    public static func override(stored: String?) -> Bool? {
        switch stored {
        case "1": true
        case "0": false
        default: nil
        }
    }

    public static func serviceTier(override: Bool?) -> String? {
        override.map { $0 ? "priority" : "default" }
    }

    /// Every catalogue model's speed under one merged configuration, keyed by model id, which is
    /// what a server sends so that changing the model picker needs no second round trip.
    public static func speeds(config: JSONValue, models: [CodexModel]) -> [String: CodexSpeed] {
        Dictionary(models.map { ($0.id, CodexSpeed(config: config, model: $0)) }, uniquingKeysWith: { first, _ in first })
    }
}

/// What a composer drawing Codex's speed switch can say about it.
public enum CodexSpeedReading: Equatable, Sendable {
    case loading
    case unavailable
    case read(CodexSpeed)

    public var speed: CodexSpeed? {
        if case .read(let speed) = self { speed } else { nil }
    }

    /// A server's report for the selected model. Absent means a server too old to report speed,
    /// or one whose Codex could not be read, and neither is a reason to guess from this machine.
    public static func reported(_ speeds: [String: CodexSpeed]?, model: String, isLoaded: Bool) -> Self {
        guard isLoaded else { return .loading }
        guard let speed = speeds?[ModelIdentifier.resolve(model).model] ?? speeds?[model] else { return .unavailable }
        return .read(speed)
    }
}
