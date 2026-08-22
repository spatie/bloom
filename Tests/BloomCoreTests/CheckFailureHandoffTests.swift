import Foundation
import Testing
@testable import BloomCore

@Suite("Handing a failed check to an agent")
struct CheckFailureHandoffTests {
    // MARK: - Which log to ask for

    @Test("A job URL names the job, so a matrix hands over the one that failed")
    func readsJob() {
        let target = CheckFailureHandoff.logTarget(
            detailsURL: "https://github.com/spatie/bloom/actions/runs/42/job/99"
        )
        #expect(target == CheckFailureHandoff.LogTarget(runID: "42", jobID: "99"))
    }

    @Test("A rerun puts an attempt between the run and the job, and both are still found")
    func readsRerun() {
        let target = CheckFailureHandoff.logTarget(
            detailsURL: "https://github.com/spatie/bloom/actions/runs/42/attempts/2/job/99"
        )
        #expect(target == CheckFailureHandoff.LogTarget(runID: "42", jobID: "99"))
    }

    @Test("A bare run URL is still a log worth fetching")
    func readsRun() {
        let target = CheckFailureHandoff.logTarget(
            detailsURL: "https://github.com/spatie/bloom/actions/runs/42"
        )
        #expect(target == CheckFailureHandoff.LogTarget(runID: "42", jobID: nil))
    }

    @Test("A commit status pointing somewhere else has no log gh could fetch")
    func refusesForeignURLs() {
        #expect(CheckFailureHandoff.logTarget(detailsURL: nil) == nil)
        #expect(CheckFailureHandoff.logTarget(detailsURL: "") == nil)
        #expect(CheckFailureHandoff.logTarget(detailsURL: "https://circleci.com/gh/x/1") == nil)
        #expect(CheckFailureHandoff.logTarget(detailsURL: "https://github.com/spatie/bloom/pull/7") == nil)
        // Somebody else's host with our path on it is not our host.
        #expect(CheckFailureHandoff.logTarget(detailsURL: "https://github.com.evil.test/actions/runs/42") == nil)
    }

    @Test("A run id that is not a number is not a run id")
    func refusesNonNumericRun() {
        #expect(CheckFailureHandoff.logTarget(detailsURL: "https://github.com/a/b/actions/runs/latest") == nil)
    }

    // MARK: - Cleaning

    @Test("gh's job and step prefix comes off, because the sentence above already says it")
    func stripsPrefix() {
        let line = "build\tRun tests\t2026-08-22T14:05:11.1234567Z boom"
        #expect(CheckFailureHandoff.clean(line) == ["boom"])
    }

    @Test("A line with no prefix is passed through rather than cut by guesswork")
    func keepsPlainLines() {
        #expect(CheckFailureHandoff.clean("just a line") == ["just a line"])
        #expect(CheckFailureHandoff.clean("a\tb") == ["a\tb"])
    }

    @Test("Terminal colour is not worth a token")
    func stripsAnsi() {
        #expect(CheckFailureHandoff.clean("\u{1B}[0;31mfailed\u{1B}[0m") == ["failed"])
    }

    // MARK: - How much of a log

    @Test("A short log is handed over whole")
    func keepsShortLogs() {
        let log = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = CheckFailureHandoff.excerpt(log)
        #expect(!excerpt.isTruncated)
        #expect(excerpt.totalLines == 20)
        #expect(excerpt.text == log)
    }

    @Test("A long log keeps both ends, because the first error is not always the last one")
    func keepsBothEnds() {
        let log = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = CheckFailureHandoff.excerpt(log, headLines: 5, tailLines: 5)

        #expect(excerpt.isTruncated)
        #expect(excerpt.totalLines == 1000)
        #expect(excerpt.droppedLines == 990)
        #expect(excerpt.text.contains("line 1\n"))
        #expect(excerpt.text.contains("line 5\n"))
        #expect(excerpt.text.contains("line 996"))
        #expect(excerpt.text.hasSuffix("line 1000"))
        #expect(!excerpt.text.contains("line 500"))
    }

    @Test("A cut says it is a cut, so nothing reasons about half a log without knowing")
    func admitsTheCut() {
        let log = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = CheckFailureHandoff.excerpt(log, headLines: 5, tailLines: 5)
        #expect(excerpt.text.contains("990 lines of this log are not shown"))
    }

    @Test("One enormous line cannot get through the line budget")
    func capsCharacters() {
        let excerpt = CheckFailureHandoff.excerpt(
            String(repeating: "x", count: 50_000), maxCharacters: 100
        )
        #expect(excerpt.text.count < 200)
        #expect(excerpt.text.contains("the rest of this log is not shown"))
    }

    // MARK: - What the agent is told

    @Test("The log is named after the check, and reads as text")
    func namesTheLog() {
        let name = CheckFailureHandoff.logFilename(
            for: "build / test (macos)",
            at: Date(timeIntervalSince1970: 1_755_871_511),
            timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(name == "build - test (macos) 2025-08-22 at 14.05.11.log")
        #expect(!name.contains("/"))
    }

    @Test("A check with no name at all still gets a file that can be written")
    func namesAnUnnamedCheck() {
        let name = CheckFailureHandoff.logFilename(for: "///")
        #expect(name.hasSuffix(".log"))
        #expect(!name.hasPrefix("."))
    }

    @Test("The sentence says which check, that it failed, where the log is and where the run is")
    func writesTheSentence() {
        let excerpt = CheckFailureHandoff.Excerpt(text: "x", totalLines: 1, droppedLines: 0)
        let sentence = CheckFailureHandoff.sentence(
            name: "Run tests",
            workflow: "CI",
            state: .failed,
            detailsURL: "https://github.com/spatie/bloom/actions/runs/42/job/99",
            logPath: ".bloom/attachments/aB3dEf/Run tests.log",
            excerpt: excerpt
        )
        #expect(sentence.contains("\"Run tests\""))
        #expect(sentence.contains("in CI"))
        #expect(sentence.contains("failed."))
        #expect(sentence.contains(AttachmentDraft.token(for: ".bloom/attachments/aB3dEf/Run tests.log")))
        #expect(sentence.contains("actions/runs/42/job/99"))
        #expect(!sentence.contains("Only part of the log"))
    }

    @Test("A trimmed log says so in the sentence, not only in the file")
    func admitsTrimmingInProse() {
        let excerpt = CheckFailureHandoff.Excerpt(text: "x", totalLines: 900, droppedLines: 700)
        let sentence = CheckFailureHandoff.sentence(
            name: "Run tests", state: .failed, logPath: "a.log", excerpt: excerpt
        )
        #expect(sentence.contains("Only part of the log"))
    }

    @Test("A workflow that repeats the check's own name is not said twice")
    func doesNotRepeatTheWorkflow() {
        let sentence = CheckFailureHandoff.sentence(
            name: "Run tests", workflow: "Run tests", state: .failed, logPath: "a.log"
        )
        #expect(!sentence.contains("in Run tests"))
    }

    @Test("A check whose log could not be fetched says so rather than pretending")
    func admitsAMissingLog() {
        let sentence = CheckFailureHandoff.sentence(
            name: "Run tests", state: .failed, detailsURL: "https://example.test/1"
        )
        #expect(sentence.contains("could not fetch its log"))
        #expect(sentence.contains("https://example.test/1"))
    }

    @Test("The parsed draft finds the log path, so the agent is handed a chip and not a code span")
    func theSentenceIsAValidDraft() {
        let path = ".bloom/attachments/aB3dEf/Run tests.log"
        let sentence = CheckFailureHandoff.sentence(name: "Run tests", state: .failed, logPath: path)
        #expect(AttachmentDraft.parse(sentence).paths == [path])
    }
}
