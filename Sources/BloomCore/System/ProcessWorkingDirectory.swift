import Darwin

/// The current directory of another process on this Mac, read from the kernel.
///
/// `proc_pidinfo` with `PROC_PIDVNODEPATHINFO` rather than `lsof`, because the bridge asks this
/// once per connection during a handshake that a CLI is waiting on, and a subprocess there is a
/// hundred milliseconds nobody needs to spend. It answers for any process owned by the same user,
/// which is every process that can reach Bloom's socket. See `BridgeOwnerPlacement` for the one
/// question it is asked.
public enum ProcessWorkingDirectory {
    public static func of(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}
