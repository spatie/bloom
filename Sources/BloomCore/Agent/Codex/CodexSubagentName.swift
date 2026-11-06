import Foundation

/// A Codex agent path is an identifier on the wire, but its last component is a name on screen.
enum CodexSubagentName {
    static func display(_ path: String, fallback: String = "") -> String {
        let name = ToolPresenter.basename(path)
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { String($0).capitalizedFirst }
            .joined(separator: " ")
        return name.isEmpty ? fallback : name
    }
}
