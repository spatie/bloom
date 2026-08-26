import Foundation

/// What a browser pane says when a page will not load.
///
/// **It said nothing at all.** Both of `WKNavigationDelegate`'s failure callbacks refreshed the
/// toolbar and dropped the error on the floor, so a mistyped host left a white rectangle under an
/// address bar holding the address that failed. A blank pane is what this app shows while a page
/// is arriving, so the reader cannot tell a dead domain from a slow one, and the only way to find
/// out was to wait and see whether anything ever appeared.
///
/// Here rather than in the view because it is a decision about what an error means, and the
/// mapping is the sort of thing a test should hold: `NSURLErrorCancelled` is not a failure a reader
/// should ever be told about, and neither is WebKit's frame-load-interrupted, which is what a
/// download looks like from the navigation's point of view.
public struct BrowserLoadFailure: Equatable, Sendable {
    /// The heading, which names what went wrong rather than restating the address.
    public let title: String
    /// One sentence, and where possible one that says what to try.
    public let message: String
    /// Whether the address bar's text is worth repeating in the message. False for the failures
    /// that are about the machine rather than about this page.
    public let namesTheAddress: Bool

    public init(title: String, message: String, namesTheAddress: Bool = true) {
        self.title = title
        self.message = message
        self.namesTheAddress = namesTheAddress
    }

    /// Nil for the "failures" that are a normal part of browsing and must draw nothing.
    ///
    /// Three of them, and each has bitten somebody: a load cancelled because the reader typed a new
    /// address while the last one was in flight; WebKit's `frameLoadInterrupted`, which is what a
    /// response turned into a download looks like from here, so the pane that just saved a file
    /// would otherwise accuse itself of failing; and a policy refusal, which is the app's own
    /// decision rather than an error.
    public static func of(domain: String, code: Int, host: String? = nil) -> BrowserLoadFailure? {
        if domain == NSURLErrorDomain, code == NSURLErrorCancelled { return nil }
        if domain == "WebKitErrorDomain", code == 102 || code == 101 { return nil }

        guard domain == NSURLErrorDomain else {
            return BrowserLoadFailure(
                title: "This page did not load",
                message: "Something went wrong loading this page. Try again, or open it in your browser."
            )
        }

        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return BrowserLoadFailure(
                title: "Cannot find that address",
                message: named(host, "There is no server at %@.", "There is no server at that address.")
                    + " Check the spelling."
            )
        case NSURLErrorCannotConnectToHost:
            return BrowserLoadFailure(
                title: "Cannot connect",
                message: named(host, "%@ refused the connection.", "The server refused the connection.")
                    + " It may be down, or nothing may be listening on that port."
            )
        case NSURLErrorNotConnectedToInternet:
            return BrowserLoadFailure(
                title: "No internet connection",
                message: "This Mac is not online, so nothing can be fetched.",
                namesTheAddress: false
            )
        case NSURLErrorTimedOut:
            return BrowserLoadFailure(
                title: "The server took too long",
                message: named(host, "%@ did not answer in time.", "The server did not answer in time.")
                    + " It may be starting up."
            )
        case NSURLErrorUnsupportedURL, NSURLErrorBadURL:
            return BrowserLoadFailure(
                title: "That is not an address this pane can open",
                message: "Only http and https pages, and local files, open here."
            )
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid:
            return BrowserLoadFailure(
                title: "The connection is not private",
                message: named(host, "%@ presented a certificate this Mac does not trust.",
                               "The server presented a certificate this Mac does not trust.")
            )
        case NSURLErrorNetworkConnectionLost:
            return BrowserLoadFailure(
                title: "The connection dropped",
                message: "The connection was lost while the page was loading. Try again.",
                namesTheAddress: false
            )
        case NSURLErrorFileDoesNotExist, NSURLErrorFileIsDirectory:
            return BrowserLoadFailure(
                title: "That file is not there",
                message: "Nothing is at that path any more. It may have been moved or deleted."
            )
        default:
            return BrowserLoadFailure(
                title: "This page did not load",
                message: "Something went wrong loading this page. Try again, or open it in your browser."
            )
        }
    }

    /// The host when there is one, and a sentence that still reads when there is not. A message
    /// with an empty gap where the host should be is worse than one that never mentions it.
    private static func named(_ host: String?, _ withHost: String, _ without: String) -> String {
        guard let host, !host.isEmpty else { return without }
        return withHost.replacingOccurrences(of: "%@", with: host)
    }
}
