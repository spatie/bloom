import Foundation

public struct ComposerModelSection: Identifiable, Equatable, Sendable {
    public var kind: AgentKind
    public var options: [ComposerOption]
    public var id: String { kind.rawValue }
    public var title: String { kind.label }
    public init(kind: AgentKind, options: [ComposerOption]) { self.kind = kind; self.options = options }
}
