import AsyncHTTPClient
import BloomCore
import BloomProtocol
import Foundation
import Hummingbird
import ServiceLifecycle
import Synchronization

/// `bloom-runner serve`: everything a machine runs, put together once.
///
/// The order matters in three places. The first summary goes before setup starts, because that
/// summary is what makes runbloom.app hand out tokens, and setup output is worth watching live.
/// The HTTP server is listening before setup starts for the same reason. And on the way out the
/// machine reports and closes streams before anything stops, so a limit or an update that ends
/// the process still leaves runbloom.app knowing where things stood.
public enum ServeCommand {
    public static func run(environment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        /*
         * The worktree is shared between the Runner and `bloom-agent` through the `bloom-work`
         * group, and setgid keeps new files in that group. It does not make them writable by it:
         * with the default 022 a file lands 0644, so each of them could read the other's work and
         * not change it. A checkout, a merge, the Runner writing into the repository, the agent
         * editing a file the Runner made: all refused, while deleting the same file worked, because
         * that needs the directory rather than the file. 002 is the umask a shared group directory
         * wants, and the group has exactly these two members.
         */
        umask(0o002)

        var bootConfiguration = try MachineConfiguration.load(environment: environment)
        let layout = MachineLayout.from(environment: environment)
        try FileManager.default.createDirectory(atPath: layout.dataDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let store = try Store(path: layout.databasePath)
        let runnerExecutable = MachineSetup.currentExecutable
        // Found rather than assumed. `/usr/bin/gh` is where CI puts the one it compiles and is not
        // where a Sprite keeps it, which stopped every Cloud workspace created on 21 September 2026
        // at `static host checks` with `gh` sitting in `/.sprite/bin`, root owned and usable. What
        // matters is that root owns it and nobody else can write it, and that is what is checked.
        guard let gitExecutable = PersonBoundTrustedExecutable.find("git") else {
            throw MachineConfigurationError(
                "No Git this machine can be trusted with was found. Looked on PATH and in "
                    + PersonBoundTrustedExecutable.searchDirectories.joined(separator: ", ")
                    + ". It must be owned by root, with no group or other write, every directory above it too."
            )
        }
        guard let ghExecutable = PersonBoundTrustedExecutable.find("gh") else {
            throw MachineConfigurationError(
                "No gh this machine can be trusted with was found. Looked on PATH and in "
                    + PersonBoundTrustedExecutable.searchDirectories.joined(separator: ", ")
                    + ". It must be owned by root, with no group or other write, every directory above it too."
            )
        }
        guard let gitRemoteHTTPSExecutable = PersonBoundGitCommand.gitRemoteHTTPSExecutable(
            gitExecutable: gitExecutable
        ) else {
            throw MachineConfigurationError(
                "The root-owned Git HTTPS transport required for person-bound credentials was not found."
            )
        }
        guard let personBound = await PersonBoundRuntimeFoundation.live(
            executable: runnerExecutable, repository: bootConfiguration.repository,
            worktree: layout.worktree, gitExecutable: gitExecutable, ghExecutable: ghExecutable,
            gitRemoteHTTPSExecutable: gitRemoteHTTPSExecutable
        ) else {
            throw MachineConfigurationError(
                "This host did not pass every mandatory person-bound credential runtime self-test."
            )
        }
        defer { personBound.launcher.close() }
        guard let sandbox = MachineSandbox.available() else {
            throw MachineConfigurationError(
                "The mandatory repository script and service sandbox is unavailable."
            )
        }
        let http = HTTPClient(eventLoopGroupProvider: .singleton)
        let workspaceID = bootConfiguration.workspaceID
        // Only the secret is taken from a rewritten file. Everything else in it is fixed for the
        // life of the workspace, and a file naming another workspace is not this machine's.
        let secret = WorkspaceSecret(bootConfiguration.workspaceSecret) {
            let fresh = try MachineConfiguration.load(environment: environment)
            guard fresh.workspaceID == workspaceID else {
                throw MachineConfigurationError("workspace.json now names another workspace.")
            }
            return fresh.workspaceSecret
        }
        guard let machineID = bootConfiguration.machineIdentity?.machineID else {
            throw MachineIdentityError.invalidConfiguration("machine_identity is absent")
        }
        let identity = try MachineIdentitySigner.live(
            machineID: machineID,
            workspaceID: WorkspaceID(bootConfiguration.workspaceID),
            executable: runnerExecutable
        )
        let client = RunbloomClient(
            baseURL: bootConfiguration.baseURL, workspaceID: bootConfiguration.workspaceID,
            secret: secret, http: http, identity: identity
        )
        let configurationPath = environment["BLOOM_WORKSPACE_CONFIG"] ?? MachineConfiguration.defaultPath
        try await MachineIdentityBootstrap.establish(
            configuration: &bootConfiguration, client: client, signer: identity,
            configurationPath: configurationPath
        )
        let configuration = bootConfiguration
        let modelGateway = ModelGateway(client: client)
        let modelGatewayServer = try await ModelGatewayServer.start(gateway: modelGateway)
        defer { modelGatewayServer.cancel() }
        let gate = RunbloomTurns(
            client: client, modelGateway: modelGateway,
            modelGatewayBaseURL: modelGatewayServer.baseURL,
            modelGatewayUsable: { modelGatewayServer.isReady }
        )
        let personBoundBroker = PersonBoundCredentialBroker(
            repository: configuration.repository,
            registry: personBound.registry,
            operation: { peer, binding, declared in
                PersonBoundPeerOperation.attest(
                    peer: peer, binding: binding, declared: declared,
                    runnerExecutable: runnerExecutable
                )
            }
        ) {
            try await client.githubCredentials(grant: $0, operation: $1, requestID: $2)
        }
        let runPersonBoundCommand: RemotePublishing.Run = { executable, arguments, cwd, context in
            guard ["git", "gh"].contains(executable), let grant = context.githubCredentialGrant,
                  let reservation = personBound.registry.reserve(
                      .turn(id: context.turnID, userID: context.userID)
                  ) else {
                throw RemoteFailure(.unavailable, "The isolated publishing command could not be reserved.")
            }
            personBoundBroker.install(
                PersonBoundGithubGrant(
                    token: grant.token, expiresAt: grant.expiresAt, revision: grant.revision
                ), for: reservation
            )
            var environment = Shell.environment()
            environment["BLOOM_REPOSITORY"] = configuration.repository
            environment["BLOOM_RUNNER_EXECUTABLE"] = runnerExecutable
            environment["BLOOM_REAL_GIT"] = gitExecutable
            environment["BLOOM_REAL_GH"] = ghExecutable
            environment["BLOOM_REAL_GIT_REMOTE_HTTPS"] = gitRemoteHTTPSExecutable
            environment["BLOOM_CREDENTIAL_SOCKET_V2"] = MachineSandbox.credentialV2SocketPath
            let launch = AgentLaunch(
                executable: runnerExecutable,
                arguments: [executable == "git" ? "git-v2" : "gh-v2"] + arguments,
                cwd: cwd, environment: environment
            )
            let prepared = personBound.launcher.prepare(launch, reservation: reservation)
            let process = StreamingProcess(
                executable: prepared.launch.executable, arguments: prepared.launch.arguments,
                cwd: prepared.launch.cwd, environment: prepared.launch.environment,
                mergeStderr: false,
                cleanup: {
                    personBoundBroker.forget(reservation)
                    prepared.cleanup()
                }
            )
            let errors = Task {
                var lines: [String] = []
                for await line in process.errorLines { lines.append(line) }
                return lines
            }
            var output: [String] = []
            for try await line in process.lines { output.append(line) }
            let status = await process.exitStatus
            let errorOutput = await errors.value
            return ShellResult(
                status: status,
                stdout: output.isEmpty ? "" : output.joined(separator: "\n") + "\n",
                stderr: errorOutput.isEmpty ? "" : errorOutput.joined(separator: "\n") + "\n"
            )
        }
        let workspace = try await RemoteMachineWorkspace.ensure(
            store: store, id: configuration.workspaceID, name: configuration.name, repository: configuration.repository,
            path: layout.worktree, branch: configuration.branch, baseBranch: configuration.baseBranch
        )
        let version = RunnerVersion.current
        FileHandle.standardError.write(Data("bloom-runner: repository scripts and services run as \(sandbox.user)\n".utf8))
        let binDirectory = MachineSandbox.personBoundSharedDirectory + "/bin"
        let bridgeDirectory = MachineSandbox.sharedDirectory
        // Who may be addressed, pulled from runbloom.app and refetched on a miss so that somebody
        // who joined the team this morning is addressable this afternoon. See `MachineMembers`.
        let members = MachineMembers { try await client.members() }
        // The word that somebody was addressed, which is what lets runbloom.app mail them. Its own
        // sender rather than a fold into the usage queue, because it causes mail: see
        // `AddressedReporter`.
        let addressedReporter = AddressedReporter(store: store) { try await client.reportAddressed($0) }
        let runtime = WorkspaceRuntime(
            store: store, workspaceID: workspace.id, gate: gate,
            makeRunner: { session, path, store, environment, bridge, context in
                // Every agent process finds Bloom's Git and gh wrappers before the system tools.
                // The credential door trusts only the root-attested launch registration.
                var extra = environment
                extra["BLOOM_REPOSITORY"] = configuration.repository
                extra["BLOOM_DATA_DIR"] = layout.dataDirectory
                extra["BLOOM_RUNNER_PORT"] = String(layout.serverPort)
                extra["BLOOM_CREDENTIAL_SOCKET_V2"] = MachineSandbox.credentialV2SocketPath
                extra["PATH"] = binDirectory + ":" + (environment["PATH"] ?? Shell.environment()["PATH"] ?? "/usr/bin:/bin")
                guard let context, let grant = context.githubCredentialGrant else {
                    throw RemoteFailure(.unavailable, "This turn has no person-bound GitHub credential grant.")
                }
                let unclaimed = Mutex(true)
                let isolate: RemoteRunnerFactory.Isolate = { launch in
                    let claimed = unclaimed.withLock { available -> Bool in
                        guard available else { return false }
                        available = false
                        return true
                    }
                    guard claimed, let reservation = personBound.registry.reserve(
                        .turn(id: context.turnID, userID: context.userID)
                    ) else {
                        return .init(
                            launch: AgentLaunch(
                                executable: "/usr/bin/false", arguments: [], cwd: launch.cwd,
                                environment: [:]
                            ), cleanup: {}
                        )
                    }
                    personBoundBroker.install(
                        PersonBoundGithubGrant(
                            token: grant.token, expiresAt: grant.expiresAt, revision: grant.revision
                        ), for: reservation
                    )
                    let prepared = personBound.launcher.prepare(launch, reservation: reservation)
                    return .init(launch: prepared.launch) {
                        personBoundBroker.forget(reservation)
                        prepared.cleanup()
                    }
                }
                return RemoteRunnerFactory.make(
                    session, path, store, extra, bridge, sandbox: nil, isolate: isolate
                )
            },
            publishing: RemotePublishing(run: runPersonBoundCommand),
            retiresRunnerAfterTurn: true,
            // Short and group-shared when the sandboxed agent has to reach it. A machine without
            // that second user keeps the socket beside its private data, as it did before.
            bridgeSocketPath: bridgeDirectory + "/bridge.sock",
            bridgeAccess: .sharedGroup,
            runsSetup: configuration.runsSetup,
            briefing: BridgeBriefing.machine(
                publicURL: configuration.publicURL, appPort: layout.appPort, reservedPorts: layout.reservedPorts
            ),
            lookUpMember: { await members.look(up: $0) },
            listMembers: { await members.all() },
            addressed: { _ in await addressedReporter.start() },
            createCloudWorkspace: { await client.createCloudWorkspace($0) },
            peers: RunbloomPeers.peers(client: client, http: http),
            sandbox: nil,
            sharedDirectory: MachineSandbox.sharedDirectory
        )
        let host: any MachineHost = SpriteMachineHost.isAvailable ? SpriteMachineHost(http: http) : LocalMachineHost()
        // What the machine says about its own reporting goes two ways here, because the two readers
        // are different people: to the workspace record, so anybody looking at the workspace sees
        // that what they are doing is not being recorded, and to the log with the queue's depth,
        // for whoever reads a machine afterwards. The third reader is runbloom.app, which is told
        // about shedding by `MachineReporter` in the next report it can send.
        let shedSoFar = Mutex(0)
        let delivery = ReportDelivery(sender: .init(client: client), observer: { status in
            await runtime.reportingChanged(status.record)
            let newlyShed = shedSoFar.withLock { shed -> Int in
                defer { shed = status.shed }
                return status.shed - shed
            }
            if newlyShed > 0 {
                note("shed \(newlyShed) unsent usage report(s); \(status.queued) queued, \(status.queuedBytes) bytes")
            }
            if let since = status.unreachableSince {
                // Not "unreachable": the three things that reach here are a network that answered
                // nothing, a server that erred, and a machine that was asleep, and only the first
                // is what that word means. What is true of all of them is that nothing has been
                // recorded since.
                note("nothing reported to runbloom.app since \(WireDate.string(from: since)); "
                     + "\(status.queued) report(s) queued, \(status.queuedBytes) bytes")
            }
        })
        let reporter = MachineReporter(
            runtime: runtime, store: store, delivery: delivery, host: host, version: version,
            capabilitiesProvider: {
                personBound.capabilities
                    + [MachineIdentitySigner.capability]
                    + (modelGatewayServer.isReady ? [ModelGateway.capability] : [])
            }
        )
        let awake = AwakeController(host: host, runtime: runtime, reporter: reporter)
        let machineEnvironment = MachineEnvironment(
            fetchVariables: { try await client.environment() },
            fetchSecrets: { try await client.secrets(for: $0) }
        )
        let keys = KeySet.live(url: configuration.jwksURL, client: http)
        let verifier = TokenVerifier(issuer: configuration.issuer, workspaceID: configuration.workspaceID, keys: keys,
                                     revocations: Revocations(store: store))

        await runtime.observeActivity { event in
            switch event {
            case .turnStarted(_, let turnID, let author, let agent):
                if let turnID { await reporter.record(.turnStarted(turnID: turnID, userID: author?.userID, agent: agent, at: Date())) }
                await reporter.changed()
            case .turnFinished(_, let turnID):
                // runbloom.app pairs a finish with its start by the turn, so a turn nobody
                // registered (a subagent's report) is reported as neither.
                if let turnID { await reporter.record(.turnFinished(turnID: turnID, at: Date())) }
                await reporter.changed()
            case .chatIdle:
                await reporter.changed()
            case .setupStarted:
                await reporter.record(.setupStarted(at: Date()))
                await reporter.changed()
            case .setupStep:
                await reporter.changed()
            case .setupFinished(let succeeded):
                await reporter.record(.setupFinished(succeeded: succeeded, at: Date()))
                await reporter.changed()
            case .humanInput:
                break
            case .workspaceChanged:
                await reporter.changed()
                return
            case .connectionsChanged(let open):
                await awake.connectionsChanged(open: open)
                await reporter.changed(slow: true)
                return
            }
            await awake.nudge()
        }

        try await runtime.start()
        // Whatever the last run could not deliver, including the case this exists for: a machine
        // that stopped between writing the message and telling runbloom.app about it.
        await addressedReporter.start()
        await reporter.postSummaryNow()
        await machineEnvironment.refresh()

        let streams = EventStreams()
        let terminals = TerminalConnections()
        let supervisor = MachineSupervisor(
            runtime: runtime, awake: awake, reporter: reporter, streams: streams, terminals: terminals,
            environment: machineEnvironment, secret: secret, revocations: verifier.revocations, updater: { version, sha256, tag, downloadURL in
                try MachineUpdate.start(version: version, sha256: sha256, tag: tag, downloadURL: downloadURL)
            }
        )
        // The supervisor's own states, on the workspace record, because a service that never
        // started is otherwise a sentence held in this process's memory and reachable only through
        // a preview page that a project's own proxy can make unreachable. See `ServiceRecord`.
        let services = ServiceSupervisor(
            layout: layout,
            sandbox: sandbox,
            scopedEnvironment: { serviceID, base in
                try await machineEnvironment.scoped(.service(id: serviceID, launchID: UUID()), base: base)
            },
            observer: { [weak runtime] statuses in
            await runtime?.servicesChanged(statuses.map {
                ServiceRecord(name: $0.name, state: $0.state.rawValue, restarts: $0.restarts,
                              message: $0.message, isHTTP: $0.isHTTP)
            })
        })
        let server = WorkspaceHTTPServer(dependencies: .init(
            runtime: runtime, verifier: verifier, gate: gate, control: supervisor, store: store,
            allowedOrigins: configuration.allowedOrigins, version: version, streams: streams, terminals: terminals,
            // On again, as the sandbox user every agent already runs as. It was switched off until
            // terminals had a person-bound identity of their own, nobody built that, and a Cloud
            // workspace had no shell at all: the client read the empty refusal as a dropped
            // connection and said "Still trying to get back to your shell" for ever. A pane is not
            // an attested process, so network git and gh in it are refused rather than handed a
            // person's credential. Agreed with Freek on 23 September 2026.
            terminalsEnabled: true,
            services: { await services.status },
            appPort: layout.appPort,
            reservedPorts: layout.reservedPorts.map(\.port) + [modelGatewayServer.port]
        ))

        let credentialSocket = try PersonBoundCredentialSocket(
            path: MachineSandbox.credentialV2SocketPath, group: MachineSandbox.sharedGroup
        ) { request, peer in
            await personBoundBroker.credential(for: request, peer: peer)
        }
        defer { credentialSocket.close() }

        let caddy = CaddySupervisor(layout: layout, publicURL: configuration.publicURL)
        let setup = MachineSetup(
            runtime: runtime, store: store, configuration: configuration, layout: layout,
            environment: machineEnvironment, services: services,
            isolateNetworkGit: { launch in
                /*
                 * **Every refusal here used to be silent, and the fallback is a clone that cannot
                 * work.** When this returns nil, setup runs plain `git clone` with no credential
                 * helper at all, which dies as "fatal: unable to get password from user" with
                 * nothing in any log to say why the isolated path was not taken. A day was spent
                 * on the Runner's own credential machinery over a message that meant this.
                 */
                func refuse(_ reason: String) -> RemoteRunnerFactory.IsolatedLaunch? {
                    FileHandle.standardError.write(Data(
                        "bloom-runner: the isolated git could not be prepared: \(reason)\n".utf8
                    ))

                    return nil
                }
                guard launch.executable == "git" else { return nil }
                guard await delivery.flush(timeout: .seconds(15)) else {
                    return refuse("the report queue did not drain in fifteen seconds")
                }
                let grant: PersonBoundGithubGrant
                do {
                    grant = try await client.bootstrapGithubCredentialGrant()
                } catch {
                    return refuse("runbloom.app refused a bootstrap credential grant: \(error)")
                }
                guard let reservation = personBound.registry.reserve(.bootstrap) else {
                    return refuse("the launch gate would not reserve a sandbox")
                }
                personBoundBroker.install(grant, for: reservation)
                var environment = launch.environment
                environment["BLOOM_REPOSITORY"] = configuration.repository
                environment["BLOOM_RUNNER_EXECUTABLE"] = runnerExecutable
                environment["BLOOM_REAL_GIT"] = gitExecutable
                environment["BLOOM_REAL_GH"] = Shell.which("gh") ?? "/usr/bin/gh"
                environment["BLOOM_REAL_GIT_REMOTE_HTTPS"] = gitRemoteHTTPSExecutable
                environment["BLOOM_CREDENTIAL_SOCKET_V2"] = MachineSandbox.credentialV2SocketPath
                let protected = AgentLaunch(
                    executable: runnerExecutable, arguments: ["git-v2"] + launch.arguments,
                    cwd: launch.cwd, environment: environment
                )
                let prepared = personBound.launcher.prepare(protected, reservation: reservation)
                return .init(launch: prepared.launch) {
                    personBoundBroker.forget(reservation)
                    prepared.cleanup()
                }
            }, syncServiceManifest: { try await client.syncServiceManifest($0) },
            sandbox: sandbox
        )
        await machineEnvironment.observe { await setup.restartServices() }
        // `stop_setup` reaches the machine's own setup through here; one run by hand is the
        // runtime's own to stop. See `MachineSetup.stop(by:)`.
        await runtime.setSetupStopper { name in await setup.stop(by: name) }
        await runtime.setSetupRerunner { await setup.rerunSetup() }
        // Caddy first, so the machine's URL answers while setup runs; a machine without it still
        // serves Bloom Runner on its own port, which is what development on a Mac does.
        do {
            try await caddy.start()
        } catch {
            FileHandle.standardError.write(Data("bloom-runner: \(error)\n".utf8))
        }

        let projectIcons = ProjectIconDiscoveryMonitor(
            repositoryPath: layout.worktree,
            loadRequest: { try await client.projectIconRequest() },
            report: { try await client.reportProjectIcon($0) },
            loadState: { try await store.setting(ProjectIconDiscoveryMonitor.stateSetting) },
            saveState: { try await store.setSetting(ProjectIconDiscoveryMonitor.stateSetting, $0) },
            isAwake: { await awake.holding }
        )
        let measurements = WorktreeMeasurements(runtime: runtime, reporter: reporter)
        await awake.whenWaking {
            await machineEnvironment.refresh()
            await projectIcons.woke()
        }
        await awake.start()
        await measurements.start()
        // After the first summary and with the server about to listen, so setup can be watched live.
        // The opening prompt, when an agent created this workspace with one, after setup so it runs
        // on an installed project; after a failed setup too, so the person sees why. See
        // `OpeningHandoff`.
        let openings = OpeningHandoff(client: client, runtime: runtime)
        let setupRun = Task {
            await setup.run()
            guard !Task.isCancelled else { return }
            await projectIcons.start(initialRequest: configuration.projectIconRequest)
            await openings.run()
        }
        // An update waits for this file to go: deleting it once listening is how a new release says
        // it came up, which works whether or not the script that restarted the service survived it.
        let application = server.application(port: layout.serverPort) { _ in
            try? FileManager.default.removeItem(atPath: environment["BLOOM_UPDATE_MARKER"] ?? "/var/tmp/bloom-update-pending")
        }

        // SIGTERM: a limit's grace ran out, an update is restarting the service, or the machine is
        // being deleted. The wind down runs before the HTTP server stops, not after: the server's
        // graceful shutdown waits for every request to finish, and an event stream or a terminal
        // never does, so a machine with one client connected never got as far as reporting.
        let windDown = WindDown {
            note("stopping: stopping turns, reporting to runbloom.app and closing streams")
            // Setup first, filed as interrupted, so nothing it would start begins now.
            setupRun.cancel()
            await setupRun.value
            await projectIcons.stop()
            await measurements.stop()
            // Turns before the report, so the last usage report has every turn finishing in it.
            // This also closes every event stream.
            await runtime.shutdown()
            await modelGateway.shutdown()
            await modelGatewayServer.stop()
            await terminals.closeAll()
            await services.stopAll()
            await caddy.stop()
            await awake.shutdown()
        }
        // A service group shuts its services down in reverse order, so the wind down goes first.
        let group = ServiceGroup(configuration: .init(
            services: [.init(service: application), .init(service: windDown, successTerminationBehavior: .gracefullyShutdownGroup)],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: application.logger
        ))
        try await group.run()
        await delivery.shutdown()
        try await http.shutdown()
        note("stopped")
    }

    static func note(_ line: String) {
        FileHandle.standardError.write(Data("bloom-runner: \(line)\n".utf8))
    }

}

/// Waits for the service group to begin shutting down, then does the machine's own shutdown.
struct WindDown: Service {
    let work: @Sendable () async -> Void

    func run() async throws {
        // Throws only when the group is cancelled, which is a shutdown too.
        try? await gracefulShutdown()
        await work()
    }
}
