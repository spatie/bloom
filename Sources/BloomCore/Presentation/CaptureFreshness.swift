import Foundation

/// Whether a capture run is photographing the code that is in the tree, or an older build of it.
///
/// This exists because a capture lied and cost two people most of a morning. "Just a terminal" was
/// merged, and the picture taken to check it showed a footer with no such button in it. The button
/// was in the source, in the shared row every fit variant of the footer draws, and wired through
/// from the sheet. It was simply not in `.build/debug/Bloom`, which had last been linked twenty
/// minutes before the commit landed. Nothing in a PNG says which commit it is, so the picture read
/// as proof of a bug rather than as proof of a stale build, and the hunt went looking for a layout
/// fault that was never there.
///
/// Agents share one `.build` in this repository, so a binary that is behind the tree is the normal
/// state rather than an unusual one. The head of `Tools/master.sh` already says this about builds
/// meant to be installed. A capture is the same hazard with none of the same care: it is run by
/// hand, it takes seconds, and its whole purpose is to be believed.
///
/// Here rather than in `Snapshot` for the usual reason: the comparison and the sentence are a
/// decision the suite can hold, and the test target cannot see the app.
public enum CaptureFreshness: Equatable, Sendable {
    /// A build has been run since the last source change, so the picture is of this tree.
    case current
    /// A source file has changed since the last build. Whatever is photographed is the build from
    /// before that change.
    case stale
    /// There is no source tree beside this binary to compare against, which is every shipped copy
    /// and any build run from somewhere else. Nothing to say, rather than a guess.
    case unknowable

    /// Equal timestamps are current, not stale. A build stamps its record after it has read the
    /// sources, so the only way the two land on the same instant is an edit that arrived while the
    /// build was running, and calling that stale would refuse a tree the next build fixes anyway.
    public static func of(builtAt: Date?, newestSourceChangeAt: Date?) -> CaptureFreshness {
        guard let builtAt, let newestSourceChangeAt else { return .unknowable }
        return newestSourceChangeAt > builtAt ? .stale : .current
    }

    /// What the run says before it refuses, or nothing when there is nothing to refuse.
    ///
    /// It names the remedy rather than only the fault, because the person reading it is mid
    /// investigation and the next thing they do decides whether they chase a real bug or a ghost.
    public func refusal(flag: String) -> String? {
        guard self == .stale else { return nil }
        return """
            \(flag): this binary is older than the sources beside it, so the capture would show \
            the build from before your last change. Run `swift build` and take it again.
            """
    }
}
