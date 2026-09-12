import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Clients may send an administrative credential here. Every ancestor and the socket itself
/// must belong to root, so a workspace process cannot redirect the relay to capture that key.
enum ServerMaintenanceRoute {
    static func path(directory: String) -> String {
        "/run/bloom-maintenance/" + TmuxSessions.fingerprint(ServerDaemon.databasePath(directory: directory)) + ".sock"
    }

    static func available(directory: String) -> String? {
        #if os(Linux)
        let path = path(directory: directory)
        for component in ["/run", "/run/bloom-maintenance"] {
            var info = stat()
            guard lstat(component, &info) == 0, info.st_uid == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_mode & 0o022 == 0 else { return nil }
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), info.st_mode & 0o007 == 0 else { return nil }
        return path
        #else
        return nil
        #endif
    }
}
