import Foundation

/// Progress comes from completed operations and installer events, never elapsed-time estimates.
public struct ServerSetupActivity: Sendable {
    public enum Stage: Int, CaseIterable, Sendable, Identifiable {
        case transfer, verify, dependencies, account, service, swap, browser, docker, accounts
        public var id: Int { rawValue }
        public var title: String {
            switch self {
            case .transfer: "Send server files"
            case .verify: "Verify package"
            case .dependencies: "Prepare development tools"
            case .account: "Create server account"
            case .service: "Start Bloom Server"
            case .swap: "Prepare swap space"
            case .browser: "Prepare browser tools"
            case .docker: "Prepare Docker"
            case .accounts: "Check accounts"
            }
        }
    }

    public enum Status: Sendable { case pending, running, complete, failed, skipped }
    public struct Line: Sendable, Identifiable {
        public let id: Int
        public let text: String
    }
    public private(set) var lines: [Line] = []
    public private(set) var statuses: [Stage: Status] = [:]
    public private(set) var currentMessage = "Preparing setup"
    public private(set) var activeStage: Stage?
    private var nextLineID = 0
    private var logBytes = 0

    public init() {}

    public mutating func begin(browser: Bool, docker: Bool = false, swap: Bool = false) {
        self = Self()
        if !browser { statuses[.browser] = .skipped }
        if !docker { statuses[.docker] = .skipped }
        if !swap { statuses[.swap] = .skipped }
        start(.transfer, message: "Preparing the connection and client key")
    }

    public func status(of stage: Stage) -> Status { statuses[stage] ?? .pending }
    public var output: String { lines.map(\.text).joined(separator: "\n") }

    public mutating func receive(_ event: ServerInstallEvent) {
        if event.event == "progress", let stage = Self.stage(for: event.step) {
            start(stage, message: event.message ?? stage.title)
        } else if let message = event.message {
            append(message)
            if event.event == "progress" { currentMessage = message }
        }
    }

    public mutating func start(_ stage: Stage, message: String) {
        if let previous = activeStage, previous != stage, statuses[previous] == .running {
            statuses[previous] = .complete
        }
        if let previous = activeStage, stage.rawValue > previous.rawValue + 1 {
            for skipped in Stage.allCases where skipped.rawValue > previous.rawValue && skipped.rawValue < stage.rawValue && statuses[skipped] == nil {
                statuses[skipped] = .skipped
            }
        }
        activeStage = stage
        statuses[stage] = .running
        currentMessage = message
        append(message)
    }

    public mutating func finish() {
        if let activeStage, statuses[activeStage] == .running { statuses[activeStage] = .complete }
    }

    public mutating func fail(message: String = "This setup step failed") {
        if let activeStage { statuses[activeStage] = .failed }
        currentMessage = message
    }

    /// The transport sanitises incoming lines. Bound retained output independently of its source.
    public mutating func append(_ message: String) {
        for text in message.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(text.prefix(4096))
            lines.append(Line(id: nextLineID, text: value))
            nextLineID += 1
            logBytes += value.utf8.count + 1
        }
        while lines.count > 1000 || logBytes > 256 * 1024 {
            logBytes -= lines.removeFirst().text.utf8.count + 1
        }
    }

    private static func stage(for step: String?) -> Stage? {
        switch step {
        case "staging", "upload-package", "upload-key", "launch-installer": .transfer
        case "verify": .verify
        case "dependencies": .dependencies
        case "account": .account
        case "service": .service
        case "swap_check", "swap_create", "swap_activate", "swap_persist": .swap
        case "browser_dependencies", "browser_download", "browser_smoke": .browser
        case "docker_dependencies", "docker_account", "docker_service", "docker_verify": .docker
        case "accounts": .accounts
        default: nil
        }
    }
}
