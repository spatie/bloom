import AppKit
import CoreServices
import Foundation
import Observation
import WebKit
import BloomCore

/// One file a page is handing over, and the delegate WebKit reports it through.
///
/// **Where it lands, and why there is no save panel.** Every download goes to the reader's own
/// Downloads folder, under a name `BrowserDownloadFile` decides. The two other answers were both
/// considered and both are worse. A modal `NSSavePanel` for every file turns a one click download
/// into two clicks and a decision, and it is the wrong dialog besides: nobody chooses a folder for
/// a zip they are about to unpack. Writing into the workspace's worktree, which the review that
/// asked for this suggested, is worse still: a download would show up in `git status`, land in the
/// diff the reader is reviewing, and could be committed by an agent that never knew where it came
/// from. Downloads is where the platform puts these, it is outside every worktree, and it is the
/// one folder a reader already knows to look in.
///
/// **And he is told.** A file arriving in silence is the poor half of that answer, so the pane
/// grows a strip under its toolbar naming what came, how far it has got and where it went, with
/// Show in Finder on it. See `BrowserDownloadsBar`.
///
/// The delegate is this object rather than one beside it because `WKDownload.delegate` is weak:
/// something has to hold it for the life of the download, and the list the strip is drawn from is
/// exactly that. One per download, so two at once cannot be confused for each other.
@MainActor
@Observable
final class BrowserDownloadItem: NSObject, WKDownloadDelegate, Identifiable {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
    }

    let id = UUID()

    /// What the file is called on disk, which is not always what the page called it. Empty until
    /// WebKit has asked where to put it, which is one round trip after the download starts.
    private(set) var name = ""
    private(set) var destination: URL?
    private(set) var state: State = .running
    private(set) var received: Int64 = 0
    private(set) var expected: Int64 = 0

    /// KVO on the download's own `Progress`, because `WKDownloadDelegate` has no callback that
    /// reports how far it has got. Read on whatever thread `Progress` posts from, which is why the
    /// two counts are taken out of it there and only the numbers cross back.
    @ObservationIgnored private var progress: NSKeyValueObservation?

    /// The last fraction that was published, so a hundred megabyte file redraws the strip a
    /// hundred times rather than once per packet. `fractionCompleted` fires far faster than
    /// anything anybody can read.
    @ObservationIgnored private var lastFraction = 0.0

    /// Where the file came from, kept for the quarantine record rather than for the strip.
    @ObservationIgnored private let source: URL?

    init(_ download: WKDownload) {
        source = download.originalRequest?.url
        super.init()
        watch(download.progress)
    }

    /// What the strip says under the name.
    var status: String {
        switch state {
        case .running: BrowserDownloadFile.progress(received: received, expected: expected)
        case .finished: BrowserDownloadFile.size(received)
        case .failed(let reason): reason
        }
    }

    /// How far along, for a bar, or nothing when the server sent no length and there is no
    /// fraction to draw.
    var fraction: Double? {
        guard state == .running, expected > 0 else { return nil }
        return min(Double(received) / Double(expected), 1)
    }

    // MARK: - WKDownloadDelegate

    /// Where the file goes.
    ///
    /// **The `async` spelling, so the destination is decided exactly once.** WebKit fails the
    /// download if the handler is never called and raises if it is called twice, and this is the
    /// one delegate method with a filesystem question in the middle of it.
    ///
    /// Nil cancels, which is what a Downloads folder that cannot be made deserves: better a
    /// download that visibly does not happen than one written somewhere nobody will look.
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let manager = FileManager.default
        guard let folder = Self.folder(manager) else {
            state = .failed("Bloom could not reach your Downloads folder.")
            return nil
        }

        // The name the page chose is never trusted. `BrowserDownloadFile` takes the path out of
        // it, unhides it, cuts it to something a file system will take, and numbers around
        // anything already in the folder, so a page cannot write over the reader's own files.
        let filename = BrowserDownloadFile.filename(for: suggestedFilename) {
            manager.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let url = folder.appendingPathComponent(filename)

        name = filename
        destination = url
        expected = max(response.expectedContentLength, 0)
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        progress = nil
        if expected > 0 { received = expected }
        quarantine()
        state = .finished
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        progress = nil
        state = .failed(error.readableMessage)
    }

    // A redirect during a download is deliberately not answered here, and WebKit's own default of
    // following it is what a file behind a signed URL needs anyway. It is worth writing down why
    // rather than leaving the gap to look like an oversight: the four delegate methods above are
    // written in their `async` spelling and every one of them produces an `@objc` thunk under the
    // completion handler selector WebKit calls, which was measured rather than assumed by dumping
    // the class's method list. `willPerformHTTPRedirection` is the one that does not. Written the
    // same way it compiles, satisfies the protocol, and emits no thunk at all, so WebKit's
    // `respondsToSelector:` says no and the method is never called. A method that looks like a
    // policy and is not one is worse than no method.

    // MARK: - The parts that are not WebKit's

    private func watch(_ progress: Progress) {
        self.progress = progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            // Out of `Progress` here, because it is not `Sendable` and only these two numbers may
            // cross. `Progress` posts from whatever thread the download is running on.
            let fraction = progress.fractionCompleted
            let received = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor [weak self] in
                self?.advance(fraction: fraction, received: received, expected: total)
            }
        }
    }

    private func advance(fraction: Double, received: Int64, expected: Int64) {
        guard state == .running else { return }
        // A hundredth of the file at a time. Every write here redraws the pane's strip, and
        // `fractionCompleted` fires per packet, which for a fast local server is thousands a
        // second for a line nobody can read changing that quickly.
        guard fraction - lastFraction >= 0.01 || received == expected else { return }
        lastFraction = fraction
        self.received = received
        if expected > 0 { self.expected = expected }
    }

    /// Marks the file as having come off the web, which is what makes Gatekeeper ask before it is
    /// opened and what puts "downloaded today from ..." in the dialog.
    ///
    /// Set here rather than trusted to WebKit, which does apply it in Safari and makes no promise
    /// about a `WKWebView` embedded in somebody else's app. Two mechanisms agreeing is the point,
    /// and a file the owner did not ask for is exactly the one that should be asked about.
    private func quarantine() {
        guard var url = destination else { return }
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
            kLSQuarantineAgentNameKey as String: "Bloom",
            kLSQuarantineDataURLKey as String: source?.absoluteString ?? "",
        ]
        do {
            try url.setResourceValues(values)
        } catch {
            // Nothing to do and nothing to say to the reader: the file is downloaded either way,
            // and a volume that does not carry the attribute (a network share, an old format) is
            // not a failure of the download. It is left unquarantined rather than deleted.
        }
    }

    /// The reader's own Downloads folder, made if it is not there.
    private static func folder(_ manager: FileManager) -> URL? {
        guard let url = manager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return nil
        }
        guard !manager.fileExists(atPath: url.path) else { return url }
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            // Somebody has deleted their Downloads folder and it cannot be put back. Answered with
            // nil, which cancels the download rather than writing the file somewhere else.
            return nil
        }
        return url
    }
}
