import BloomCore
import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc

@_silgen_name("ptrace")
private func linuxPtrace(
    _ request: Int32, _ pid: Int32, _ address: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?
) -> Int

#endif

struct PersonBoundLaunchRequest: Codable, Sendable, Hashable {
    var nonce: String
}

struct PersonBoundLaunchAnswer: Codable, Sendable, Hashable {
    var execute: Bool
}

/// Owns the synchronous launch gate and constructs the privileged wrapper used by v2 processes.
/// An untrusted executable is never reached until the registry has recorded its kernel identity.
final class PersonBoundSandboxLauncher: @unchecked Sendable {
    struct Prepared: Sendable {
        var launch: AgentLaunch
        var reservation: PersonBoundProcessRegistry.Reservation
        var cleanup: @Sendable () -> Void
    }

    let registry: PersonBoundProcessRegistry
    private let gate: LocalJSONSocket<PersonBoundLaunchRequest, PersonBoundLaunchAnswer>
    private let executable: String
    private let gatePath: String
    private let group: String
    private let worktree: String
    private let supervisor: PersonBoundProcessIdentity?

    init(
        executable: String,
        worktree: String,
        gatePath: String = MachineSandbox.launchGateSocketPath,
        group: String = MachineSandbox.sharedGroup,
        registry: PersonBoundProcessRegistry,
        supervisor: PersonBoundProcessIdentity? = PersonBoundProcIdentity.read(
            Int32(ProcessInfo.processInfo.processIdentifier)
        )
    ) throws {
        self.executable = executable
        self.worktree = worktree
        self.supervisor = supervisor
        self.gatePath = gatePath
        self.group = group
        self.registry = registry
        gate = try LocalJSONSocket(path: gatePath, group: group) { request, peer in
            guard let peer else { return PersonBoundLaunchAnswer(execute: false) }
            return PersonBoundLaunchAnswer(execute: registry.register(nonce: request.nonce, peer: peer) != nil)
        }
    }

    func prepare(_ launch: AgentLaunch, purpose: PersonBoundProcessPurpose) -> Prepared? {
        guard let reservation = registry.reserve(purpose) else { return nil }
        return prepare(launch, reservation: reservation)
    }

    func prepare(_ launch: AgentLaunch, reservation: PersonBoundProcessRegistry.Reservation) -> Prepared {
        var environment = launch.environment
        environment.removeValue(forKey: "BLOOM_PERSON_BOUND_FOUNDATION_SELF_TEST")
        if case .bootstrap = reservation.purpose {
            environment["BLOOM_PERSON_BOUND_FOUNDATION_SELF_TEST"] = "1"
        }
        environment["BLOOM_PERSON_BOUND_NONCE"] = reservation.nonce
        environment["BLOOM_PERSON_BOUND_UID"] = String(reservation.uid)
        environment["BLOOM_PERSON_BOUND_CGROUP"] = reservation.cgroup
        environment["BLOOM_PERSON_BOUND_GATE"] = gatePath
        environment["BLOOM_PERSON_BOUND_GROUP"] = group
        environment["BLOOM_PERSON_BOUND_HOME"] = MachineSandbox.personBoundHomeRoot + "/" + reservation.id.uuidString.lowercased()
        environment["BLOOM_PERSON_BOUND_PROVENANCE"] = MachineSandbox.personBoundProvenanceRoot + "/"
            + reservation.id.uuidString.lowercased()
        environment["BLOOM_PERSON_BOUND_WORKTREE"] = worktree
        environment["BLOOM_PERSON_BOUND_PATH"] = environment["PATH"]
        if let supervisor {
            environment["BLOOM_PERSON_BOUND_SUPERVISOR_PID"] = String(supervisor.pid)
            environment["BLOOM_PERSON_BOUND_SUPERVISOR_START"] = String(supervisor.startTime)
        }
        let wrapped = AgentLaunch(
            executable: "/usr/bin/sudo",
            arguments: [
                "-n", "-E", "/usr/bin/unshare", "--mount", "--propagation", "private", "--",
                executable, "sandbox-exec", "--", launch.executable,
            ] + launch.arguments,
            cwd: launch.cwd,
            environment: environment
        )
        let cleanup: @Sendable () -> Void = { [registry, id = reservation.id] in
            registry.forgetBeforeTeardown(id)
        }
        return Prepared(launch: wrapped, reservation: reservation, cleanup: cleanup)
    }

    func close() { gate.close() }
}

/// The root half of `PersonBoundSandboxLauncher`, invoked only through passwordless sudo and a
/// private mount namespace. Its child drops to a fresh numeric uid, joins a fresh cgroup and blocks
/// at the launch gate before `execve` replaces it with untrusted code.
enum PersonBoundSandboxExec {
    /// Every refusal below used to be a bare `return 1`, which is how a Cloud workspace spent a
    /// night saying `live exchange (... output=[])` and nothing else: the most guarded path in the
    /// Runner had no way to say which guard stopped it, and running it by hand printed nothing at
    /// all. The reason is not a secret. Only root reaches this, through passwordless sudo, and a
    /// machine that cannot launch a sandbox is broken rather than under attack.
    /// The same, from the forked child, which has no return value to carry one.
    private static func childRefusal(_ reason: String) {
        FileHandle.standardError.write(Data("bloom-runner: sandbox-exec refused: \(reason)\n".utf8))
    }

    private static func refuse(_ reason: String) -> Int32 {
        FileHandle.standardError.write(Data("bloom-runner: sandbox-exec refused: \(reason)\n".utf8))

        return 1
    }

    private enum ProtectedOperation {
        case git
        case gh
    }

    /// What the sandboxed command inherits: everything the Runner handed over, less the launch's
    /// own `BLOOM_PERSON_BOUND_` internals, with the Runner's PATH put back.
    ///
    /// **PATH travels under another name because sudo throws it away.** `secure_path` replaces
    /// PATH even under `-E`, so an agent's shell started with the system directories only: Bloom's
    /// `git` and `gh` wrappers, which the Runner puts first, were gone, the real gh in `/.sprite/bin`
    /// with them, and an agent asked to open a pull request reported "gh is not installed" and a
    /// push that could not read a username. Services lost PATH the same way and were fixed in the
    /// sandbox wrapper; this is the same fix for everything the person-bound launcher starts.
    static func childEnvironment(from environment: [String: String]) -> [String: String] {
        var childEnvironment = environment
        let foundationSelfTest = childEnvironment["BLOOM_PERSON_BOUND_FOUNDATION_SELF_TEST"] == "1"
        let carriedPath = childEnvironment["BLOOM_PERSON_BOUND_PATH"]
        for key in childEnvironment.keys where key.hasPrefix("BLOOM_PERSON_BOUND_") {
            childEnvironment.removeValue(forKey: key)
        }
        if foundationSelfTest {
            childEnvironment["BLOOM_PERSON_BOUND_FOUNDATION_SELF_TEST"] = "1"
        }
        if let carriedPath, !carriedPath.isEmpty {
            childEnvironment["PATH"] = carriedPath
        }
        return childEnvironment
    }

    static func run(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        #if !os(Linux)
        return 1
        #else
        guard getuid() == 0, arguments.first == "--", arguments.count >= 2,
              let uid = environment["BLOOM_PERSON_BOUND_UID"].flatMap(UInt32.init),
              uid == MachineSandbox.agentUID() || uid >= 200_000,
              let cgroup = safePath(environment["BLOOM_PERSON_BOUND_CGROUP"], under: "/sys/fs/cgroup/bloom-person-bound/"),
              let home = safePath(environment["BLOOM_PERSON_BOUND_HOME"], under: MachineSandbox.personBoundHomeRoot + "/"),
              let provenance = safePath(
                  environment["BLOOM_PERSON_BOUND_PROVENANCE"], under: MachineSandbox.personBoundProvenanceRoot + "/"
              ),
              let worktree = environment["BLOOM_PERSON_BOUND_WORKTREE"], worktree.hasPrefix("/"),
              let gate = environment["BLOOM_PERSON_BOUND_GATE"], gate == MachineSandbox.launchGateSocketPath,
              let nonce = environment["BLOOM_PERSON_BOUND_NONCE"], nonce.count >= 32,
              let group = environment["BLOOM_PERSON_BOUND_GROUP"], let groupEntry = group.withCString({ getgrnam($0) })
        else {
            return refuse(
                "it must run as root, with `--` and a command, and with BLOOM_PERSON_BOUND_UID the agent user's "
                    + "or 200000 or above, "
                    + "_CGROUP, _HOME, _PROVENANCE, _WORKTREE, _GATE, _NONCE and _GROUP all set and within their roots"
            )
        }
        // A fresh uid has to be unused, or it is somebody else's. The agent user is shared on
        // purpose, by every reservation and by the services, so it is always in use.
        if uid != MachineSandbox.agentUID() {
            guard uidIsAvailable(uid) else { return refuse("uid \(uid) is already taken on this host") }
        }

        guard FileManager.default.fileExists(atPath: "/.sprite/api.sock") else {
            return refuse("there is no /.sprite/api.sock to mask, so this is not a machine a sandbox may run on")
        }
        guard rootCommand("/usr/bin/mount", ["--bind", "/dev/null", "/.sprite/api.sock"]) == 0 else {
            return refuse("/dev/null could not be bind mounted over /.sprite/api.sock, which must be masked first")
        }
        do {
            try FileManager.default.createDirectory(atPath: cgroup, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: provenance, withIntermediateDirectories: true)
        } catch {
            return refuse("the cgroup, home or provenance directory could not be made: \(error)")
        }
        guard chown(home, uid, groupEntry.pointee.gr_gid) == 0, chmod(home, 0o700) == 0,
              chown(provenance, 0, 0) == 0, chmod(provenance, 0o700) == 0 else {
            return refuse("the home or provenance directory could not be given its owner and mode")
        }

        // **The agent user keeps its own home; only a numeric uid gets the throwaway one.** Claude
        // keeps every conversation under `$HOME/.claude`, and a home removed when its launch ended
        // took the conversation with it: the next message in that chat resumed a session id that
        // no longer existed, Claude exited before making a single request, and the chat never
        // answered again. Every launch shares the agent's uid, so a home per launch kept nothing
        // apart that the uid had not already joined. Looked up before the fork, because getpwuid
        // is not safe in the child of a threaded process.
        let persistentHome = uid == MachineSandbox.agentUID() ? getpwuid(uid).map { entry in
            (String(cString: entry.pointee.pw_dir), String(cString: entry.pointee.pw_name))
        } : nil
        let child = fork()
        guard child >= 0 else { return refuse("this host would not fork") }
        if child == 0 {
            _ = setpgid(0, 0)
            let pid = String(getpid()) + "\n"
            guard writeText(pid, to: cgroup + "/cgroup.procs") else { childRefusal("the child could not join its cgroup"); _exit(125) }
            guard linuxPtrace(0, 0, nil, nil) == 0 else { childRefusal("PTRACE_TRACEME was refused, so the supervisor could not watch the exec"); _exit(125) } // PTRACE_TRACEME
            _ = raise(SIGSTOP)
            var groups = [groupEntry.pointee.gr_gid]
            guard groups.withUnsafeMutableBufferPointer({ setgroups($0.count, $0.baseAddress) }) == 0,
                  setgid(groupEntry.pointee.gr_gid) == 0,
                  setuid(uid) == 0 else {
                childRefusal("the child could not drop to uid \(uid) in group \(group)")
                _exit(125)
            }

            let request = PersonBoundLaunchRequest(nonce: nonce)
            let answer: PersonBoundLaunchAnswer? = LocalCredentialClient.exchange(request, over: gate)
            guard answer?.execute == true else { childRefusal("the launch gate did not answer execute for this nonce"); _exit(126) }

            var childEnvironment = Self.childEnvironment(from: environment)
            // Everything BLOOM_PERSON_BOUND_ is stripped above because it carries the launch
            // nonce and the machine's internals, and none of that belongs in an agent's
            // environment. The worktree is not one of those: it is the directory the agent is
            // working in and can see for itself. It is put back under a plain name because a
            // network git command has to name it as a safe directory, having had the system-wide
            // config turned off, and without it every push refused as "dubious ownership".
            childEnvironment["BLOOM_WORKTREE"] = worktree
            childEnvironment["HOME"] = persistentHome?.0 ?? home
            childEnvironment["USER"] = persistentHome?.1 ?? String(uid)
            childEnvironment["LOGNAME"] = persistentHome?.1 ?? String(uid)
            // The same shared group umask the Runner uses, so whatever the agent writes in the
            // worktree the Runner can still change, and the other way round.
            umask(0o002)
            execute(arguments: Array(arguments.dropFirst()), environment: childEnvironment)
        }

        guard let supervisorPID = environment["BLOOM_PERSON_BOUND_SUPERVISOR_PID"].flatMap(Int32.init),
              let supervisorStart = environment["BLOOM_PERSON_BOUND_SUPERVISOR_START"].flatMap(UInt64.init)
        else {
            _ = writeText("1\n", to: cgroup + "/cgroup.kill")

            return refuse("BLOOM_PERSON_BOUND_SUPERVISOR_PID and _START name the Runner that must outlive this, and were not both set")
        }
        return supervise(
            leader: child, runnerPID: supervisorPID, runnerStart: supervisorStart,
            cgroup: cgroup, provenance: provenance, worktree: worktree,
            provesCleanup: environment["BLOOM_PERSON_BOUND_FOUNDATION_SELF_TEST"] == "1",
            proofUID: uid, proofGroup: groupEntry.pointee.gr_gid
        )
        #endif
    }

    #if os(Linux)
    private static func safePath(_ value: String?, under root: String) -> String? {
        guard let value, value.hasPrefix(root), !value.contains(".."),
              value.dropFirst(root.count).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return value
    }

    private static func rootCommand(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch { return 127 }
    }

    private static func uidIsAvailable(_ uid: UInt32) -> Bool {
        guard getpwuid(uid) == nil,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return false }
        for entry in entries where entry.allSatisfy(\.isNumber) {
            guard let status = try? String(contentsOfFile: "/proc/\(entry)/status", encoding: .utf8),
                  let line = status.split(separator: "\n").first(where: { $0.hasPrefix("Uid:") }),
                  let observed = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().first.flatMap({ UInt32($0) })
            else { continue }
            if observed == uid { return false }
        }
        return true
    }

    private static func writeText(_ text: String, to path: String) -> Bool {
        guard let handle = FileHandle(forWritingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: Data(text.utf8))
            return true
        } catch { return false }
    }

    private static func supervise(
        leader: Int32, runnerPID: Int32, runnerStart: UInt64,
        cgroup: String, provenance: String, worktree: String, provesCleanup: Bool,
        proofUID: UInt32, proofGroup: UInt32
    ) -> Int32 {
        let traceFork: Int = 0x00000002 | 0x00000004 | 0x00000008
        let traceExec: Int = 0x00000010
        let traceExit: Int = 0x00000040
        let exitKill: Int = 0x00100000
        let options = traceFork | traceExec | traceExit | exitKill
        var initial: Int32 = 0
        guard waitpid(leader, &initial, 0) == leader, stopped(initial),
              linuxPtrace(0x4200, leader, nil, UnsafeMutableRawPointer(bitPattern: options)) == 0
        else {
            _ = writeText("1\n", to: cgroup + "/cgroup.kill")

            return refuse("the sandbox leader did not stop for PTRACE_SETOPTIONS, so its execs cannot be watched")
        }
        var traced: Set<Int32> = [leader]
        var tainted: [Int32: Bool] = [leader: false]
        var threadGroups: [Int32: Int32] = [leader: leader]
        var leaderStatus: Int32?
        // Existing reservation processes stop before a trusted network wrapper runs. Git resumes
        // after its local config is masked. gh resumes the others only after its preload has made
        // the credential-bearing process non-dumpable and raised SIGSTOP as acknowledgement.
        var shieldingPID: Int32?
        var shieldStarted = false
        var awaitingShieldStop = false
        var protectedOperation: ProtectedOperation?
        var maskedGitConfiguration: [String] = []
        var pendingShieldGroups: Set<Int32> = []
        var allShieldGroups: Set<Int32> = []
        var pausedTracees: Set<Int32> = []
        var cleanupProof: Int32?
        if provesCleanup {
            cleanupProof = spawnCleanupProof(
                leader: leader, uid: proofUID, group: proofGroup, cgroup: cgroup
            )
            guard cleanupProof != nil else {
                _ = writeText("1\n", to: cgroup + "/cgroup.kill")

                return refuse("the cleanup proof process could not be started, which the self test requires")
            }
        }
        defer { _ = terminateAndReapCleanupProof(&cleanupProof) }
        guard linuxPtrace(7, leader, nil, nil) == 0 else {
            return refuse("PTRACE_CONT was refused for the sandbox leader")
        } // PTRACE_CONT

        while !traced.isEmpty {
            var status: Int32 = 0
            let waited = waitpid(-1, &status, 0x40000000 | WNOHANG) // __WALL
            if waited == 0 {
                if leaderStatus != nil || PersonBoundProcIdentity.read(runnerPID)?.startTime != runnerStart {
                    guard writeText("1\n", to: cgroup + "/cgroup.kill") else {
                        return refuse("the Runner that reserved this sandbox is gone and its cgroup would not take a kill")
                    }
                }
                usleep(10_000)
                continue
            }
            if waited < 0 {
                if errno == EINTR { continue }
                if errno == ECHILD, let leaderStatus {
                    // Reached only with a leader status in hand; the refusal below is the other way out.
                    try? FileManager.default.removeItem(atPath: provenance)
                    guard terminateAndReapCleanupProof(&cleanupProof) else {
                        return refuse("the cleanup proof process outlived the sandbox it was proving")
                    }

                    return leaderStatus
                }

                return refuse("waiting on the sandbox failed with errno \(errno) before the leader reported a status")
            }
            if exited(status) || signalled(status) {
                if let proof = cleanupProof, waited == proof {
                    cleanupProof = nil
                    guard leaderStatus != nil else {
                        _ = writeText("1\n", to: cgroup + "/cgroup.kill")

                        return refuse("the cleanup proof process died while the sandbox it was proving was still running")
                    }
                    continue
                }
                if waited == shieldingPID {
                    if protectedOperation == .git,
                       !unmaskRepositoryConfiguration(maskedGitConfiguration) { return 1 }
                    for group in allShieldGroups { _ = kill(group, SIGCONT) }
                    for tracee in pausedTracees { _ = linuxPtrace(7, tracee, nil, nil) }
                    shieldingPID = nil
                    shieldStarted = false
                    awaitingShieldStop = false
                    protectedOperation = nil
                    maskedGitConfiguration = []
                    pendingShieldGroups = []
                    allShieldGroups = []
                    pausedTracees = []
                }
                if let group = threadGroups[waited] {
                    pendingShieldGroups.remove(group)
                }
                traced.remove(waited)
                tainted[waited] = nil
                threadGroups[waited] = nil
                if waited == leader {
                    leaderStatus = exitCode(status)
                    guard writeText("1\n", to: cgroup + "/cgroup.kill") else { return 1 }
                }
                if let shield = shieldingPID, pendingShieldGroups.isEmpty, !shieldStarted {
                    guard linuxPtrace(7, shield, nil, nil) == 0 else { return 1 }
                    shieldStarted = true
                }
                continue
            }
            guard stopped(status) else { continue }
            let event = UInt32(bitPattern: status) >> 16
            let stop = (status >> 8) & 0xff
            if let shield = shieldingPID {
                if waited == shield, protectedOperation == .gh,
                   awaitingShieldStop, event == 0, stop == SIGSTOP {
                    for group in allShieldGroups { _ = kill(group, SIGCONT) }
                    for tracee in pausedTracees {
                        _ = linuxPtrace(7, tracee, nil, nil)
                    }
                    shieldingPID = nil
                    shieldStarted = false
                    awaitingShieldStop = false
                    protectedOperation = nil
                    pendingShieldGroups = []
                    allShieldGroups = []
                    pausedTracees = []
                    guard linuxPtrace(7, waited, nil, nil) == 0 || errno == ESRCH else { return 1 }
                    continue
                }
                if waited != shield, let group = threadGroups[waited], allShieldGroups.contains(group) {
                    pendingShieldGroups.remove(group)
                    pausedTracees.insert(waited)
                    if pendingShieldGroups.isEmpty, !shieldStarted {
                        guard linuxPtrace(7, shield, nil, nil) == 0 else { return 1 }
                        shieldStarted = true
                    }
                    continue
                }
            }
            if event == 1 || event == 2 || event == 3 { // fork, vfork, clone
                var born: UInt = 0
                let read = withUnsafeMutablePointer(to: &born) {
                    linuxPtrace(0x4201, waited, nil, UnsafeMutableRawPointer($0)) // PTRACE_GETEVENTMSG
                }
                if read == 0, let pid = Int32(exactly: born) {
                    traced.insert(pid)
                    tainted[pid] = tainted[waited] ?? true
                    threadGroups[pid] = event == 3 ? processThreadGroup(pid) ?? pid : pid
                }
            } else if event == 4 { // PTRACE_EVENT_EXEC, stopped before user code runs
                var former: UInt = 0
                _ = withUnsafeMutablePointer(to: &former) {
                    linuxPtrace(0x4201, waited, nil, UnsafeMutableRawPointer($0))
                }
                let formerPID = Int32(exactly: former) ?? waited
                let group = threadGroups[formerPID] ?? threadGroups[waited] ?? waited
                let members = threadGroups.compactMap { $0.value == group ? $0.key : nil }
                let inherited = members.contains { tainted[$0] ?? true }
                for member in members {
                    traced.remove(member)
                    tainted[member] = nil
                    threadGroups[member] = nil
                }
                traced.insert(waited)
                threadGroups[waited] = waited
                let command = tracedCommand(waited)
                let controlled = command.map {
                    PersonBoundPeerOperation.repositoryControlled($0, worktree: worktree)
                } ?? true
                let untrusted = inherited || controlled
                tainted[waited] = untrusted
                let status = command == nil ? "tainted-unreadable" : inherited ? "tainted-inherited"
                    : controlled ? "tainted-controlled" : "trusted"
                guard let observed = command,
                      writeProvenance(observed, status: status, directory: provenance) else {
                    _ = writeText("1\n", to: cgroup + "/cgroup.kill")

                    return refuse("an exec could not be identified or its provenance could not be written to \(provenance)")
                }
                let isGh = command?.environment["LD_PRELOAD"] == MachineSandbox.personBoundCredentialShield
                    && URL(fileURLWithPath: command?.executable ?? "").lastPathComponent == "gh"
                let isNetworkGit = URL(fileURLWithPath: command?.executable ?? "").lastPathComponent == "git"
                    && command?.arguments.contains(where: { $0.contains("git-credential-v2") }) == true
                if shieldingPID == waited, shieldStarted {
                    if protectedOperation == .gh, isGh {
                        guard linuxPtrace(7, waited, nil, nil) == 0 else { return 1 }
                        awaitingShieldStop = true
                        continue
                    }
                    if protectedOperation == .git, isNetworkGit {
                        guard let masked = maskRepositoryConfiguration(worktree: worktree) else { return 1 }
                        maskedGitConfiguration = masked
                        guard linuxPtrace(7, waited, nil, nil) == 0 else { return 1 }
                        continue
                    }
                }
                let isProtectedWrapper = !untrusted
                    && (command?.arguments.contains("gh-v2") == true || command?.arguments.contains("git-v2") == true)
                    && URL(fileURLWithPath: command?.executable ?? "").lastPathComponent.hasPrefix("bloom-runner")
                if isProtectedWrapper {
                    let groups = Set(threadGroups.values).subtracting([waited])
                    shieldingPID = waited
                    protectedOperation = command?.arguments.contains("gh-v2") == true ? .gh : .git
                    pendingShieldGroups = groups
                    allShieldGroups = groups
                    for group in groups where kill(group, SIGSTOP) != 0 && errno != ESRCH { return 1 }
                    if groups.isEmpty {
                        guard linuxPtrace(7, waited, nil, nil) == 0 else { return 1 }
                        shieldStarted = true
                    }
                    continue
                }
                if isGh || isNetworkGit { return 1 }
            }
            let delivered = event == 0 && stop != SIGTRAP && stop != SIGSTOP ? stop : 0
            guard linuxPtrace(7, waited, nil, UnsafeMutableRawPointer(bitPattern: Int(delivered))) == 0
                    || errno == ESRCH else { return 1 }
        }
        try? FileManager.default.removeItem(atPath: provenance)
        guard terminateAndReapCleanupProof(&cleanupProof) else { return 1 }
        return leaderStatus ?? 1
    }

    /// What was exec'd, written where only root can read it, under a name carrying the pid and its
    /// start time so a reused pid cannot inherit another run's record.
    ///
    /// The command goes in beside the status now. The attestor used to re-read it from `/proc`
    /// when a credential was asked for, which needs CAP_SYS_PTRACE across uids and is therefore
    /// impossible on the machines this runs on. It is written here instead, by the tracer that saw
    /// the exec happen, and rewritten whenever the process execs again.
    private static func writeProvenance(
        _ command: PersonBoundPeerOperation.Command, status: String, directory: String
    ) -> Bool {
        let path = directory + "/\(command.identity.pid)-\(command.identity.startTime)"

        guard let encoded = try? JSONEncoder().encode(
            PersonBoundPeerOperation.ProvenanceRecord(status: status, command: command)
        ) else { return false }

        do {
            try encoded.write(to: URL(fileURLWithPath: path), options: .atomic)

            return chown(path, 0, 0) == 0 && chmod(path, 0o400) == 0
        } catch { return false }
    }

    private static func spawnCleanupProof(
        leader: Int32, uid: UInt32, group: UInt32, cgroup: String
    ) -> Int32? {
        let proof = fork()
        guard proof >= 0 else { return nil }
        if proof == 0 {
            guard setpgid(0, leader) == 0,
                  writeText(String(getpid()) + "\n", to: cgroup + "/cgroup.procs") else { _exit(125) }
            var groups = [group]
            guard groups.withUnsafeMutableBufferPointer({ setgroups($0.count, $0.baseAddress) }) == 0,
                  setgid(group) == 0, setuid(uid) == 0 else { _exit(125) }
            while true { pause() }
        }
        for _ in 0..<100 {
            if let members = try? String(contentsOfFile: cgroup + "/cgroup.procs", encoding: .utf8),
               members.split(whereSeparator: \.isWhitespace).contains(where: { Int32($0) == proof }) {
                return proof
            }
            var status: Int32 = 0
            if waitpid(proof, &status, WNOHANG) == proof { return nil }
            usleep(1_000)
        }
        var cleanupProof: Int32? = proof
        _ = terminateAndReapCleanupProof(&cleanupProof)
        return nil
    }

    private static func terminateAndReapCleanupProof(_ proof: inout Int32?) -> Bool {
        guard let pid = proof else { return true }
        guard kill(pid, SIGKILL) == 0 || errno == ESRCH else { return false }
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, 0)
            if waited == pid {
                proof = nil
                return true
            }
            if waited < 0, errno == EINTR { continue }
            if waited < 0, errno == ECHILD {
                proof = nil
                return true
            }
            return false
        }
    }

    /// The local scopes Git reads for a normal repository or a linked worktree.
    static func repositoryConfigurationPaths(worktree: String) -> [String]? {
        let files = FileManager.default
        let dotGit = URL(fileURLWithPath: worktree).appendingPathComponent(".git").path
        var directory: ObjCBool = false
        guard files.fileExists(atPath: dotGit, isDirectory: &directory) else { return [] }
        let gitDirectory: String
        if directory.boolValue {
            gitDirectory = dotGit
        } else {
            guard let marker = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  let line = marker.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
            let value = String(line.dropFirst("gitdir:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            gitDirectory = URL(fileURLWithPath: dotGit).deletingLastPathComponent()
                .appendingPathComponent(value).standardizedFileURL.path
        }
        let commonDirectory: String
        let commonMarker = URL(fileURLWithPath: gitDirectory).appendingPathComponent("commondir").path
        if let value = try? String(contentsOfFile: commonMarker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            commonDirectory = URL(fileURLWithPath: gitDirectory).appendingPathComponent(value).standardizedFileURL.path
        } else {
            commonDirectory = gitDirectory
        }
        let local = URL(fileURLWithPath: commonDirectory).appendingPathComponent("config").path
        var localDirectory: ObjCBool = false
        guard files.fileExists(atPath: local, isDirectory: &localDirectory), !localDirectory.boolValue else { return nil }
        let worktreeConfig = URL(fileURLWithPath: gitDirectory).appendingPathComponent("config.worktree").path
        var paths = [local]
        var worktreeDirectory: ObjCBool = false
        if files.fileExists(atPath: worktreeConfig, isDirectory: &worktreeDirectory), !worktreeDirectory.boolValue {
            paths.append(worktreeConfig)
        }
        return Array(Set(paths)).sorted()
    }

    private static func maskRepositoryConfiguration(worktree: String) -> [String]? {
        guard let paths = repositoryConfigurationPaths(worktree: worktree) else { return nil }
        var masked: [String] = []
        for path in paths {
            guard rootCommand("/usr/bin/mount", ["--bind", "/dev/null", path]) == 0 else {
                _ = unmaskRepositoryConfiguration(masked)
                return nil
            }
            masked.append(path)
        }
        return masked
    }

    private static func unmaskRepositoryConfiguration(_ paths: [String]) -> Bool {
        var succeeded = true
        for path in paths.reversed() {
            succeeded = rootCommand("/usr/bin/umount", [path]) == 0 && succeeded
        }
        return succeeded
    }

    /// Read as the process's own uid, because root on a machine may not: see
    /// `PersonBoundPeerOperation.liveCommandAsOwner`, which the attestor needs for the same reason.
    private static func tracedCommand(_ pid: Int32) -> PersonBoundPeerOperation.Command? {
        for _ in 0..<10 {
            if let command = PersonBoundPeerOperation.liveCommandAsOwner(pid) { return command }
            usleep(1_000)
        }

        return nil
    }

    private static func processThreadGroup(_ pid: Int32) -> Int32? {
        guard let status = try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8),
              let line = status.split(separator: "\n").first(where: { $0.hasPrefix("Tgid:") }) else { return nil }
        return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().first.flatMap { Int32($0) }
    }

    private static func stopped(_ status: Int32) -> Bool { status & 0xff == 0x7f }
    private static func exited(_ status: Int32) -> Bool { status & 0x7f == 0 }
    private static func signalled(_ status: Int32) -> Bool {
        let value = status & 0x7f
        return value != 0 && value != 0x7f
    }
    private static func exitCode(_ status: Int32) -> Int32 {
        exited(status) ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }

    /// A command named without a directory, found the way a shell would find it: on the `PATH`
    /// the child is about to run with, checked as the uid it now is.
    ///
    /// **`execve` does not search `PATH`, and the sandbox this replaced used `setpriv`, which
    /// does.** Agents are launched by name, `claude`, and found through the root-owned links in
    /// `/usr/local/bin` that provisioning makes. So every agent turn on a Cloud workspace exited
    /// 127 with "person-bound exec failed with errno 2" while the binary sat where it always had,
    /// because every test launched an absolute path and no agent turn had run through this.
    static func resolved(_ executable: String, path: String?) -> String {
        guard !executable.contains("/") else { return executable }
        for directory in (path ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(executable)"
            if access(candidate, X_OK) == 0 { return candidate }
        }

        return executable
    }

    private static func execute(arguments: [String], environment: [String: String]) -> Never {
        guard let named = arguments.first else { _exit(127) }
        let executable = resolved(named, path: environment["PATH"])
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.compactMap { $0 }.forEach { free(UnsafeMutableRawPointer($0)) }
            envp.compactMap { $0 }.forEach { free(UnsafeMutableRawPointer($0)) }
        }
        _ = argv.withUnsafeBufferPointer { argumentsBuffer in
            envp.withUnsafeBufferPointer { environmentBuffer in
                executable.withCString { path in
                    execve(path, argumentsBuffer.baseAddress!, environmentBuffer.baseAddress!)
                }
            }
        }
        let failure = "bloom-runner: person-bound exec of \(executable) failed with errno \(errno)\n"
        FileHandle.standardError.write(Data(failure.utf8))
        _exit(127)
    }
    #endif
}

enum PersonBoundSandboxCleanup {
    /// Called only after the in-memory binding was forgotten. The privileged command receives no
    /// token or grant, only the kernel identity and the two paths it must remove.
    static func invoke(
        executable: String, identity: PersonBoundProcessIdentity?, reservation: PersonBoundProcessRegistry.Reservation
    ) -> Bool {
        var environment = [
            "PATH": "/usr/bin:/bin",
            "BLOOM_PERSON_BOUND_CGROUP": reservation.cgroup,
            "BLOOM_PERSON_BOUND_HOME": MachineSandbox.personBoundHomeRoot + "/"
                + reservation.id.uuidString.lowercased(),
            "BLOOM_PERSON_BOUND_PROVENANCE": MachineSandbox.personBoundProvenanceRoot + "/"
                + reservation.id.uuidString.lowercased(),
        ]
        if let identity {
            environment["BLOOM_PERSON_BOUND_PID"] = String(identity.pid)
            environment["BLOOM_PERSON_BOUND_UID"] = String(identity.uid)
            environment["BLOOM_PERSON_BOUND_START"] = String(identity.startTime)
        }
        for _ in 0..<4 {
            if invokeRoot(executable: executable, command: "sandbox-cleanup", environment: environment) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// A killed Runner has no in-memory grants, but its numeric users and cgroups may still exist.
    /// Startup removes all of them before creating either socket or reporting the capability.
    static func cleanupStale(executable: String) -> Bool {
        for _ in 0..<4 {
            if invokeRoot(
                executable: executable, command: "sandbox-cleanup-stale",
                environment: ["PATH": "/usr/bin:/bin"]
            ) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    static func run(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        #if !os(Linux)
        return 1
        #else
        guard getuid() == 0,
              let cgroup = safePath(environment["BLOOM_PERSON_BOUND_CGROUP"], under: "/sys/fs/cgroup/bloom-person-bound/"),
              let home = safePath(environment["BLOOM_PERSON_BOUND_HOME"], under: MachineSandbox.personBoundHomeRoot + "/"),
              let provenance = safePath(
                  environment["BLOOM_PERSON_BOUND_PROVENANCE"], under: MachineSandbox.personBoundProvenanceRoot + "/"
              )
        else { return 1 }

        var succeeded = true
        if let pid = environment["BLOOM_PERSON_BOUND_PID"].flatMap(Int32.init),
           let uid = environment["BLOOM_PERSON_BOUND_UID"].flatMap(UInt32.init),
           let start = environment["BLOOM_PERSON_BOUND_START"].flatMap(UInt64.init),
           let observed = PersonBoundProcIdentity.read(pid),
           observed.pid == pid, observed.uid == uid, observed.startTime == start, observed.cgroup == cgroup,
           observed.processGroup == pid {
            succeeded = signal(-pid, SIGTERM) && succeeded
        }
        succeeded = cleanCgroup(cgroup) && succeeded
        succeeded = removeTree(home) && succeeded
        succeeded = removeTree(provenance) && succeeded
        return succeeded ? 0 : 1
        #endif
    }

    static func runStale() -> Int32 {
        #if !os(Linux)
        return 1
        #else
        guard getuid() == 0 else { return 1 }
        let files = FileManager.default
        let cgroupRoot = "/sys/fs/cgroup/bloom-person-bound"
        let homeRoot = MachineSandbox.personBoundHomeRoot
        let provenanceRoot = MachineSandbox.personBoundProvenanceRoot
        var succeeded = true

        setpwent()
        while let entry = getpwent() {
            if (200_000...299_999).contains(entry.pointee.pw_uid) {
                endpwent()
                return 1
            }
        }
        endpwent()

        if let entries = try? files.contentsOfDirectory(atPath: cgroupRoot) {
            for entry in entries {
                let candidate = cgroupRoot + "/" + entry
                var directory: ObjCBool = false
                guard files.fileExists(atPath: candidate, isDirectory: &directory), directory.boolValue else { continue }
                guard let path = safePath(candidate, under: cgroupRoot + "/") else {
                    succeeded = false
                    continue
                }
                succeeded = cleanCgroup(path) && succeeded
            }
        } else if files.fileExists(atPath: cgroupRoot) {
            succeeded = false
        }

        for _ in 0..<100 {
            guard let stale = personBoundProcesses() else { return 1 }
            if stale.isEmpty { break }
            for pid in stale { succeeded = signal(pid, SIGKILL) && succeeded }
            usleep(10_000)
        }
        guard let survivors = personBoundProcesses() else { return 1 }
        if !survivors.isEmpty { succeeded = false }

        if let entries = try? files.contentsOfDirectory(atPath: homeRoot) {
            for entry in entries {
                guard let path = safePath(homeRoot + "/" + entry, under: homeRoot + "/") else {
                    succeeded = false
                    continue
                }
                succeeded = removeTree(path) && succeeded
            }
        } else if files.fileExists(atPath: homeRoot) {
            succeeded = false
        }
        if let entries = try? files.contentsOfDirectory(atPath: provenanceRoot) {
            for entry in entries {
                guard let path = safePath(provenanceRoot + "/" + entry, under: provenanceRoot + "/") else {
                    succeeded = false
                    continue
                }
                succeeded = removeTree(path) && succeeded
            }
        } else if files.fileExists(atPath: provenanceRoot) {
            succeeded = false
        }
        return succeeded ? 0 : 1
        #endif
    }

    private static func invokeRoot(executable: String, command: String, environment: [String: String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "-E", executable, command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    #if os(Linux)
    private static func safePath(_ value: String?, under root: String) -> String? {
        guard let value, value.hasPrefix(root), !value.contains(".."),
              value.dropFirst(root.count).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return value
    }

    private static func writeText(_ text: String, to path: String) -> Bool {
        guard let handle = FileHandle(forWritingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: Data(text.utf8))
            return true
        } catch { return false }
    }

    private static func signal(_ pid: Int32, _ value: Int32) -> Bool {
        kill(pid, value) == 0 || errno == ESRCH
    }

    private static func cleanCgroup(_ path: String) -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: path) else { return true }
        guard writeText("1\n", to: path + "/cgroup.kill") else { return false }
        for _ in 0..<100 {
            guard let members = try? String(contentsOfFile: path + "/cgroup.procs", encoding: .utf8) else {
                return false
            }
            if members.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            usleep(10_000)
        }
        guard let members = try? String(contentsOfFile: path + "/cgroup.procs", encoding: .utf8),
              members.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        for _ in 0..<10 {
            if rmdir(path) == 0 || errno == ENOENT { return true }
            usleep(10_000)
        }
        return !files.fileExists(atPath: path)
    }

    private static func removeTree(_ path: String) -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: path) else { return true }
        do {
            try files.removeItem(atPath: path)
            return !files.fileExists(atPath: path)
        } catch {
            return false
        }
    }

    private static func personBoundProcesses() -> [Int32]? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
        var result: [Int32] = []
        for entry in entries where entry.allSatisfy(\.isNumber) {
            guard let pid = Int32(entry) else { return nil }
            let path = "/proc/\(entry)"
            guard let status = try? String(contentsOfFile: path + "/status", encoding: .utf8) else {
                if FileManager.default.fileExists(atPath: path) { return nil }
                continue
            }
            guard let line = status.split(separator: "\n").first(where: { $0.hasPrefix("Uid:") }),
                  let uid = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .dropFirst().first.flatMap({ UInt32($0) }) else { return nil }
            if (200_000...299_999).contains(uid) { result.append(pid) }
        }
        return result
    }
    #endif
}
