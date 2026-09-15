import Foundation
import Testing
@testable import BloomCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite struct ServerSkillDirectoryTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skill-directory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func invalidPathsDoNotRetainDescriptorsForThisDirectory() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let directory = try ServerSkillDirectory(path: url.path)
        let before = try descriptorCount(matching: directory.descriptor)
        for _ in 0..<100 {
            for path in ["../escape", "nested//child", "bad\0name"] {
                #expect(throws: Error.self) { _ = try directory.directory(path) }
            }
        }
        // Match this fixture's inode rather than global descriptor counts, since other suites
        // legitimately open sockets and subprocess pipes while this test is running.
        #expect(try descriptorCount(matching: directory.descriptor) == before)
        #expect(try directory.names().isEmpty)
    }

    @Test func directoryDuplicatesStayCloseOnExec() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let root = try ServerSkillDirectory(path: url.path)
        let duplicate = try root.directory("")
        let child = try root.directory("nested", create: true)
        for directory in [root, duplicate, child] {
            let flags = fcntl(directory.descriptor, F_GETFD)
            #expect(flags >= 0)
            #expect(flags & FD_CLOEXEC != 0)
        }
        let before = try descriptorCount(matching: root.descriptor)
        for _ in 0..<100 { #expect(try root.names() == ["nested"]) }
        #expect(try descriptorCount(matching: root.descriptor) == before)
    }

    private func descriptorCount(matching descriptor: Int32) throws -> Int {
        var expected = stat()
        guard fstat(descriptor, &expected) == 0 else { throw ServerSkillDirectory.failure }
        let path = FileManager.default.fileExists(atPath: "/proc/self/fd") ? "/proc/self/fd" : "/dev/fd"
        return try FileManager.default.contentsOfDirectory(atPath: path).filter { name in
            guard let number = Int32(name) else { return false }
            var info = stat()
            return fstat(number, &info) == 0 && info.st_dev == expected.st_dev && info.st_ino == expected.st_ino
        }.count
    }
}
