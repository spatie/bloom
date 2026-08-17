import SwiftUI
import Observation
import BatonCore

/// One long-running command from the repo settings, usually a dev server.
///
/// The state lives outside the view because a dev server has to keep running while the user is
/// looking at the Setup tab, at another terminal, or at another workspace entirely.
@MainActor
@Observable
final class RunScriptSession {
    var script: RunScript
    let workspace: Workspace

    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var exitStatus: Int32?
    /// The port the script announced in its own output, which beats the allocated one when the
    /// script decided to bind somewhere else.
    private(set) var detectedPort: Int?

    private var process: StreamingProcess?
    private var task: Task<Void, Never>?
    /// Set when a restart is waiting for the old process to actually die, so the new one starts
    /// from `finish` rather than racing the exit.
    private var restartRequest: (environment: [String: String], port: Int)?

    /// Logs are dropped from the front past this, because a dev server left running all day will
    /// happily produce hundreds of megabytes.
    private static let maximumOutput = 400_000

    init(script: RunScript, workspace: Workspace) {
        self.script = script
        self.workspace = workspace
    }

    func start(environment: [String: String], port: Int) {
        guard !isRunning else { return }

        output = ""
        exitStatus = nil
        detectedPort = port > 0 ? port : nil

        let runner = StreamingProcess(
            executable: "/bin/zsh",
            arguments: ["-lc", script.command],
            cwd: workspace.path,
            environment: Shell.environment(extra: environment)
        )
        process = runner
        isRunning = true

        task = Task { [weak self] in
            do {
                for try await line in runner.lines {
                    self?.append(line)
                }
            } catch {
                self?.append("\(error)")
            }
            let status = await runner.exitStatus
            self?.finish(status)
        }
    }

    func stop() {
        guard isRunning else { return }
        process?.terminate()
        // A dev server that ignores SIGTERM should not keep the port hostage.
        Task { [process] in
            try? await Task.sleep(for: .seconds(3))
            process?.kill()
        }
    }

    func restart(environment: [String: String], port: Int) {
        guard isRunning else {
            start(environment: environment, port: port)
            return
        }
        restartRequest = (environment, port)
        stop()
    }

    private func append(_ line: String) {
        output += line + "\n"
        if output.count > Self.maximumOutput {
            output = String(output.suffix(Self.maximumOutput))
        }
        if let found = Self.port(in: line) { detectedPort = found }
    }

    private func finish(_ status: Int32) {
        isRunning = false
        exitStatus = status
        process = nil
        task = nil
        output += "\n[exited with status \(status)]\n"

        if let request = restartRequest {
            restartRequest = nil
            start(environment: request.environment, port: request.port)
        }
    }

    /// Matches the shapes dev servers actually print: `http://localhost:5173`, `0.0.0.0:8000`,
    /// `listening on port 3000`.
    static func port(in line: String) -> Int? {
        let patterns = [
            #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::\])[:\s]+(\d{2,5})"#,
            #"\bport[:\s]+(\d{2,5})\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(
                      in: line, range: NSRange(line.startIndex..., in: line)
                  ),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: line),
                  let value = Int(line[range]), value > 0, value < 65_536 else { continue }
            return value
        }
        return nil
    }
}

/// The Run tab: a start, stop and restart bar over the script's output, plus a link to whatever
/// it is serving.
struct RunScriptView: View {
    @Bindable var model: WorkspaceModel
    var script: RunScript

    private var session: RunScriptSession {
        TerminalSessionStore.shared.runSession(for: script, workspace: model.workspace)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if session.output.isEmpty && !session.isRunning {
                EmptyStateView(
                    glyph: "play.circle",
                    title: script.name,
                    message: script.command,
                    actionTitle: "Start",
                    action: { session.start(environment: environment(), port: ensurePort()) }
                )
                .background(Palette.surfaceSunken)
            } else {
                LogOutputView(text: session.output, isFollowing: session.isRunning)
            }
        }
        .background(Palette.surfaceSunken)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ActivityDot(isActive: session.isRunning)

            Text(script.name)
                .font(Typo.labelEmphasis)
                .foregroundStyle(Palette.textPrimary)

            Chip(text: script.command, monospaced: true)
                .lineLimit(1)
                .layoutPriority(-1)

            if let url = serverURL {
                Link(destination: url) {
                    Chip(
                        text: url.absoluteString,
                        systemImage: "arrow.up.right",
                        tint: Palette.accent,
                        background: Palette.accent.opacity(0.12),
                        monospaced: true
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 8)

            if session.isRunning {
                action("Stop", icon: "stop.fill", tint: Palette.negative) { session.stop() }
                action("Restart", icon: "arrow.clockwise") {
                    session.restart(environment: environment(), port: ensurePort())
                }
            } else {
                action("Start", icon: "play.fill", tint: Palette.positive) {
                    session.start(environment: environment(), port: ensurePort())
                }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: 28)
        .background(Palette.surface)
    }

    private func action(
        _ title: String,
        icon: String,
        tint: Color = Palette.textSecondary,
        run: @escaping () -> Void
    ) -> some View {
        Button(action: run) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(Typo.label)
            }
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    private var serverURL: URL? {
        let port = session.detectedPort ?? (model.port > 0 ? model.port : nil)
        guard let port else { return nil }
        return URL(string: "http://localhost:\(port)")
    }

    /// Run scripts bind `$BATON_PORT`, so a workspace that has not been through setup still needs
    /// a port before its first run.
    private func ensurePort() -> Int {
        if model.port == 0 { model.port = (try? PortAllocator.allocate(taken: [])) ?? 0 }
        return model.port
    }

    private func environment() -> [String: String] {
        guard let repo = model.repo, let store = model.store else { return [:] }
        return WorkspaceManager(store: store).environment(
            for: model.workspace, repo: repo, port: ensurePort()
        )
    }
}
