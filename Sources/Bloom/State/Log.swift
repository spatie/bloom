import Foundation
import os

/// Where the app says what it just refused to do.
///
/// Added because of one bug and the day it took to find it. Pressing "Archive and lose that work"
/// did nothing at all: the confirmation's dismissal cleared the state the button's action then
/// read back, the `guard else { return }` fired, and the app said nothing, drew nothing and left
/// the workspace exactly where it was. Finding it took hand-rolling a stderr probe and driving
/// the app under it, because the app target had no logging of any kind and 76 non-sleep `try?`.
///
/// So this is deliberately small, and it is not a tracing facility. It exists for the places
/// where the app decides not to do the thing it was just asked to do, and it exists so that
/// "I pressed it and nothing happened" leaves a line in Console naming what was refused and why.
/// The bar for a call site is that one question: if this returns here, is there any other way to
/// find out that it did?
///
/// Names and error text are logged `public`, not redacted. This is a developer tool reading its
/// own machine's Console, and a log line that says "could not archive <private>" is the same
/// silence in a different font.
enum Log {
    /// Archiving, restoring and the confirmations in front of them.
    static let archive = Logger(subsystem: subsystem, category: "archive")

    /// The composer, and anything that holds text somebody typed.
    static let composer = Logger(subsystem: subsystem, category: "composer")

    /// The updater, which mostly logs the checks and installs it decided not to do.
    static let updates = Logger(subsystem: subsystem, category: "updates")

    /// The install ping, which is silent everywhere else and so has nowhere else to say that it
    /// did not send.
    static let ping = Logger(subsystem: subsystem, category: "ping")

    /// The launch sweep for project artwork, which is the only work the app does that nobody
    /// asked for and that changes something on screen. When a badge is suddenly a picture, this
    /// is where it says which projects it looked at and how long it spent.
    static let icons = Logger(subsystem: subsystem, category: "icons")

    /// Permission questions: what was granted, and what a crash left unanswered.
    static let permissions = Logger(subsystem: subsystem, category: "permissions")

    /// The workspace bridge: the socket it bound, the handshakes it refused, and the sessions it
    /// could not register. Every one of those is a tool the agent silently does not have, which is
    /// invisible from inside a transcript.
    static let bridge = Logger(subsystem: subsystem, category: "bridge")

    /// The app's own bundle id, so an instance running against `BLOOM_DB_PATH` for a test can be
    /// told apart from the one somebody is using.
    private static let subsystem = Bundle.main.bundleIdentifier ?? "be.spatie.bloom"
}
