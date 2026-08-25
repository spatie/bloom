import Foundation
import Testing
@testable import BloomCore

/// What a file a page hands over is called, how far it has got, and how many of them it may send.
@Suite("Browser downloads")
struct BrowserDownloadTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The name a page chose

    @Test("A name that is really a path can only ever name a file in the download folder")
    func aPathIsNotAName() {
        #expect(BrowserDownloadFile.name(from: "../../../etc/passwd") == "passwd")
        #expect(BrowserDownloadFile.name(from: "/Users/freek/.ssh/id_ed25519") == "id_ed25519")
        #expect(BrowserDownloadFile.name(from: "a/b/report.pdf") == "report.pdf")
    }

    @Test("A leading dot goes, because a download the reader cannot see is one he cannot check")
    func aHiddenNameIsUnhidden() {
        #expect(BrowserDownloadFile.name(from: ".zshrc") == "zshrc")
        #expect(BrowserDownloadFile.name(from: "...hidden.sh") == "hidden.sh")
    }

    @Test("A name with nothing left in it is still a name")
    func anEmptyNameGetsOne() {
        #expect(BrowserDownloadFile.name(from: "") == "download")
        #expect(BrowserDownloadFile.name(from: "..") == "download")
        #expect(BrowserDownloadFile.name(from: "   ") == "download")
        #expect(BrowserDownloadFile.name(from: "/") == "download")
    }

    @Test("Control characters and separators go, so a name draws as what it is")
    func aNameIsReadable() {
        #expect(BrowserDownloadFile.name(from: "in\u{0}voi\u{7}ce.pdf") == "invoice.pdf")
        #expect(BrowserDownloadFile.name(from: "a:b.txt") == "ab.txt")
    }

    @Test("A very long name is cut and keeps its extension")
    func aLongNameKeepsItsExtension() {
        let long = String(repeating: "a", count: 500) + ".zip"
        let name = BrowserDownloadFile.name(from: long)
        #expect(name.count == BrowserDownloadFile.nameLimit)
        #expect(name.hasSuffix(".zip"))
    }

    // MARK: - Not writing over somebody's file

    @Test("A free name is used as it is")
    func aFreeNameIsKept() {
        #expect(BrowserDownloadFile.filename(for: "report.pdf", isTaken: { _ in false })
            == "report.pdf")
    }

    @Test("A taken name is numbered around rather than written over")
    func aTakenNameIsNumbered() {
        let taken: Set<String> = ["report.pdf", "report-2.pdf"]
        let name = BrowserDownloadFile.filename(for: "report.pdf") { taken.contains($0) }
        #expect(name == "report-3.pdf")
    }

    @Test("A name with no extension is numbered too")
    func anExtensionlessNameIsNumbered() {
        let taken: Set<String> = ["Makefile"]
        let name = BrowserDownloadFile.filename(for: "Makefile") { taken.contains($0) }
        #expect(name == "Makefile-2")
    }

    @Test("A folder that is full of that name still never returns one that is taken")
    func aFullFolderStillAnswers() {
        let name = BrowserDownloadFile.filename(for: "x.txt") { $0 != "x-1001.txt" }
        #expect(name != "x.txt")
        #expect(name.hasSuffix(".txt"))
    }

    // MARK: - How far it has got

    @Test("Bytes are counted in the units the platform writes them in")
    func sizesReadLikeFinder() {
        #expect(BrowserDownloadFile.size(0) == "0 bytes")
        #expect(BrowserDownloadFile.size(999) == "999 bytes")
        #expect(BrowserDownloadFile.size(1_000) == "1.0 kB")
        #expect(BrowserDownloadFile.size(1_500_000) == "1.5 MB")
        #expect(BrowserDownloadFile.size(2_400_000_000) == "2.4 GB")
    }

    @Test("A server that sends no length says only what has arrived")
    func anUnknownLengthSaysWhatItKnows() {
        #expect(BrowserDownloadFile.progress(received: 2_000, expected: 0) == "2.0 kB")
        #expect(BrowserDownloadFile.progress(received: 2_000, expected: 8_000)
            == "2.0 kB of 8.0 kB")
    }

    // MARK: - How many

    @Test("A reader pressing a download button is never asked about it")
    func anOrdinaryDownloadIsSaved() {
        var downloads = BrowserDownloads()
        #expect(downloads.request(from: "localhost:3100", at: Self.start) == .save)
    }

    @Test("A page in a loop is stopped, and says so once")
    func aLoopIsStopped() {
        var downloads = BrowserDownloads(limit: 2, window: 5)
        #expect(downloads.request(from: "localhost:3100", at: Self.start) == .save)
        #expect(downloads.request(from: "localhost:3100", at: Self.start) == .save)

        let third = downloads.request(from: "localhost:3100", at: Self.start)
        guard case .refuseAndSay(let notice) = third else {
            Issue.record("the third download in a burst should be refused, got \(third)")
            return
        }
        #expect(notice.title.contains("localhost:3100"))

        for _ in 0..<100 {
            #expect(downloads.request(from: "localhost:3100", at: Self.start) == .refuse)
        }
    }
}
