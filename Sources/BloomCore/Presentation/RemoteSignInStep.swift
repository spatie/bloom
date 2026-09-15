import Foundation

/// The one thing a server sign-in sheet asks of the person in front of it, decided from what the
/// command has printed and how it ended.
///
/// Whether the account really is signed in is not decided here. A clean exit only moves the sheet
/// to `.finished`, and the sheet then asks the server, because Claude Code exits zero after a
/// cancelled login just as it does after a real one.
public enum RemoteSignInStep: Sendable, Equatable {
    /// SSH is connecting, or the CLI has printed nothing recognisable yet.
    case connecting
    /// npm is installing the CLI.
    case installing
    /// Open the page, sign in there, and paste the code it shows back here. Claude Code.
    case pasteCode(link: URL)
    /// A code has been pasted and the CLI is checking it.
    case confirming
    /// Open the page and enter this code there. gh and Codex. `needsReturn` is gh waiting for a
    /// keypress before it starts polling, which the sheet sends when the page is opened.
    case enterCode(code: String, link: URL, needsReturn: Bool)
    /// A link to open with nothing to type, for a flow that only printed an address.
    case openLink(URL)
    /// The CLI is asking something this sheet does not recognise. The terminal is the answer.
    case unrecognised
    /// The command exited cleanly. Time to ask the server.
    case finished
    /// The command ended without signing in.
    case failed(message: String)

    public static func decide(account: RemoteSignInAccount, reading: RemoteSignInReading, exit: TerminalExit?) -> Self {
        if let exit {
            if exit == .exited(0) { return .finished }
            if reading.isInstalling {
                return .failed(message: "\(account.title) could not be installed on the server. Check the terminal output, then try again.")
            }
            if let problem = reading.problem { return .failed(message: problem) }
            return .failed(message: "Sign-in did not finish. Check the terminal output, then try again.")
        }
        if reading.isInstalling { return .installing }
        if reading.hasUnrecognisedPrompt { return .unrecognised }
        if reading.hasPastedCode, !reading.wantsPastedCode { return .confirming }
        if let link = reading.link {
            if reading.wantsPastedCode { return .pasteCode(link: link) }
            if let code = reading.code { return .enterCode(code: code, link: link, needsReturn: reading.waitsForReturn) }
            // Claude Code prints its link a moment before its prompt; the code field is what the
            // step is for, so it is shown from the link onwards rather than flickering in.
            if account == .claude { return .pasteCode(link: link) }
            return .openLink(link)
        }
        return .connecting
    }

    /// The page this step opens, when it has one.
    public var link: URL? {
        switch self {
        case .pasteCode(let link), .enterCode(_, let link, _), .openLink(let link): link
        default: nil
        }
    }

    /// Whether the terminal should open without being asked, because the step cannot be answered
    /// anywhere else.
    public var needsTerminal: Bool {
        switch self {
        case .unrecognised, .failed: true
        default: false
        }
    }
}
