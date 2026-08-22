import Foundation
import Testing
@testable import BloomCore

/// `FileEditor` writes into a worktree an agent may be editing at the same moment, and every rule
/// in it exists to stop a stale editor from destroying the agent's newer work. Nothing pinned any
/// of those rules until now, so a refactor could have quietly turned the byte comparison back into
/// a date comparison and no test would have said a word.
@Suite("Editing a file beside a working agent", .scratchDirectory)
struct FileEditorTests {
    private func makeFile(_ name: String, _ contents: String) throws -> String {
        let path = TestScratch.path(name)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - Reading

    @Test("a read hands back the bytes and a stamp that describes them")
    func readRoundTrips() throws {
        let path = try makeFile("plain.swift", "let x = 1\n")

        let file = try FileEditor.read(path)

        #expect(file.text == "let x = 1\n")
        #expect(file.path == path)
        #expect(file.size == 10)
        #expect(file.filename == "plain.swift")
    }

    @Test("a relative path is refused, because the writer cannot be trusted with a working directory")
    func relativePathIsRefused() {
        #expect(throws: FileEditorError.notAbsolute("relative.txt")) {
            try FileEditor.read("relative.txt")
        }
    }

    @Test("a file that is not there any more says so, rather than pretending to be empty")
    func missingFileIsMissing() {
        let path = TestScratch.path("never-written.txt")
        #expect(throws: FileEditorError.missing(path)) {
            try FileEditor.read(path)
        }
    }

    @Test("a directory is not a file to edit")
    func directoryIsRefused() throws {
        let path = TestScratch.path("a-folder")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        #expect(throws: FileEditorError.missing(path)) {
            try FileEditor.read(path)
        }
    }

    @Test("a NUL byte means binary, matching what the diff already calls binary")
    func binaryIsRefused() throws {
        let path = TestScratch.path("image.bin")
        try Data([0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]).write(to: URL(fileURLWithPath: path))

        #expect(throws: FileEditorError.notText(path)) {
            try FileEditor.read(path)
        }
    }

    @Test("bytes that are not UTF-8 are refused rather than mangled")
    func invalidUTF8IsRefused() throws {
        let path = TestScratch.path("latin1.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: URL(fileURLWithPath: path))

        #expect(throws: FileEditorError.notText(path)) {
            try FileEditor.read(path)
        }
    }

    @Test("a file past the size limit is refused before it is read whole")
    func oversizeIsRefused() throws {
        let path = TestScratch.path("bundle.js")
        let bytes = FileEditor.sizeLimit + 1
        try Data(count: 1).write(to: URL(fileURLWithPath: path))
        // Grown in place rather than built in memory, so the test does not allocate 4 MB of text.
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()

        // The grown tail is NUL bytes, but the size check has to come first: reading 4 MB to
        // discover it is binary is exactly what the limit exists to avoid.
        #expect(throws: FileEditorError.tooLarge(path: path, bytes: bytes)) {
            try FileEditor.read(path)
        }
    }

    // MARK: - Offering the editor

    @Test("what can be edited is decided the way read decides it, without reading everything")
    func editability() throws {
        let text = try makeFile("code.swift", "print(1)\n")
        let binary = TestScratch.path("blob.bin")
        try Data([0x00, 0x01]).write(to: URL(fileURLWithPath: binary))

        #expect(FileEditor.isEditable(text))
        #expect(!FileEditor.isEditable(binary))
        #expect(!FileEditor.isEditable(TestScratch.path("absent.txt")))
        #expect(!FileEditor.isEditable("relative.txt"))
    }

    // MARK: - Saving

    @Test("a save lands on disk and hands back a baseline that can keep editing")
    func saveRoundTrips() throws {
        let path = try makeFile("notes.md", "first\n")
        let baseline = try FileEditor.read(path)

        let next = try FileEditor.write("second\n", over: baseline)

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "second\n")
        #expect(next.text == "second\n")

        // The returned value is a real baseline, not a copy of the argument: saving again from it
        // must succeed without a fresh read.
        try FileEditor.write("third\n", over: next)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "third\n")
    }

    @Test("a file the agent rewrote after the read is not overwritten")
    func concurrentEditWins() throws {
        let path = try makeFile("shared.swift", "mine\n")
        let baseline = try FileEditor.read(path)

        try "the agent's newer work\n".write(toFile: path, atomically: true, encoding: .utf8)

        do {
            try FileEditor.write("mine, edited\n", over: baseline)
            Issue.record("the save went through over the agent's write")
        } catch {
            guard case .changedOnDisk = error else {
                Issue.record("expected changedOnDisk, got \(error)")
                return
            }
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "the agent's newer work\n")
    }

    @Test("the conflict check reads bytes, so a write inside the same timestamp tick is still caught")
    func sameStampDifferentBytesIsCaught() throws {
        let path = try makeFile("tick.swift", "aaaa\n")
        let baseline = try FileEditor.read(path)

        // Same length and, forced below, the same modification date: the only thing that gives
        // the second writer away is the bytes themselves.
        try "bbbb\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: baseline.modifiedAt], ofItemAtPath: path
        )

        do {
            try FileEditor.write("cccc\n", over: baseline)
            Issue.record("a date comparison would have waved this through")
        } catch {
            guard case .changedOnDisk = error else {
                Issue.record("expected changedOnDisk, got \(error)")
                return
            }
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "bbbb\n")
    }

    @Test("a file deleted after the read cannot be resurrected by a save")
    func deletedFileIsNotRecreated() throws {
        let path = try makeFile("gone.swift", "text\n")
        let baseline = try FileEditor.read(path)

        try FileManager.default.removeItem(atPath: path)

        #expect(throws: FileEditorError.missing(path)) {
            try FileEditor.write("back from the dead\n", over: baseline)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("a script keeps its executable bit across a save")
    func executableBitSurvives() throws {
        let path = try makeFile("run.sh", "#!/bin/sh\necho 1\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let baseline = try FileEditor.read(path)

        try FileEditor.write("#!/bin/sh\necho 2\n", over: baseline)

        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o755)
    }
}
