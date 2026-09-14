import Foundation

/// Planning describes the requested work, independently of permission to change files.
public enum InteractionMode: String, Codable, CaseIterable, Sendable, Hashable {
    case build
    case plan

    public var label: String { self == .plan ? "Plan" : "Build" }

    public static func supports(_ agent: AgentKind) -> Bool { agent == .codex }

    public func nearest(on agent: AgentKind) -> InteractionMode {
        Self.supports(agent) ? self : .build
    }

    /// Verified against the schema emitted by codex-cli 0.153.4. Null instructions preserve
    /// Codex's own planning instructions instead of copying a second application's prompt.
    public func codexSettings(model: String, effort: String?) -> JSONValue {
        .object([
            "mode": .string(self == .plan ? "plan" : "default"),
            "settings": .object([
                "model": .string(model),
                "reasoning_effort": effort.flatMap { $0.isEmpty ? nil : .string($0) } ?? .null,
                "developer_instructions": .null,
            ]),
        ])
    }
}
