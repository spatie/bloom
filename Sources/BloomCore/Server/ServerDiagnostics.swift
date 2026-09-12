import Foundation

/// Public facts only. Command output, environment variables and credentials never cross the wire.
public struct ServerDiagnostics: Codable, Sendable, Equatable {
    public struct Check: Codable, Sendable, Equatable, Identifiable {
        public enum Status: String, Codable, Sendable { case ready, attention, unavailable }
        public enum Kind: String, Codable, Sendable { case git, tmux, github, docker, agents, disk, memory, watches }
        public var id: Kind
        public var title: String
        public var status: Status
        public var detail: String
    }

    public var checkedAt: Date
    public var hostname: String
    public var operatingSystem: String
    public var account: String
    public var checks: [Check]

    public var needsAttention: Bool { checks.contains { $0.status == .attention } }
    public var summary: String { needsAttention ? "Some checks need attention" : "Server checks complete" }
    public var text: String {
        (["\(hostname) (\(operatingSystem)), account \(account)"] + checks.map {
            "\($0.title) [\($0.status.rawValue)]: \($0.detail)"
        }).joined(separator: "\n")
    }
}

public enum ServerDiagnosticsCollector {
    typealias Probe = @Sendable (String, [String]) async -> Bool?

    public static func collect(directory: String) async -> ServerDiagnostics {
        await collect(directory: directory, probe: probe)
    }

    static func collect(directory: String, probe: @escaping Probe) async -> ServerDiagnostics {
        async let git = probe("git", ["--version"])
        async let tmux = probe("tmux", ["-V"])
        async let github = probe("gh", ["auth", "status", "--hostname", "github.com"])
        async let docker = probe("docker", ["info", "--format", "{{.ServerVersion}}"])
        var checks = await [
            tool(.git, "Git", git, required: true, missing: "Install Git to create workspaces.", failed: "Git could not run under the server account."),
            tool(.tmux, "Terminals", tmux, required: true, missing: "Install tmux for persistent terminals.", failed: "tmux could not run under the server account."),
            tool(.github, "GitHub", github, required: false, missing: "Install gh to browse and clone private GitHub repositories.", failed: "GitHub authentication failed or could not be checked. Run gh auth login as the server account."),
            tool(.docker, "Docker", docker, required: false, missing: "Docker is optional. Install it for projects with container setup scripts.", failed: "The Docker daemon could not be reached. Check the server account's Docker context and service."),
        ]
        let agents = ["claude", "codex", "opencode", "pi"].filter { Shell.which($0) != nil }
        checks.append(.init(id: .agents, title: "Agents", status: agents.isEmpty ? .attention : .ready,
                            detail: agents.isEmpty ? "No agent CLI found on the server PATH. Container projects may provide their own." : "Available on the server PATH: \(agents.joined(separator: ", ")). Authentication is checked when an agent starts."))
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory)
        checks.append(disk(freeBytes: (attributes?[.systemFreeSize] as? NSNumber)?.uint64Value))
        #if os(Linux)
        checks += linuxResources(memory: (try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8)) ?? "",
                                 watches: (try? String(contentsOfFile: "/proc/sys/fs/inotify/max_user_watches", encoding: .utf8)) ?? "")
        #else
        checks.append(.init(id: .memory, title: "Memory", status: .ready,
                            detail: "\(mib(ProcessInfo.processInfo.physicalMemory)) MiB installed. Available memory is not measured on macOS."))
        #endif
        return ServerDiagnostics(checkedAt: Date(), hostname: ProcessInfo.processInfo.hostName,
                                 operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                                 account: NSUserName(), checks: checks)
    }

    private static func probe(_ executable: String, _ arguments: [String]) async -> Bool? {
        guard let path = Shell.which(executable) else { return nil }
        do {
            let result = try await Shell.run(path, arguments, env: ["GH_PROMPT_DISABLED": "1", "GIT_TERMINAL_PROMPT": "0"], stdin: "", timeout: .seconds(8))
            return result.ok
        } catch { return false }
    }

    static func tool(_ id: ServerDiagnostics.Check.Kind, _ title: String, _ result: Bool?, required: Bool, missing: String, failed: String) -> ServerDiagnostics.Check {
        .init(id: id, title: title, status: result == true ? .ready : (result == nil && !required ? .unavailable : .attention),
              detail: result == true ? "Available to the server account." : (result == nil ? missing : failed))
    }

    static func disk(freeBytes: UInt64?) -> ServerDiagnostics.Check {
        guard let freeBytes else {
            return .init(id: .disk, title: "Disk", status: .unavailable, detail: "Free space for the server data directory could not be measured.")
        }
        let low = freeBytes < 2 * 1_024 * 1_024 * 1_024
        return .init(id: .disk, title: "Disk", status: low ? .attention : .ready,
                     detail: "\(mib(freeBytes)) MiB free on the server data volume." + (low ? " Container images and dependency installs may need more space." : " Workspace volumes on other disks are not measured."))
    }

    static func linuxResources(memory: String, watches: String) -> [ServerDiagnostics.Check] {
        var values: [String: UInt64] = [:]
        for line in memory.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == ":" || $0.isWhitespace })
            if parts.count == 3, parts[2] == "kB", let value = UInt64(parts[1]) { values[String(parts[0])] = value }
        }
        var checks: [ServerDiagnostics.Check] = []
        if let total = values["MemTotal"], let available = values["MemAvailable"], available <= total {
            let low = available < 256 * 1_024
            let swap = values["SwapFree"].map { " \($0 / 1_024) MiB swap free." } ?? ""
            checks.append(.init(id: .memory, title: "Memory", status: low ? .attention : .ready,
                                detail: "\(available / 1_024) MiB available of \(total / 1_024) MiB RAM.\(swap)" + (low ? " Builds and additional workspaces may exhaust memory." : "")))
        } else {
            checks.append(.init(id: .memory, title: "Memory", status: .unavailable, detail: "Available memory could not be measured."))
        }
        if let limit = UInt64(watches.trimmingCharacters(in: .whitespacesAndNewlines)) {
            checks.append(.init(id: .watches, title: "File watchers", status: limit < 65_536 ? .attention : .ready,
                                detail: "\(limit) watches allowed per Linux user." + (limit < 65_536 ? " Multiple workspaces may exhaust this limit. Ask the administrator to raise fs.inotify.max_user_watches to at least 65536." : " Shared by all workspaces under this account.")))
        }
        return checks
    }

    private static func mib(_ bytes: UInt64) -> UInt64 { bytes / 1_024 / 1_024 }
}
