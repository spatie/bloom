import Foundation

/// The one thing Bloom cannot do for itself: turn the system's sleep switch off while a Keep Awake
/// session runs, so a closing lid does not take the Mac down with it.
///
/// **A closing lid is not idle sleep.** No `IOPMAssertion` an application can take will hold it;
/// `pmset -a disablesleep 1` is the only lever, and it is root's. Amphetamine, which people reach
/// for because it does beat the lid, is a sandboxed App Store app and gets there by writing a
/// sudoers rule granting every admin account passwordless `pmset`. Bloom is not sandboxed, so it
/// can use the door Apple opened instead: a `LaunchDaemon` registered with `SMAppService`, approved
/// once, which changes nothing outside Bloom and leaves nothing behind when Bloom is deleted.
///
/// It does exactly two things, and it is deliberately this small: it flips the switch, and it
/// watches the process that asked. If Bloom dies with sleep disabled, the watchdog puts it back.
/// That is the failure Amphetamine's own alert says it cannot cover ("your Mac may be unable to
/// return to normal sleeping behavior until you relaunch Amphetamine").
let machServiceName = "be.spatie.bloom.sleep"

/// Only Bloom may ask. Checked by the system rather than by us: `setConnectionCodeSigningRequirement`
/// refuses the connection before a byte of it reaches this process.
let clientRequirement = """
anchor apple generic and certificate leaf[subject.OU] = "97KRXCRMAY" \
and (identifier "be.spatie.bloom" or identifier "be.spatie.bloom.dev")
"""

@objc protocol SleepControl {
    func setSleepDisabled(_ disabled: Bool, clientPID: Int32, withReply reply: @escaping (Bool) -> Void)
    func readSleepDisabled(withReply reply: @escaping (Bool) -> Void)
}

final class SleepHelper: NSObject, NSXPCListenerDelegate, SleepControl {
    /// Watches the process that asked for sleep to stay off, so a crash cannot leave a Mac that
    /// never sleeps.
    private var watchdog: DispatchSourceProcess?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SleepControl.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func setSleepDisabled(_ disabled: Bool, clientPID: Int32, withReply reply: @escaping (Bool) -> Void) {
        let changed = Self.pmset(disabled)
        watchdog?.cancel()
        watchdog = nil
        if disabled, changed {
            let source = DispatchSource.makeProcessSource(identifier: pid_t(clientPID), eventMask: .exit, queue: .main)
            source.setEventHandler {
                _ = Self.pmset(false)
                self.watchdog?.cancel()
                self.watchdog = nil
            }
            source.resume()
            watchdog = source
        }
        reply(changed)
    }

    func readSleepDisabled(withReply reply: @escaping (Bool) -> Void) {
        reply(Self.readsDisabled())
    }

    /// The whole privileged act, and nothing else this daemon can be asked for.
    private static func pmset(_ disabled: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func readsDisabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n")
            .first { $0.contains("SleepDisabled") }?
            .contains("1") ?? false
    }
}

let helper = SleepHelper()
let listener = NSXPCListener(machServiceName: machServiceName)
listener.delegate = helper
listener.setConnectionCodeSigningRequirement(clientRequirement)
listener.resume()
RunLoop.main.run()
