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

    private static let start: TimeInterval = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let started = info.kp_proc.p_starttime
        return TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000
    }()
}
