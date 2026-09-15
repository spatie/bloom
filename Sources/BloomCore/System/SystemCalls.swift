import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// The few POSIX spellings that differ between Darwin and Linux stay at the descriptor boundary.
enum SystemCalls {
    static var streamSocketType: Int32 {
        #if os(Linux)
        Int32(SOCK_STREAM.rawValue)
        #else
        SOCK_STREAM
        #endif
    }

    static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if os(Linux)
        Glibc.read(descriptor, buffer, count)
        #else
        Darwin.read(descriptor, buffer, count)
        #endif
    }

    static func write(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if os(Linux)
        Glibc.write(descriptor, buffer, count)
        #else
        Darwin.write(descriptor, buffer, count)
        #endif
    }

    static func socketWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if os(Linux)
        Glibc.send(descriptor, buffer, count, Int32(MSG_NOSIGNAL))
        #else
        Darwin.write(descriptor, buffer, count)
        #endif
    }

    static func socketRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if os(Linux)
        Glibc.recv(descriptor, buffer, count, Int32(MSG_DONTWAIT))
        #else
        Darwin.recv(descriptor, buffer, count, MSG_DONTWAIT)
        #endif
    }

    static func close(_ descriptor: Int32) {
        #if os(Linux)
        _ = Glibc.close(descriptor)
        #else
        _ = Darwin.close(descriptor)
        #endif
    }

    static func connect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if os(Linux)
        Glibc.connect(descriptor, address, length)
        #else
        Darwin.connect(descriptor, address, length)
        #endif
    }

    static func accept(_ descriptor: Int32) -> Int32 {
        #if os(Linux)
        Glibc.accept(descriptor, nil, nil)
        #else
        Darwin.accept(descriptor, nil, nil)
        #endif
    }

    static func kill(_ pid: Int32, _ signal: Int32) {
        #if os(Linux)
        _ = Glibc.kill(pid, signal)
        #else
        _ = Darwin.kill(pid, signal)
        #endif
    }

    static func configurePipeWrites(_ descriptor: Int32) {
        #if os(Linux)
        _ = ignoredPipeSignal
        #else
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        #endif
    }

    #if os(Linux)
    // Linux has MSG_NOSIGNAL for sockets but no F_SETNOSIGPIPE for child-process pipes.
    private static let ignoredPipeSignal: Void = { _ = signal(SIGPIPE, SIG_IGN) }()
    #endif
}
