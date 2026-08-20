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

    /// What actually goes in the body. The name is cleaned again on the way through, in the core,
    /// where the rule is under test.
    var wire: Feedback.Image {
        Feedback.Image(filename: filename, contentType: contentType, data: data)
    }
}

/// Turning what somebody dropped, pasted or picked into pictures a report can carry.
///
/// The reading of a pasteboard is not repeated here: `ComposerTextView.attachables(on:)` already
/// decides what a clipboard is offering and `PastedAttachment` owns the rules behind it, so both
/// doors into this file hand over the same `AttachmentSource` values the composer works in. What
/// is added is the part a feedback report needs and a worktree attachment does not: pictures only,
/// a size that fits in a request, and a type the endpoint has heard of.
enum FeedbackImages {
    enum Failure: LocalizedError, Equatable {
        case notAnImage(String)
        case unreadable(String)
        case tooLarge(String, Int)
        case tooMany
        case tooMuch

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

    /// Everything in `sources` that can go with a report, given what is already attached.
    ///
    /// Throws on the first one that cannot, and keeps none of them, which is deliberate: a drop of
    /// five screenshots where the third is a hundred megabytes should say so once rather than
    /// silently attaching two of them and leaving somebody to work out which.
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
        case .image(let data, let format, let name):
            // A pasted picture is bytes that never had a file. TIFF is what the pasteboard falls
            // back to when nothing better was put on it, and `PastedImageFormat` is where the
            // decision to rewrite it lives, so it is asked rather than second-guessed here.
            let (bytes, type) = format.isWorthReencoding ? rewritten(data, name: name) : (data, format)
            return FeedbackImage(filename: name, contentType: mimeType(of: type), data: bytes)
        }
    }

    private nonisolated static func read(file url: URL) throws -> FeedbackImage {
        let name = url.lastPathComponent

        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else {
            throw Failure.notAnImage(name)
        }

        // The size is asked of the file system before the bytes are read, so a two gigabyte
        // picture is refused rather than loaded into memory to be refused.
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
        guard bytes <= Feedback.maxImageBytes else { throw Failure.tooLarge(name, bytes) }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw Failure.unreadable(name) }

        let mime = type.preferredMIMEType ?? ""
        guard Feedback.imageContentTypes.contains(mime) else {
            // A picture in a format the endpoint has never heard of becomes a PNG, rather than
            // being refused or sent under a type nobody can open.
            let (rewrittenData, _) = rewritten(data, name: name)
            guard rewrittenData != data else { throw Failure.notAnImage(name) }
            return FeedbackImage(
                filename: (name as NSString).deletingPathExtension + ".png",
                contentType: "image/png",
                data: rewrittenData
            )
        }

        return FeedbackImage(filename: name, contentType: mime, data: data)
    }

    /// The same picture as a PNG, or the original bytes when it cannot be read as a picture at
    /// all. Never a lie: bytes that could not be rewritten keep the type they arrived with.
    private nonisolated static func rewritten(
        _ data: Data, name: String
    ) -> (Data, PastedImageFormat) {
        guard let representation = NSBitmapImageRep(data: data),
              let png = representation.representation(using: .png, properties: [:])
        else { return (data, .tiff) }
        return (png, .png)
    }

    private nonisolated static func mimeType(of format: PastedImageFormat) -> String {
        switch format {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        case .tiff: "image/png"
        }
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

    static func send(_ report: Feedback.Report) async -> Feedback.Outcome {
        // JSON on its own, multipart the moment there is a picture. Which of the two it is, and
        // how either is written, is `Feedback.body(for:boundary:)` in the core.
        guard let body = try? Feedback.body(for: report) else { return .refused }
        return await post(body, kind: .report, appVersion: report.environment.appVersion)
    }

    static func send(_ submission: Feedback.PromptSubmission) async -> Feedback.Outcome {
        guard let body = try? Feedback.body(for: submission) else { return .refused }
        return await post(body, kind: .prompt, appVersion: submission.environment.appVersion)
    }

    private static func post(
        _ body: Feedback.Body, kind: Feedback.Kind, appVersion: String
    ) async -> Feedback.Outcome {
        guard let endpoint = Feedback.endpoint(kind, environment: ProcessInfo.processInfo.environment),
              body.data.count <= Feedback.maximumBodyBytes
        else { return .refused }

        let request = Feedback.request(to: endpoint, body: body, appVersion: appVersion)

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return Feedback.outcome(
                statusCode: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
        } catch {
            return .unreachable
        }
    }
}
