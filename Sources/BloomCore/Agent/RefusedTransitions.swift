import Foundation
import os
import Synchronization

/// Where a lifecycle says it was asked for something that cannot happen.
///
/// **What an illegal transition does, and why it is not a crash.** Three of the writes that move
/// these states happen during `AppModel.bootstrap`, before a window exists: the sessions left
/// running by the last launch, the questions they were blocked on, and the setup scripts that died
/// with them. Bloom is developed in Bloom and the owner is using it right now, holding real
/// worktrees, so a machine that traps on a bad transition turns a wrong enum into an app that
/// cannot open, and the row it was protecting is still there on the next attempt. A `precondition`
/// in that position is not a safety net, it is a lock on the door of a building somebody is
/// already inside.
///
/// Throwing is the other obvious answer and it is worse than it looks. Every caller of a
/// transition would have to decide what to do with the error, in paths that are already `try?` for
/// good reasons (a setup script's outcome must not be lost because SQLite was busy), so the errors
/// would be swallowed at almost every site and the machine would have bought nothing but noise.
///
/// So a refused transition **refuses**: the state is left holding what it had, which is by
/// construction a state it was legally moved into, and the attempt is recorded here and written to
/// the log. `AppLogExcerpt` picks the log up, so a refusal is in the feedback report the owner
/// sends without anybody having to reproduce it, and `count` is readable from a test so the suite
/// can assert that correct code refuses nothing.
///
/// What it must never do is succeed quietly, which is the state every one of these enums was in
/// before this file existed.
///
/// Deliberately not an actor. This is reached from `Workspace.apply` and `Session.apply`, which
/// are synchronous mutating methods on value types called from inside `Store`'s actor, and an
/// `await` there would open a suspension point in the middle of the one read and write that
/// `Store.update` promises has none. A `Mutex` around an array of at most `limit` entries costs
/// nothing on a path that, when the code is right, is never taken at all.
public enum RefusedTransitions {
    /// One attempt that was turned down, in the terms a reader needs to find it: which lifecycle,
    /// what it was holding, and what it was asked to do.
    public struct Entry: Sendable, Hashable {
        /// The lifecycle, named after the enum it governs: `setup`, `session`.
        public var machine: String
        public var from: String
        public var event: String
        public var at: Date

        public init(machine: String, from: String, event: String, at: Date = Date()) {
            self.machine = machine
            self.from = from
            self.event = event
            self.at = at
        }

        /// One line, and the same line the log gets, so what a test asserts on and what the owner
        /// reads in Console cannot drift apart.
        public var sentence: String {
            "\(machine) refused \(event) from \(from)"
        }
    }

    /// Enough to see a pattern, few enough that a loop gone wrong cannot eat memory. A refusal is
    /// a bug, and a bug that has happened two hundred times has told you everything it is going to.
    private static let limit = 200

    private static let entries = Mutex<[Entry]>([])
    private static let refusals = Mutex<Int>(0)

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "be.spatie.bloom",
        category: "transitions"
    )

    /// Called by a lifecycle, never by a caller of one.
    ///
    /// Logged `public` rather than redacted, for the reason `Log` in the app target gives: nothing
    /// here is anybody's data. A machine name, a state and an event are three words out of an enum
    /// that is in the source, and a line saying "<private> refused <private> from <private>" is
    /// the same silence in a different font.
    static func record(machine: String, from: String, event: String, at: Date = Date()) {
        let entry = Entry(machine: machine, from: from, event: event, at: at)
        refusals.withLock { $0 += 1 }
        entries.withLock {
            $0.append(entry)
            if $0.count > limit { $0.removeFirst($0.count - limit) }
        }
        log.error("\(entry.sentence, privacy: .public)")
    }

    /// What has been refused this launch, oldest first.
    public static var recent: [Entry] { entries.withLock { $0 } }

    /// How many transitions have been refused, including any dropped from `recent`.
    ///
    /// The number a test asserts is zero. Correct code refuses nothing, and a suite that lets this
    /// climb is a suite watching a machine fire on the happy path, which is how a rule stops being
    /// believed.
    public static var count: Int { refusals.withLock { $0 } }

    /// For a test that has just proved a refusal and does not want to leave it lying around for
    /// the next one. Not for production code: a refusal is evidence and nothing in the app has any
    /// business throwing evidence away.
    public static func forget() {
        entries.withLock { $0 = [] }
        refusals.withLock { $0 = 0 }
    }
}
