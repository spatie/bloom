import Foundation

/// What the live tail says while a tool call is running.
///
/// The stream names a tool before its input has finished arriving, so the first useful answer is
/// the readable tool name. Once the completed call arrives, `ToolPresenter` can use its input. For
/// Bash that gives the tail the same label as the saved row and replaces forty identical "Running
/// Bash" lines with the description the agent wrote for the command.
public struct RunningTool: Equatable, Sendable {
    /// How long a call may run before the clock is useful rather than flicker.
    public static let elapsedThreshold = 5

    public let label: String
    public let startedAt: Date?

    /// The provisional line shown while only the streamed name is known.
    public init(name: String) {
        label = name == AdvisorConsultation.toolName
            ? AdvisorConsultation.runningLabel
            : "Running \(MCPToolName.readable(name))"
        startedAt = nil
    }

    /// The line shown once the complete call and its input are known.
    public init(use: AgentToolUse, startedAt: Date = Date()) {
        let name = MCPToolName.readable(use.name)
        let presented = ToolPresenter.present(use).label
        // A presentation that adds no information keeps the running verb the old line carried.
        // A Bash description, a task type or another useful label replaces it.
        if use.name == AdvisorConsultation.toolName {
            label = AdvisorConsultation.runningLabel
        } else {
            label = presented == name ? "Running \(name)" : presented
        }
        self.startedAt = startedAt
    }

    /// The label plus a clock once this has become a wait somebody can feel.
    public func text(at now: Date) -> String {
        guard let startedAt else { return label }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        guard seconds >= Self.elapsedThreshold else { return label }
        return "\(label) · \(TurnDuration.wholeSeconds(seconds * 1_000))"
    }
}
