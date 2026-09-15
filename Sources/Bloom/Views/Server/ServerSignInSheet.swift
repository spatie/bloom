import SwiftUI
import BloomCore

/// Signing in to an account on a Bloom Server. Laid out like `AgentSignInSheet` and
/// `GitHubSignInSheet`, with the same heading, terminal panel and warning line, so a server's
/// sign-in and this Mac's read as one feature. The difference is that the terminal is folded under
/// the step it is on, for the reasons in `ServerSignInSession`.
struct ServerSignInSheet: View {
    @Bindable var session: ServerSignInSession
    let close: () -> Void

    @State private var copied: Copied?

    private enum Copied { case link, code }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            header
            stepContent
                .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            terminalDisclosure
            footer
        }
        .padding(Metrics.pane)
        .frame(width: 660)
        .background(Palette.surface)
        .onChange(of: session.isComplete) { _, isComplete in
            if isComplete { close() }
        }
        .onDisappear { session.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: InspectorLayout.tight) {
            Text("Sign in to \(session.account.title)")
                .font(Typo.heading)
                .foregroundStyle(Palette.textPrimary)
            Text("On \(session.host). The sign-in page opens in your browser on this Mac.")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch session.step {
        case .connecting:
            progress("Connecting to \(session.host)…")
        case .installing:
            progress("Installing \(session.account.title) on the server…", detail: "This takes a minute the first time.")
        case .pasteCode(let link):
            pasteCode(link)
        case .confirming:
            progress("Checking the code…")
        case .enterCode(let code, let link, _):
            enterCode(code, link: link)
        case .openLink(let link):
            openLink(link)
        case .unrecognised:
            warning("The server is asking something Bloom does not recognise. Answer it in the terminal below.")
        case .finished:
            verdict
        case .failed(let message):
            warning(message)
        }
    }

    // MARK: - Steps

    private func pasteCode(_ link: URL) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            numbered(1, "Open the sign-in page and approve access.") {
                HStack(spacing: InspectorLayout.gap) {
                    Button("Open Sign-in Page", systemImage: "safari") { session.openLink() }
                        .modifier(PrimaryAction(isPrimary: !session.hasOpenedLink))
                    copyButton("Copy Link", item: .link, text: link.absoluteString)
                }
            }
            numbered(2, "Paste the code the page shows you.") {
                HStack(spacing: InspectorLayout.gap) {
                    TextField("Code", text: $session.pastedCode)
                        .textFieldStyle(.roundedBorder)
                        .font(Typo.code)
                        .onSubmit { session.submitCode() }
                    Button("Continue") { session.submitCode() }
                        .modifier(PrimaryAction(isPrimary: session.hasOpenedLink))
                        .disabled(session.pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func enterCode(_ code: String, link: URL) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Enter this code at \(address(link)).")
                .font(Typo.label)
                .foregroundStyle(Palette.textPrimary)
            HStack(spacing: Metrics.gutter) {
                Text(code)
                    .font(.system(.title, design: .monospaced, weight: .semibold))
                    .kerning(2)
                    .textSelection(.enabled)
                    .foregroundStyle(Palette.textPrimary)
                copyButton("Copy Code", item: .code, text: code)
            }
            HStack(spacing: InspectorLayout.gap) {
                Button(openTitle, systemImage: "safari") { session.openLink() }
                    .modifier(PrimaryAction(isPrimary: !session.hasOpenedLink))
                if session.hasOpenedLink { waiting }
            }
        }
    }

    private func openLink(_ link: URL) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Finish signing in at \(address(link)).")
                .font(Typo.label)
                .foregroundStyle(Palette.textPrimary)
            HStack(spacing: InspectorLayout.gap) {
                Button("Open Sign-in Page", systemImage: "safari") { session.openLink() }
                    .modifier(PrimaryAction(isPrimary: !session.hasOpenedLink))
                copyButton("Copy Link", item: .link, text: link.absoluteString)
                if session.hasOpenedLink { waiting }
            }
        }
    }

    @ViewBuilder
    private var verdict: some View {
        switch session.verdict {
        case .pending, .checking:
            progress("Checking the accounts on the server…")
        case .signedIn:
            Label("Signed in to \(session.account.title)", systemImage: "checkmark.circle.fill")
                .font(Typo.label)
                .foregroundStyle(Palette.positive)
        case .stillSignedOut:
            warning("\(session.account.title) is still signed out on this server. You can try again.")
        }
    }

    // MARK: - Parts

    @ViewBuilder
    private var terminalDisclosure: some View {
        if let terminal = session.terminal {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Button(
                    session.showsTerminal ? "Hide Terminal Output" : "Show Terminal Output",
                    systemImage: session.showsTerminal ? "chevron.down" : "chevron.right"
                ) {
                    session.showsTerminal.toggle()
                }
                .linkButton()
                .font(Typo.label)

                if session.showsTerminal {
                    LoginTerminalPanel(session: terminal, height: 240)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: InspectorLayout.gap) {
            Spacer()
            if canTryAgain {
                Button("Try Again", systemImage: "arrow.clockwise") { session.start() }
            }
            Button(session.isRunning ? "Cancel" : "Done", action: close)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var canTryAgain: Bool {
        if case .failed = session.step { return true }
        return session.verdict == .stillSignedOut
    }

    private var openTitle: String {
        if session.hasOpenedLink { return "Open Again" }
        return session.account == .github ? "Copy Code and Open GitHub" : "Copy Code and Open Sign-in Page"
    }

    private var waiting: some View {
        HStack(spacing: InspectorLayout.gap) {
            ProgressView().controlSize(.small)
            Text("Waiting for you to finish in the browser…")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private func address(_ link: URL) -> String {
        (link.host() ?? "") + (link.path() == "/" ? "" : link.path())
    }

    private func numbered<Content: View>(_ number: Int, _ text: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.gutter) {
            Text("\(number)")
                .font(Typo.captionEmphasis)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 20, height: 20)
                .background(Palette.surfaceSunken, in: Circle())
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text(text)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    private func progress(_ text: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            HStack(spacing: InspectorLayout.gap) {
                ProgressView().controlSize(.small)
                Text(text).font(Typo.label).foregroundStyle(Palette.textSecondary)
            }
            if let detail {
                Text(detail).font(Typo.caption).foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private func warning(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(Typo.label)
            .foregroundStyle(Palette.warning)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func copyButton(_ title: String, item: Copied, text: String) -> some View {
        Button(copied == item ? "Copied" : title, systemImage: copied == item ? "checkmark" : "doc.on.doc") {
            Clipboard.copy(text)
            copied = item
            Task {
                try? await Task.sleep(for: Clipboard.flashDuration)
                if copied == item { copied = nil }
            }
        }
    }
}

/// The one prominent button a step has, which moves from Open to Continue once the page is open.
private struct PrimaryAction: ViewModifier {
    let isPrimary: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPrimary {
            content
                .buttonStyle(.borderedProminent)
                .tint(Palette.controlAccent)
                .keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}
