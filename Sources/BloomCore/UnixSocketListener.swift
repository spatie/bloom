import Foundation
import Synchronization

/// A listening unix domain socket, handing each accepted connection to a callback.
///
/// A `DispatchSource` rather than a thread blocked in `accept`. The connection count here is tiny,
/// one per running agent process, so a thread each would work; a source costs nothing when nobody
/// is connecting, which is almost always, and it cannot be left blocked on a descriptor that has
/// been closed underneath it.
public final class UnixSocketListener: Sendable {
    public let path: String
    private let descriptor: Int32
    private let source: any DispatchSourceRead
    /// Guards the once-ness of `stop`, which both the owner and `deinit` may reach: a second
    /// cancel is harmless, but a second unlink could remove a socket file a successor has
    /// already bound. `Mutex` rather than `NSLock` plus `@unchecked Sendable`, for the reason
    /// given on `EventFanout` in `SessionRunner`.
    private let stopped = Mutex(false)

    /// Binds and starts accepting.
    ///
    /// A socket file left behind by a crashed process is removed before binding, because bind
    /// refuses an existing name (EADDRINUSE) whether or not anything is listening on it. Removing
    /// it is safe for exactly one reason: the name carries a fingerprint of the database path, so
    /// the only process that could have created it is another instance holding the same database,
    /// and two of those cannot usefully run at once anyway.
    public init(path: String, accept handler: @escaping @Sendable (UnixSocketConnection) -> Void) throws {
        self.path = path

        var address = try UnixSocketAddress.make(path: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocketError.couldNotOpen(code: errno) }
        self.descriptor = descriptor

        unlink(path)
        // The socket file is created with the process umask applied, which on a default macOS
        // account leaves it group and world readable. Narrowed deliberately: anything that can
        // open this socket can speak as any session whose token it also has, and the token is
        // reachable by anything running as the user anyway, so this closes the one gap that is
        // free to close rather than pretending to close the others.
        let previousMask = umask(0o077)
        let bound = UnixSocketAddress.withSocketAddress(&address) { socketAddress, length in
            bind(descriptor, socketAddress, length)
        }
        umask(previousMask)
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw UnixSocketError.couldNotBind(path: path, code: code)
        }
        guard listen(descriptor, 16) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            unlink(path)
            throw UnixSocketError.couldNotListen(path: path, code: code)
        }
        // Non-blocking, so the drain loop below can stop on EAGAIN. A blocking listener would
        // leave the source's queue parked inside `accept` until the next connection arrived, which
        // is the same thread the cancel has to run on.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)

        source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "be.spatie.bloom.bridge.accept")
        )
        source.setEventHandler { [descriptor] in
            // The source fires once per readable event, and a burst of connections can arrive
            // between two of them, so this drains rather than accepting one and waiting to be
            // told again.
            while true {
                let accepted = Darwin.accept(descriptor, nil, nil)
                guard accepted >= 0 else { return }
                handler(UnixSocketConnection(descriptor: accepted))
            }
        }
        // The descriptor is closed here rather than in `stop`, because cancelling a source is
        // asynchronous: closing it first frees a number the source may still be about to use, and
        // the next thing to open a file gets it.
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    /// Stops listening and removes the socket file. Connections already accepted are not touched:
    /// they are owned by whoever took them.
    public func stop() {
        let claimed = stopped.withLock { stopped -> Bool in
            if stopped { return false }
            stopped = true
            return true
        }
        guard claimed else { return }

        source.cancel()
        unlink(path)
    }

    deinit {
        stop()
    }
}
