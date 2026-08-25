import Foundation

/// How many rows the transcript is currently handing its lazy stack, for a probe to read.
///
/// A number a run has to be able to see, because the whole of `TranscriptWindow` is a claim about
/// it and a report that says "1,582 rows in the session" says nothing about how many of them are
/// in the stack. Written where the window is set and nowhere else, and read by nothing but a
/// probe's report, so a build nobody is measuring pays for one integer store per workspace switch.
@MainActor
enum TranscriptDrawn {
    private(set) static var rows = 0

    static func note(_ count: Int) { rows = count }
}
