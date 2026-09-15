import Foundation
import Testing
@testable import BloomCore

@Suite struct ServerDockerRecoveryTests {
    @Test(arguments: [
        "Docker is not available. Start Docker for the Bloom Server user, then retry setup.",
        "Cannot connect to the Docker daemon at unix:///run/user/1000/docker.sock. Is the docker daemon running?",
        "permission denied while trying to connect to the Docker daemon socket",
        "bash: docker: command not found",
        "/bin/sh: 1: docker: not found"
    ])
    func identifiesAvailabilityFailure(_ log: String) {
        #expect(ServerDockerRecovery.isSetupFailure(log: log))
    }

    @Test(arguments: ["Docker is ready\ncomposer install failed", "Docker build complete\nDatabase migration failed", "PHP: command not found", "Setup failed"])
    func doesNotOfferDaemonRecoveryForApplicationFailures(_ log: String) {
        #expect(!ServerDockerRecovery.isSetupFailure(log: log))
    }

    @Test func sanitisesServerDiagnostics() throws {
        let status = try ServerDockerRecovery.decode(#"{"state":"needsSetup","serviceUser":"bloom","serviceHome":"/home/bloom","message":"Docker needs setup","details":"password=not-for-display"}"#)
        #expect(status.state == .needsSetup)
        #expect(status.details?.contains("not-for-display") != true)
        #expect(throws: ServerSetupFailure.self) {
            try ServerDockerRecovery.decode(#"{"state":"ready","serviceUser":"bloom","serviceHome":"/home/../root","message":"ready"}"#)
        }
    }

    @Test(arguments: ["ready", "stopped", "start", "missing", "symlink", "wrong-unit", "wrong-context", "rootful", "wrong-data", "failed-start"])
    func isolatedRecovery(_ scenario: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bloom-docker-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("recover.py")
        try ServerDockerRecovery.remoteScript.write(to: script, atomically: true, encoding: .utf8)
        let python = try #require(Shell.which("python3"))
        let result = try await ServerCredentialImportProcess.run(python, ["-c", Self.harness, script.path, directory.path, scenario],
            environment: ["PATH": "/usr/bin:/bin"], timeout: 10, captureStderr: true)
        #expect(result.status == 0, "Isolated Docker recovery fixture failed: \(String(decoding: result.output, as: UTF8.self))")
        #expect(result.output == Data("passed\n".utf8))
    }

    private static let harness = #"""
import json, os, pathlib, sys, types
script, root, scenario = sys.argv[1:]
ns = {'__name__':'fixture'}
exec(compile(pathlib.Path(script).read_text(), '<docker-fixture>', 'exec'), ns)
home = pathlib.Path(root)/'home'
for relative in ('', 'bloom', 'bloom/docker', '.config', '.config/systemd', '.config/systemd/user'):
    (home/relative).mkdir(mode=0o700, exist_ok=True)
marker = home/'bloom/docker/.bloom-managed'
marker.write_text('Bloom rootless Docker v1\n')
unit = home/'.config/systemd/user/docker.service'
unit.write_text('[Service]\nExecStart=' + str(home) + '/bloom/bin/dockerd-rootless.sh \n')
if scenario == 'missing': marker.unlink()
if scenario == 'symlink': marker.unlink(); marker.symlink_to(unit)
if scenario == 'wrong-unit': unit.write_text('[Service]\nExecStart=/usr/bin/dockerd\n')
uid = os.geteuid()
account = types.SimpleNamespace(pw_name='bloom', pw_dir=str(home))
calls = []
def invoke(arguments, environment):
    calls.append(arguments)
    assert 'DOCKER_HOST' not in environment and 'DOCKER_CONTEXT' not in environment
    assert environment['HOME'] == str(home)
    assert environment['XDG_RUNTIME_DIR'] == f'/run/user/{uid}'
    assert arguments[0] in ('/usr/bin/docker', '/usr/bin/systemctl')
    code = 0; output = ''; error = ''
    if arguments[1:] == ['context', 'show']:
        output = 'default' if scenario == 'wrong-context' else 'rootless'
    elif arguments[1:3] == ['context', 'inspect']:
        output = json.dumps(f'unix:///run/user/{uid}/docker.sock')
    elif arguments[1:] == ['--user', 'is-active', 'docker.service']:
        code = 3 if scenario in ('stopped', 'start', 'failed-start') else 0
        output = 'inactive' if code else 'active'
    elif arguments[1:] == ['--user', 'start', 'docker.service']:
        if scenario == 'failed-start': code = 1; error = 'User service start failed'
    elif arguments[1] == 'info':
        output = json.dumps({'SecurityOptions': [] if scenario == 'rootful' else ['name=rootless'],
            'DockerRootDir': '/var/lib/docker' if scenario == 'wrong-data' else str(home/'bloom/docker/data')})
    else: raise AssertionError(arguments)
    return types.SimpleNamespace(returncode=code, stdout=output, stderr=error)
ns['invoke'] = invoke
result = ns['recover'](account, uid, scenario in ('start', 'failed-start'))
expected = 'ready' if scenario in ('ready', 'start') else 'stopped' if scenario == 'stopped' else 'needsSetup'
assert result['state'] == expected, result
starts = [call for call in calls if call == ['/usr/bin/systemctl', '--user', 'start', 'docker.service']]
assert len(starts) == (1 if scenario in ('start', 'failed-start') else 0), calls
if scenario in ('missing', 'symlink', 'wrong-unit'): assert not calls
if scenario == 'wrong-context': assert not any('--user' in call for call in calls)
print('passed')
"""#
}
