import Foundation

/// Docker recovery uses the existing pinned SSH connection and the service account's own
/// user unit. Installation remains a separate, explicit administrator action in Add Server.
public enum ServerDockerRecovery {
    public enum State: String, Decodable, Sendable {
        case ready
        case stopped
        case needsSetup
    }

    public struct Status: Decodable, Sendable {
        public let state: State
        public let serviceUser: String
        public let serviceHome: String
        public var message: String
        public var details: String?
    }

    /// Match explicit Docker availability failures, not any failed project that uses Docker.
    public static func isSetupFailure(log: String) -> Bool {
        log.lowercased().split(separator: "\n").contains { line in
            line.contains("docker is not available") || line.contains("cannot connect to the docker daemon")
                || line.contains("no docker daemon is available")
                || line.contains("docker daemon socket") && line.contains("permission denied")
                || line.contains("docker.sock") && (line.contains("permission denied") || line.contains("no such file"))
                || line.contains("docker:") && (line.contains("command not found") || line.contains("not found"))
        }
    }

    public static func inspect(using connection: ServerSetupConnection) async throws -> Status {
        try await perform(start: false, using: connection)
    }

    public static func start(using connection: ServerSetupConnection) async throws -> Status {
        try await perform(start: true, using: connection)
    }

    private static func perform(start: Bool, using connection: ServerSetupConnection) async throws -> Status {
        let result = try await connection.run(start ? "python3 - start" : "python3 - check", input: remoteScript, timeout: .seconds(60))
        try Task.checkCancellation()
        return try decode(result.stdout)
    }

    static func decode(_ output: String) throws -> Status {
        guard let line = output.split(separator: "\n").last,
              var status = try? JSONDecoder().decode(Status.self, from: Data(line.utf8)),
              status.serviceUser.range(of: "^[a-z][a-z0-9-]{0,30}$", options: .regularExpression) != nil,
              status.serviceHome.hasPrefix("/"), !status.serviceHome.split(separator: "/").contains("..") else {
            throw ServerSetupFailure.installation(code: "invalid_docker_status", message: "The server returned an invalid Docker status.",
                recovery: "Check the server connection and try again.")
        }
        status.message = ServerSetupDiagnostics.sanitise(status.message)
        status.details = ServerSetupDiagnostics.optional(status.details)
        return status
    }

    static let remoteScript = #"""
import json, os, pathlib, pwd, stat, subprocess, sys

class NeedsSetup(Exception):
    pass

def private_file(path, uid, limit=16384):
    # Reject links and special files before opening. These are all service-user-owned reads,
    # never privileged operations; O_NOFOLLOW also closes the final-component link race.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_mode & 0o022 or info.st_size > limit:
            raise NeedsSetup('The Docker configuration is not a regular file owned by this account.')
        return source.read(limit + 1).decode()

def invoke(arguments, environment):
    return subprocess.run(arguments, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, timeout=30)

def required(arguments, environment):
    result = invoke(arguments, environment)
    if result.returncode:
        raise NeedsSetup((result.stderr or result.stdout or 'The Docker command failed.')[-8192:])
    return result.stdout.strip()

def recover(account, uid, start=False):
    home = pathlib.Path(account.pw_dir)
    result = dict(state='needsSetup', serviceUser=account.pw_name, serviceHome=str(home),
                  message='Docker needs setup for this server account.')
    environment = dict(HOME=str(home), USER=account.pw_name, LOGNAME=account.pw_name,
        PATH='/usr/sbin:/usr/bin:/sbin:/bin', LANG='C.UTF-8', XDG_RUNTIME_DIR=f'/run/user/{uid}',
        DBUS_SESSION_BUS_ADDRESS=f'unix:path=/run/user/{uid}/bus')
    try:
        for path in (home, home/'bloom', home/'bloom/docker', home/'.config', home/'.config/systemd', home/'.config/systemd/user'):
            info = path.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != uid or info.st_mode & 0o022:
                raise NeedsSetup('The Docker configuration directory is not owned by this account.')
        marker = private_file(home/'bloom/docker/.bloom-managed', uid)
        if marker != 'Bloom rootless Docker v1\n':
            raise NeedsSetup('No Bloom-managed rootless Docker installation was found.')
        unit = private_file(home/'.config/systemd/user/docker.service', uid)
        starts = [line.strip() for line in unit.splitlines() if line.startswith('ExecStart=')]
        if starts != [f'ExecStart={home}/bloom/bin/dockerd-rootless.sh']:
            raise NeedsSetup('The existing Docker service does not match the managed rootless installation.')
        context = required(['/usr/bin/docker', 'context', 'show'], environment)
        endpoint = json.loads(required(['/usr/bin/docker', 'context', 'inspect', '--format', '{{json .Endpoints.docker.Host}}'], environment))
        if context != 'rootless' or endpoint != f'unix:///run/user/{uid}/docker.sock':
            raise NeedsSetup('The default Docker connection is not this account\'s private rootless daemon.')
        active = invoke(['/usr/bin/systemctl', '--user', 'is-active', 'docker.service'], environment)
        if active.returncode:
            if active.stdout.strip() not in ('inactive', 'failed', 'activating', 'deactivating'):
                raise NeedsSetup((active.stderr or 'The Docker user service could not be inspected.')[-8192:])
            if not start:
                result.update(state='stopped', message='Docker is stopped on this server.')
                return result
            required(['/usr/bin/systemctl', '--user', 'start', 'docker.service'], environment)
        info = json.loads(required(['/usr/bin/docker', 'info', '--format', '{{json .}}'], environment))
        if not any(option == 'name=rootless' or option.startswith('name=rootless,') for option in info.get('SecurityOptions', [])):
            raise NeedsSetup('Docker did not report rootless protection.')
        if info.get('DockerRootDir') != str(home/'bloom/docker/data'):
            raise NeedsSetup('Docker is using an unexpected data directory.')
        result.update(state='ready', message='Docker is running and ready for workspace setup.')
    except (OSError, ValueError, NeedsSetup, subprocess.TimeoutExpired) as error:
        result['details'] = str(error)[-8192:]
    return result

def main():
    uid = os.geteuid()
    account = pwd.getpwuid(uid)
    if uid == 0:
        result = dict(state='needsSetup', serviceUser=account.pw_name, serviceHome=account.pw_dir,
                      message='Connect as the Bloom service account to start its private Docker service.')
    else:
        result = recover(account, uid, start=sys.argv[1:] == ['start'])
    print(json.dumps(result), flush=True)

if __name__ == '__main__':
    main()
"""#
}
