import Foundation

public extension AgentKind {
    func prepareInteractiveCommand(
        directory: String,
        prompt: String,
        sessionID: SessionID,
        model: String,
        effort: String,
        permissionMode: PermissionMode? = nil,
        resuming: String? = nil,
        base: URL? = nil
    ) throws -> String? {
        guard let script = interactiveCommand(
            directory: directory, prompt: prompt, sessionID: sessionID,
            model: model, effort: effort, permissionMode: permissionMode, resuming: resuming
        ) else { return nil }
        let folder = try Self.interactiveLaunchDirectory(sessionID: sessionID, base: base)
        let file = folder.appendingPathComponent(resuming == nil ? "start.sh" : "resume.sh")
        let command = TerminalLaunchScript.command(
            executable: "/bin/sh", arguments: [file.path]
        )
        // A new shell may still have macOS's 1,024-byte canonical input buffer.
        guard command.utf8.count < 1_000 else {
            throw NSError(domain: "Bloom", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The launch file path is too long to start an agent in a terminal."
            ])
        }
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let clear = #"if [ -t 1 ]; then printf '\033[2J\033[H\033[3J'; fi"#
        let data = Data(("#!/bin/sh\n" + clear + "\n" + script + "\n").utf8)
        if (try? Data(contentsOf: file)) != data {
            try data.write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return command
    }

    static func interactiveLaunchDirectory(sessionID: SessionID, base: URL? = nil) throws -> URL {
        let root = try base ?? URL(fileURLWithPath: Store.defaultPath()).deletingLastPathComponent()
        let name = sessionID.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("cli-launches", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func removeInteractiveLaunch(sessionID: SessionID, base: URL? = nil) throws {
        let directory = try interactiveLaunchDirectory(sessionID: sessionID, base: base)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
