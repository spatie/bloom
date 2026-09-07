import AppKit
import BloomCore
import SwiftUI

/// Exercises the menu's real welcome lifecycle without showing or activating a window.
/// Run in an isolated probe bundle with --setup-rehearsal all-clear.
@MainActor
enum WelcomeRestartProbe {
    private static let harness = ProbeHarness(subject: "welcome-restart")
    static var isRequested: Bool { harness.isRequested }

    static func schedule() {
        Task { @MainActor in await run() }
    }

    private static func run() async {
        await harness.settle()
        var failures: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let original = WelcomeWindow.prepare(trigger: .blocked)
        await settle(original)
        check(identifiers(in: original.contentView).contains("welcome-step-checks"),
              "initial window did not open at the checks")

        var previous = original
        for visit in 0..<3 {
            let completed = UserDefaults.standard.bool(forKey: OnboardingGate.completedKey)
            let replay = WelcomeWindow.prepare(trigger: .firstRun, restarting: true)
            await settle(replay)
            check(replay !== previous, "visit \(visit) reused the previous wizard")
            check(previous.contentViewController == nil, "visit \(visit) retained the old wizard")
            check(identifiers(in: replay.contentView).contains("welcome-step-greeting"),
                  "visit \(visit) did not restart at the greeting")
            check(!replay.isVisible && !replay.isKeyWindow, "probe showed its window")
            check(UserDefaults.standard.bool(forKey: OnboardingGate.completedKey) == completed,
                  "restart changed the completion preference")
            // Closing and asking again is the reported sequence. A second request while already
            // open must work too, so the middle visit deliberately keeps its presentation alive.
            if visit != 1 { replay.close() }
            previous = replay
        }
        harness.write(.object([
            "checks": .integer(checks), "passed": .bool(failures.isEmpty),
            "failures": .strings(failures),
        ]))
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func settle(_ window: NSWindow) async {
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(250))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private static func identifiers(in root: Any?) -> Set<String> {
        guard let element = root as? any NSAccessibilityProtocol else { return [] }
        var result = Set<String>()
        if let identifier = element.accessibilityIdentifier() { result.insert(identifier) }
        for child in element.accessibilityChildren() ?? [] {
            result.formUnion(identifiers(in: child))
        }
        return result
    }
}
