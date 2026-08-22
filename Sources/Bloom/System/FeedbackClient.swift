import AppKit
import Foundation
import UniformTypeIdentifiers
import BloomCore

/// A picture waiting to go with a report: bytes, a name and a type, and nothing about where on
/// this Mac it came from.
///
/// Held in memory rather than written anywhere. The composer copies an attachment into the
/// worktree because an agent has to be able to read it from disk; a feedback report has no such
/// need, so nothing here ever touches somebody's checkout or leaves a file behind when the sheet
/// is closed.
struct FeedbackImage: Identifiable, Equatable, Sendable {
    let id = UUID()
    var filename: String
    var contentType: String
    var data: Data

    var byteCount: Int { data.count }

    /// What actually goes in the body, which is the bytes and their type. The name above is for
    /// the chip on the sheet and goes no further: what travels is `attachment.png`, because the
    /// endpoint does not store a client filename and does check its extension against the bytes.
    /// See `Feedback.Image`.
    var wire: Feedback.Image {
        Feedback.Image(contentType: contentType, data: data)
    }
}

/// Turning what somebody dropped, pasted or picked into pictures a report can carry.
///
/// The reading of a pasteboard is not repeated here: `ComposerTextView.attachables(on:)` already
/// decides what a clipboard is offering and `PastedAttachment` owns the rules behind it, so both
/// doors into this file hand over the same `AttachmentSource` values the composer works in. What
/// is added is the part a feedback report needs and a worktree attachment does not: pictures only,
/// in a format the endpoint has heard of, inside three separate limits.
enum FeedbackImages {
    enum Failure: LocalizedError, Equatable {
        case notAnImage(String)
        case unreadable(String)
        case tooLarge(String, Int)
        case tooMany
        case tooMuch

        /// Three limits, three sentences. Which one was hit is the only useful thing this can say,
        /// because each has a different answer: take one off, crop this one, or both.
        var errorDescription: String? {
            switch self {
            case .notAnImage(let name): Feedback.notAnImageMessage(name: name)
            case .unreadable(let name): "Bloom could not read \(name)."
            case .tooLarge(let name, let bytes): Feedback.tooLargeMessage(name: name, bytes: bytes)
            case .tooMany: Feedback.tooManyMessage()
            case .tooMuch: Feedback.tooMuchMessage()
            }
        }
    }

    /// Everything in `sources` that can go with a report, given what is already attached, in the
    /// order they were handed over.
    ///
    /// Order is kept deliberately: the far end lists attachments as "Screenshot 1", "Screenshot 2"
    /// in the order they arrive, so the order somebody put them in is the order they are read in.
    ///
    /// Throws on the first one that cannot go, and keeps none of them, which is also deliberate: a
    /// drop of five screenshots where the third is a hundred megabytes should say so once rather
    /// than silently attaching two and leaving somebody to work out which.
    ///
    /// `nonisolated`, and every caller runs it off the main actor: this reads files and can
    /// re-encode a picture, neither of which belongs on the actor drawing the sheet.
    nonisolated static func read(
        _ sources: [AttachmentSource], existing: [FeedbackImage] = []
    ) throws -> [FeedbackImage] {
        guard existing.count + sources.count <= Feedback.maxImages else { throw Failure.tooMany }

        var found: [FeedbackImage] = []
        var total = existing.reduce(0) { $0 + $1.byteCount }

        for source in sources {
            let image = try read(source)
            guard image.byteCount <= Feedback.maxImageBytes else {
                throw Failure.tooLarge(image.filename, image.byteCount)
            }
            total += image.byteCount
            guard total <= Feedback.maxTotalImageBytes else { throw Failure.tooMuch }
            found.append(image)
        }
        return found
    }

    private nonisolated static func read(_ source: AttachmentSource) throws -> FeedbackImage {
        switch source {
        case .file(let url):
            return try read(file: url)
        case .image(let data, _, let name):
            // A pasted picture is bytes that never had a file. What those bytes are is read from
            // the bytes rather than from the format the pasteboard advertised, and a TIFF, which
            // is what a board falls back to when nothing better was put on it, becomes a PNG here
            // because the endpoint does not take TIFF at all.
            guard let (bytes, type) = readable(data) else { throw Failure.notAnImage(name) }
            return FeedbackImage(filename: name, contentType: type, data: bytes)
        case .text(_, let name):
            // Feedback is a screenshot and a sentence. Text Bloom generated for an agent to read,
            // which is the only thing that arrives in this case, is not an image and there is
            // nowhere in a feedback report to put it.
            throw Failure.notAnImage(name)
        }
    }

    private nonisolated static func read(file url: URL) throws -> FeedbackImage {
        let name = url.lastPathComponent

        // The size is asked of the file system before the bytes are read, so a two gigabyte
        // picture is refused rather than loaded into memory to be refused. The cap is checked
        // again on what comes out of `readable`, because a re-encode changes the size.
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
        guard onDisk <= Feedback.maxImageBytes else { throw Failure.tooLarge(name, onDisk) }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw Failure.unreadable(name) }
        guard let (bytes, type) = readable(data) else { throw Failure.notAnImage(name) }

        return FeedbackImage(filename: name, contentType: type, data: bytes)
    }

    /// The bytes as they can be sent, and what they are.
    ///
    /// Sniffed first, because the endpoint sniffs too and the two have to agree. Anything that is
    /// a picture in a format nobody here accepts (a TIFF off the clipboard, a BMP somebody saved
    /// in 2004) is re-encoded as a PNG rather than refused, and anything that is not a picture at
    /// all comes back nil. Nothing is ever sent under a type it is not.
    private nonisolated static func readable(_ data: Data) -> (Data, String)? {
        if let sniffed = Feedback.sniffedContentType(data) { return (data, sniffed) }

        guard let representation = NSBitmapImageRep(data: data),
              let png = representation.representation(using: .png, properties: [:]),
              Feedback.sniffedContentType(png) == "image/png"
        else { return nil }

        return (png, "image/png")
    }
}

/// Puts a report or a prompt submission on the wire, and says what came back.
///
/// **Nothing here writes to Bloom's log.** Every other part of the app that gives up quietly says
/// so in `Log`, and this one deliberately does not: the log is a thing this same feature offers to
/// send, and a feedback report that fails would otherwise leave a line about the failed feedback
/// report in the next one. What went wrong is said on the sheet, to the person watching it.
enum FeedbackClient {
    /// Ephemeral, so nothing about a report is written to a cache or a cookie jar on the user's
    /// disk. `waitsForConnectivity` is on, unlike the ping's: there is a person watching this one,
    /// and a laptop that has just woken up is worth waiting a few seconds for rather than telling
    /// them it failed.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func send(_ report: Feedback.Report) async -> Feedback.Result {
        // JSON on its own, multipart the moment there is a picture. Which of the two it is, and
        // how either is written, is `Feedback.body(for:boundary:)` in the core.
        guard let body = try? Feedback.body(for: report) else { return Feedback.Result(outcome: .refused) }
        return await post(body, kind: .report, appVersion: report.environment.appVersion)
    }

    static func send(_ submission: Feedback.PromptSubmission) async -> Feedback.Result {
        guard let body = try? Feedback.body(for: submission) else { return Feedback.Result(outcome: .refused) }
        return await post(body, kind: .prompt, appVersion: submission.environment.appVersion)
    }

    private static func post(
        _ body: Feedback.Body, kind: Feedback.Kind, appVersion: String
    ) async -> Feedback.Result {
        guard let endpoint = Feedback.endpoint(kind, environment: ProcessInfo.processInfo.environment),
              body.data.count <= Feedback.maximumBodyBytes
        else { return Feedback.Result(outcome: .refused) }

        let request = Feedback.request(to: endpoint, body: body, appVersion: appVersion)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Feedback.Result(outcome: .unreachable)
            }

            let outcome = Feedback.outcome(
                statusCode: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
            // Only off a reply that was actually taken, and only when it looks like a reference.
            // See `Feedback.reference(in:)` for why a server's string is checked before it is
            // printed into Bloom's own interface.
            return Feedback.Result(
                outcome: outcome,
                reference: outcome == .sent ? Feedback.reference(in: data) : nil
            )
        } catch {
            return Feedback.Result(outcome: .unreachable)
        }
    }
}
