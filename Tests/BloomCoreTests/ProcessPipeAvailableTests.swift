import Foundation
import Testing
@testable import BloomCore

struct ProcessPipeAvailableTests {
    @Test func shortInputDoesNotWaitForEOFAndIdleIsNotEOF() throws {
        let pipe = Pipe()
        #expect(try ProcessPipeReader.available(from: pipe.fileHandleForReading) == nil)
        try pipe.fileHandleForWriting.write(contentsOf: Data("first\n".utf8))
        #expect(try ProcessPipeReader.available(from: pipe.fileHandleForReading) == Data("first\n".utf8))
        #expect(try ProcessPipeReader.available(from: pipe.fileHandleForReading) == nil)
        try pipe.fileHandleForWriting.write(contentsOf: Data("second\n".utf8))
        try pipe.fileHandleForWriting.close()
        #expect(try ProcessPipeReader.available(from: pipe.fileHandleForReading) == Data("second\n".utf8))
        #expect(try ProcessPipeReader.available(from: pipe.fileHandleForReading) == Data())
    }
}
