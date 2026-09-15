import Foundation
#if os(Linux)
import Glibc
#endif

/// Foundation's Linux Process inherits the spawning thread's signal mask. Swift worker threads
/// can block SIGINT/SIGTERM, which would make every descendant shell ignore terminal interrupts.
/// Keep the reset synchronous and thread-local, restoring the caller on both success and failure.
enum ProcessLaunch {
    static func run(_ process: Process) throws {
        #if os(Linux)
        var empty = sigset_t()
        var previous = sigset_t()
        sigemptyset(&empty)
        let error = pthread_sigmask(SIG_SETMASK, &empty, &previous)
        guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
        defer { _ = pthread_sigmask(SIG_SETMASK, &previous, nil) }
        #endif
        try process.run()
    }
}
