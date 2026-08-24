import Foundation

/// Runs `work` on the main actor, now if we are already there and on the next turn of the main
/// queue if we are not.
///
/// **This exists for the two places where the main-actor guarantee is somebody else's.** Every
/// other `MainActor.assumeIsolated` in this app is backed by a guarantee the app itself makes: a
/// notification it posted, a callback it registered on a queue it chose. Two are not:
///
/// - `TerminalView`'s `processTerminated`, which is SwiftTerm's. `LocalProcess` dispatches on
///   `DispatchQueue.main` unless told otherwise and `LocalProcessTerminalView` never tells it
///   otherwise, which is true of SwiftTerm 1.18.0 and is a reading of somebody else's source.
/// - `SoftwareUpdater`'s two KVO observers, which are Sparkle's. KVO fires on whichever thread
///   mutated the property, and nothing documents which thread that is.
///
/// Both are pinned open-ended in `Package.swift`, so a resolve can move them. And the failure
/// mode of `assumeIsolated` being wrong is not a wrong pixel, it is a **fatal trap**: a terminal
/// exiting, or the first update check of a launch, would take the app down with every agent's
/// unsaved work in it. That is a large consequence for a guarantee neither library writes down.
///
/// The hop is the whole of the fix and it costs nothing on the path that was already correct.
/// `DispatchQueue.main.async` rather than a `Task`, so work stays in order with everything else
/// already queued on the main thread: a terminal's exit arriving after the output that preceded
/// it is the point.
func hopToMain(_ work: @MainActor @escaping @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(work)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}
