import Foundation

/// Each revision keeps its exact text. A handoff refers to that revision even if planning
/// continues in the original conversation while implementation is running elsewhere.
public struct PlanArtefact: Identifiable, Codable, Sendable, Hashable {
    public var id: PlanArtefactID
    public var sessionID: SessionID
    public var sourceID: String
    public var version: Int
    public var markdown: String
    public var createdAt: Date
    public var implementationSessionID: SessionID?

    public init(
        id: PlanArtefactID = .new(), sessionID: SessionID, sourceID: String,
        version: Int, markdown: String, createdAt: Date = Date(),
        implementationSessionID: SessionID? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sourceID = sourceID
        self.version = version
        self.markdown = markdown
        self.createdAt = createdAt
        self.implementationSessionID = implementationSessionID
    }

    public var title: String {
        let heading = markdown.components(separatedBy: .newlines).first {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
        let text = heading?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) ?? "Plan"
        return text.isEmpty ? "Plan" : String(text.prefix(120))
    }

    public var implementationPrompt: String {
        "Implement this plan (revision \(version)):\n\n\(markdown)"
    }

    public static func storageKey(sessionID: SessionID) -> String { "session.\(sessionID).plans" }
    public static func sourceKey(sessionID: SessionID) -> String { "session.\(sessionID).sourcePlan" }
}
