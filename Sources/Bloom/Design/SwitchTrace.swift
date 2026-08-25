import Foundation
import QuartzCore
import BloomCore

/// A timeline of one workspace switch, from the click to the frame that shows the workspace.
///
/// This exists because "switching takes about a second" is an impression, and an impression cannot
/// say whether the second is spent in SQLite, in a `git` subprocess, in `gh` asking GitHub about a
/// pull request, or in SwiftUI laying out four thousand transcript rows. Every one of those was a
/// candidate and only one of them turned out to matter.
///
/// Two kinds of mark, and the difference is the whole point:
///
/// - `mark` stamps the moment a piece of work finished. It says when the data existed.
/// - `markOnScreen` stamps the first display link tick after that, which is the first vsync whose
///   frame could contain the work. It says when the user could see it. The gap between the two is
///   the layout and render cost, and for a long transcript that gap is most of the switch.
///
/// Off unless a probe run turns it on, and every call site is one `if` against a static Bool, so a
/// build nobody is measuring pays nothing for it.
@MainActor
enum SwitchTrace {
    static var isEnabled = false

    /// One stamped moment in a switch.
    struct Mark: Sendable {
        var name: String
        var ms: Double
        /// Whether this is a vsync stamp rather than a work stamp. See the note above.
        var onScreen: Bool
    }

    private(set) static var marks: [Mark] = []
    private(set) static var workspaceID: WorkspaceID?
    private static var start: CFTimeInterval = 0
    private static var seen: Set<String> = []
    /// Names waiting for the next display link tick, in the order they were asked for.
    private static var pendingOnScreen: [String] = []

    /// Starts a new timeline. Everything stamped from here on is measured from this instant.
    static func begin(workspaceID id: WorkspaceID) {
        guard isEnabled else { return }
        marks = []
        seen = []
        pendingOnScreen = []
        workspaceID = id
        start = CACurrentMediaTime()
    }

    /// Stamps the moment some work finished, the first time it does.
    ///
    /// First time only, because most of these call sites run again on a poll: `refreshChanges`
    /// lands every six seconds for the rest of the launch, and a timeline that recorded all of
    /// them would say nothing about the switch.
    ///
    /// `id` is checked against the workspace being timed, so an answer arriving for the workspace
    /// the user has just left cannot be stamped onto the one they are now on. That is the same
    /// rule the app itself has to follow, and having it here is what proved the app was not
    /// following it.
    static func mark(_ name: String, workspace id: WorkspaceID? = nil) {
        guard isEnabled, start > 0 else { return }
        if let id, id != workspaceID { return }
        guard seen.insert(name).inserted else { return }
        marks.append(Mark(name: name, ms: (CACurrentMediaTime() - start) * 1000, onScreen: false))
    }

    /// Asks for a stamp at the next vsync, which is the first frame that can show what was just
    /// written. Paired with `mark` at the same call site, the two bracket the render.
    static func markOnScreen(_ name: String, workspace id: WorkspaceID? = nil) {
        guard isEnabled, start > 0 else { return }
        if let id, id != workspaceID { return }
        guard !seen.contains(name + ".onscreen") else { return }
        pendingOnScreen.append(name)
    }

    /// Called by the probe's display link, once per vsync.
    static func tick() {
        guard isEnabled, start > 0, !pendingOnScreen.isEmpty else { return }
        let ms = (CACurrentMediaTime() - start) * 1000
        for name in pendingOnScreen {
            guard seen.insert(name + ".onscreen").inserted else { continue }
            marks.append(Mark(name: name + ".onscreen", ms: ms, onScreen: true))
        }
        pendingOnScreen.removeAll()
    }

    /// The timeline as JSON, sorted by when things happened.
    ///
    /// `JSONValue` rather than the `[String: Any]` this used to hand back, for the reason written
    /// at the head of `ProbeHarness`: a dictionary of `Any` is what let a typed id reach
    /// `JSONSerialization` and kill a twenty minute run on its last line. Nothing that goes into a
    /// report can be a value JSON cannot carry any more, and the compiler is what says so.
    static func timeline() -> JSONValue {
        .array(
            marks
                .sorted { $0.ms < $1.ms }
                .map {
                    .object([
                        "name": .string($0.name),
                        "ms": .number($0.ms),
                        "onScreen": .bool($0.onScreen),
                    ])
                }
        )
    }
}
