import Foundation

/// When a Bloom Server tidies its own rootless Docker, and what it removes when it does.
///
/// Measured on a 25 GB Ubuntu server with one Laravel project and two workspaces: images at
/// 7.45 GB, build cache at 4.8 GB and the disk 87% full. Nothing had ever been pruned, because
/// cleanup existed only behind a button in Server Settings, and every setup that rebuilt the
/// project's PHP image left the previous one dangling. This type holds the decisions and runs no
/// process; `ServerDockerHousekeeper` carries them out.
///
/// The claims are in memory, so a restarted server may prune once more than the interval says.
/// That is the cheap direction to be wrong in: the commands only remove what nothing refers to.
public struct ServerDockerHousekeeping: Sendable, Equatable {
    public enum Trigger: Sendable, Equatable {
        /// A workspace setup script exited successfully, so a rebuilt image may have left its
        /// predecessor dangling.
        case setupSucceeded
        /// A periodic check, or a setup that failed and may have failed for want of space.
        case diskCheck
    }

    public enum Prune: Sendable, Equatable {
        case danglingImages
        case danglingBuildCache
        case unusedBuildCache

        /// Never `image prune --all`, never volumes or containers. `builder prune` without
        /// `--all` removes only cache nothing refers to; the daemon's own gc cap bounds the rest.
        public var arguments: [String] {
            switch self {
            case .danglingImages: ["image", "prune", "--force"]
            case .danglingBuildCache: ["builder", "prune", "--force"]
            case .unusedBuildCache: ["builder", "prune", "--all", "--force"]
            }
        }
    }

    /// One PHP image rebuild on the measured server left roughly a gigabyte dangling, and a
    /// project can be set up several times in a few minutes while its script is being written.
    public static let setupInterval: TimeInterval = 600
    /// Build cache pruning makes the next build slower, so low space triggers it hourly at most.
    public static let lowDiskInterval: TimeInterval = 3_600
    /// How often the server looks at free space. A statfs call, so nearly free.
    public static let checkInterval: TimeInterval = 600

    /// Low means under 15% of the volume, but never under 3 GiB nor over 10 GiB. The measured
    /// server had 13% free, about 3.3 GiB, which a bare 3 GiB floor would have let pass, and a
    /// single Laravel image rebuild needs a few GiB to succeed. The 10 GiB ceiling keeps a large
    /// disk with 100 GiB free from pruning build cache it has every room to keep.
    public static let floorBytes: Int64 = 3 * 1_073_741_824
    public static let ceilingBytes: Int64 = 10 * 1_073_741_824
    public static let lowFraction = 0.15

    /// Free space left by the last low-space cleanup, when that was still low.
    public struct Shortfall: Sendable, Equatable {
        public var freeBytes: Int64
        public var checkedAt: Date
    }

    private(set) var lastSetupPrune: Date?
    private(set) var lastLowDiskPrune: Date?
    public private(set) var shortfall: Shortfall?

    public init() {}

    public static func threshold(totalBytes: Int64?) -> Int64 {
        guard let totalBytes, totalBytes > 0 else { return floorBytes }
        return min(ceilingBytes, max(floorBytes, Int64(Double(totalBytes) * lowFraction)))
    }

    /// Nil when the volume could not be measured, which never counts as low.
    public static func isLow(totalBytes: Int64?, freeBytes: Int64?) -> Bool? {
        guard let freeBytes, freeBytes >= 0 else { return nil }
        return freeBytes < threshold(totalBytes: totalBytes)
    }

    /// Claims the rate limits for whatever it returns, so a failed prune is not retried at once.
    public mutating func plan(_ trigger: Trigger, totalBytes: Int64?, freeBytes: Int64?, now: Date) -> [Prune] {
        var plan: [Prune] = []
        let low = Self.isLow(totalBytes: totalBytes, freeBytes: freeBytes)
        if low == false { shortfall = nil }
        if low == true, Self.elapsed(since: lastLowDiskPrune, now: now, atLeast: Self.lowDiskInterval) {
            lastLowDiskPrune = now
            // Dangling cache first. Only when that already left space low an hour ago is all
            // unused cache worth the slower builds that follow.
            plan += [shortfall == nil ? .danglingBuildCache : .unusedBuildCache, .danglingImages]
        }
        if trigger == .setupSucceeded, !plan.contains(.danglingImages),
           Self.elapsed(since: lastSetupPrune, now: now, atLeast: Self.setupInterval) {
            plan.append(.danglingImages)
        }
        // A low-space pass prunes the same dangling images, so it spends the setup interval too.
        if plan.contains(.danglingImages) { lastSetupPrune = now }
        return plan
    }

    /// Recorded after a low-space cleanup, measured again once its prunes have finished.
    public mutating func recordCleanup(totalBytes: Int64?, freeBytes: Int64?, now: Date) {
        if Self.isLow(totalBytes: totalBytes, freeBytes: freeBytes) == true, let freeBytes {
            shortfall = Shortfall(freeBytes: freeBytes, checkedAt: now)
        } else {
            shortfall = nil
        }
    }

    /// The sentence the disk check carries to connected clients while space stays low.
    public var notice: String? {
        guard let shortfall else { return nil }
        let gibibytes = String(format: "%.1f", Double(shortfall.freeBytes) / 1_073_741_824)
        return "Automatic Docker cleanup ran, but only \(gibibytes) GiB is free. "
            + "Archive workspaces you no longer need, or review Storage & Cleanup in Server Settings."
    }

    /// A clock that moved backwards must not hold cleanup off until it catches up.
    private static func elapsed(since last: Date?, now: Date, atLeast interval: TimeInterval) -> Bool {
        guard let last else { return true }
        let seconds = now.timeIntervalSince(last)
        return seconds < 0 || seconds >= interval
    }
}
