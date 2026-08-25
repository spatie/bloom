import Foundation
import CoreServices
import Synchronization

/// Tells the app which worktrees have actually changed, so the six second loop stops asking git
/// about the ones that have not.
///
/// # Why this exists
///
/// `DiffRefreshSchedule` carries the measurement the polling loop was cut down by: one pass over
/// one worktree is six `git` processes, seventeen of them cost 2,864ms of process time, and the
/// answer was to ask about fewer of them per tick. That is the best a poll can do, and it is still
/// the wrong shape: every one of those processes runs to find out whether anything happened, and
/// on an idle machine the answer is always no. `IdleProbe` over three of this machine's small
/// worktrees measures 18 processes and 105ms of CPU per pass with nothing happening at all, and
/// one pass in five of that run took 3,499ms of child CPU, which is what a big repository costs
/// when the answer is still no.
///
/// So the file system is asked to say when something happens instead. A worktree that has changed
/// is refreshed on the next tick rather than up to a minute later, and a worktree that has not is
/// not asked about at all until the backstop age comes round.
///
/// # What it reports, and what it deliberately does not
///
/// The root that changed, and nothing else. Not the file, not the kind of change: everything the
/// app does with this is "ask git about that worktree", and git is the only thing here that can
/// say what a change means. Reporting less is also what makes the coalescing safe, because two
/// hundred writes inside one directory are one answer.
///
/// `.git` is deliberately NOT excluded. A commit, a checkout, a stash and an index update all move
/// what `git diff` says and all of them land in there, and a watcher that ignored it would leave
/// the counts stale for exactly the operations an agent performs most.
///
/// # Why one stream for every worktree rather than one each
///
/// FSEvents takes a list of paths and answers with the path that changed, so a single stream
/// covers every workspace in the sidebar for the cost of one. Twenty streams would be twenty
/// kernel subscriptions and twenty queues to shut down in the right order when the list moves,
/// which it does on every workspace created, archived or restored.
public final class WorktreeWatcher: Sendable {
    /// What a batch of file system events becomes: the worktree roots that changed.
    private let onChange: @Sendable (Set<String>) -> Void

    /// How long FSEvents holds events back to coalesce them.
    ///
    /// One second, which is the same order as the tick this feeds and an eternity next to the
    /// write storm a `git checkout` or an agent's edit produces. The point of the latency is that
    /// a thousand writes arrive as one wake-up; making it shorter would buy a refresh that lands
    /// in the same tick either way.
    public static let latency: TimeInterval = 1

    private struct Watched {
        var stream: FSEventStreamRef?
        /// The roots as the caller spelled them, which is what a change is reported back as and
        /// what a second call is compared against.
        var given: [String] = []
        /// The same roots with every symlink resolved, longest first so that a nested worktree is
        /// matched before the checkout it sits inside. FSEvents answers with the real path
        /// whatever it was handed, so this is the spelling an event can be compared with.
        var matching: [String] = []
        /// Real path back to the spelling the caller uses.
        var origins: [String: String] = [:]
    }

    private let watched = Mutex(Watched())
    private let queue = DispatchQueue(label: "be.spatie.bloom.worktree-watcher", qos: .utility)

    public init(onChange: @escaping @Sendable (Set<String>) -> Void) {
        self.onChange = onChange
    }

    deinit {
        // Not `stop()`, which takes the lock: nothing else can hold a reference by the time this
        // runs, and the stream still has to be released or the kernel subscription outlives us.
        watched.withLock { state in
            Self.tearDown(state.stream)
            state.stream = nil
        }
    }

    /// Points the watcher at exactly these worktrees, replacing whatever it was watching.
    ///
    /// Rebuilt rather than amended, because FSEvents has no way to add a path to a running stream
    /// and the list changes only when a workspace is created, archived or restored. A call that
    /// names the same roots as last time does nothing at all, which is what makes it safe to call
    /// from the same place the workspace list is published from.
    public func watch(roots: [String]) {
        let wanted = Self.ordered(roots)
        watched.withLock { state in
            guard state.given != wanted else { return }
            Self.tearDown(state.stream)
            state.given = wanted
            var origins: [String: String] = [:]
            for root in wanted { origins[Self.resolve(root)] = root }
            state.origins = origins
            state.matching = Self.ordered(Array(origins.keys))
            state.stream = wanted.isEmpty ? nil : makeStream(for: wanted)
        }
    }

    /// Stops watching, permanently. Called when the app is going away; `watch(roots: [])` is the
    /// way to stop watching and carry on.
    public func stop() {
        watched.withLock { state in
            Self.tearDown(state.stream)
            state.stream = nil
            state.given = []
            state.matching = []
            state.origins = [:]
        }
    }

    // MARK: - The stream

    private func makeStream(for roots: [String]) -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // `.fileEvents` is deliberately absent. Directory level events are what this reports
        // anyway, and per-file events would be thousands of callbacks for one `npm install`.
        // `.noDefer` makes the first event of a burst arrive at the start of the latency window
        // rather than the end, so a single save is seen a second sooner than a storm is.
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, _, _ in
                guard let info, count > 0 else { return }
                let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue()
                let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                watcher.report(changed)
            },
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        ) else { return nil }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        return stream
    }

    private static func tearDown(_ stream: FSEventStreamRef?) {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// One batch of events, reduced to the worktrees they happened in.
    ///
    /// A path that matches no root is dropped rather than reported: FSEvents answers about the
    /// directory it watched when a root itself is moved or deleted, and a caller told about a
    /// worktree it does not have would ask git about a path that is not there.
    private func report(_ paths: [String]) {
        let (matching, origins) = watched.withLock { ($0.matching, $0.origins) }
        let changed = Self.roots(of: paths, in: matching).compactMap { origins[$0] }
        guard !changed.isEmpty else { return }
        onChange(Set(changed))
    }

    // MARK: - The arithmetic, which is the part worth testing

    /// The roots a batch of changed paths belong to.
    ///
    /// Longest root first, so a worktree nested inside another checkout is attributed to itself
    /// rather than to its parent. A trailing separator is required on the match so that
    /// `/a/workspaces/beta-two` is not read as a change inside `/a/workspaces/beta`.
    public static func roots(of paths: [String], in roots: [String]) -> Set<String> {
        var changed: Set<String> = []
        for path in paths {
            let standardised = standardise(path)
            for root in roots where standardised == root || standardised.hasPrefix(root + "/") {
                changed.insert(root)
                break
            }
        }
        return changed
    }

    /// The roots as they are compared: standardised, deduplicated, and longest first.
    public static func ordered(_ roots: [String]) -> [String] {
        Array(Set(roots.map(standardise))).sorted { $0.count > $1.count }
    }

    /// A path with every symlink resolved, which is the spelling FSEvents reports in.
    ///
    /// `realpath` rather than `URL.resolvingSymlinksInPath`, which on this platform does the
    /// opposite of what its name promises for the one directory that needs it: handed
    /// `/private/var/folders/...` it answers `/var/folders/...`, so a watcher that trusted it
    /// matched none of its own events under `NSTemporaryDirectory`. Resolved once per change to
    /// the workspace list rather than per event.
    ///
    /// A path that does not exist resolves to itself, which is right: a worktree removed from
    /// under the watcher has nothing to compare against and nothing left to report.
    static func resolve(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return standardise(path) }
        defer { free(real) }
        return standardise(String(cString: real))
    }

    /// A path with its trailing separator removed.
    private static func standardise(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
