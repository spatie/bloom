import Foundation

/// How long this process has existed, measured from the moment the kernel created it.
///
/// Launch time is counted from there rather than from `main`, because everything before `main` is
/// part of what somebody waits through after clicking the Dock icon: dyld mapping and binding the
/// frameworks, and every static initialiser they carry. A clock started in `main` would report a
/// launch as fast as the part of it Bloom's own code controls, which is the flattering half.
public enum ProcessClock {
    /// Milliseconds since the process was created, or since first asked if the kernel will not say.
    public static func millisecondsSinceStart() -> Int {
        Int((Date().timeIntervalSince1970 - start) * 1000)
    }

    #if canImport(Darwin)
    private static let start: TimeInterval = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let started = info.kp_proc.p_starttime
        return TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000
    }()
    #else
    /// Linux has no `kinfo_proc`. Only the Mac app measures its launch, and the server this core is
    /// also built into has no Dock icon to wait on, so the first time it is asked is honest enough.
    private static let start: TimeInterval = Date().timeIntervalSince1970
    #endif
}
