"""Exact, reviewed upgrades for the Ubuntu packages used by Bloom's rootless Docker installer."""
import dataclasses
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import selectors
import signal
import stat
import subprocess
import time
import urllib.parse

PACKAGES = ('docker.io', 'docker-compose-v2', 'docker-buildx', 'uidmap', 'rootlesskit',
            'slirp4netns', 'dbus-user-session')
VERSION = re.compile(r'[0-9][A-Za-z0-9.+:~\-]{0,199}')
MAX_OUTPUT = 1024 * 1024
ENVIRONMENT = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8',
               'HOME': '/root', 'DEBIAN_FRONTEND': 'noninteractive', 'NEEDRESTART_MODE': 'l'}
APT_OPTIONS = ('-o', 'DPkg::Lock::Timeout=0', '-o', 'APT::Get::AllowUnauthenticated=false',
               '-o', 'APT::Get::allow-Downgrades=false', '-o', 'APT::Get::allow-Remove-Essential=false',
               '-o', 'APT::Get::allow-Change-Held-Packages=false')


class DockerMaintenanceError(Exception):
    def __init__(self, code, message, recovery='Review Docker maintenance output before retrying.'):
        super().__init__(message)
        self.code, self.recovery = code, recovery


@dataclasses.dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str


def _require(condition, code, message, recovery='Review the server configuration before retrying.'):
    if not condition:
        raise DockerMaintenanceError(code, message, recovery)


def _safe_line(text):
    def url(match):
        try:
            value = urllib.parse.urlsplit(match.group())
            host = value.hostname or 'redacted'
            return urllib.parse.urlunsplit((value.scheme, host, value.path, '', ''))
        except ValueError:
            return '[URL redacted]'
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    text = ''.join(c for c in text if c == '\t' or ord(c) >= 32)
    text = re.sub(r'https?://[^\s<>]+', url, text)
    text = re.sub(r'(?i)\b(?:authorization|password|token|secret|credential)\s*[:=]\s*\S+', '[credential redacted]', text)
    return text[:3000]


def run_command(arguments, *, account=None, timeout=30, log=None):
    """Drain both streams with fixed memory/time limits. Only this process group may be stopped."""
    environment = dict(ENVIRONMENT)
    options = {}
    if account:
        environment.update(HOME=account.pw_dir, USER=account.pw_name, LOGNAME=account.pw_name,
                           XDG_RUNTIME_DIR=f'/run/user/{account.pw_uid}',
                           DBUS_SESSION_BUS_ADDRESS=f'unix:path=/run/user/{account.pw_uid}/bus')
        options = dict(user=account.pw_uid, group=account.pw_gid, extra_groups=[])
    started = time.monotonic()
    process = subprocess.Popen(list(arguments), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, env=environment, cwd='/', close_fds=True,
                               start_new_session=True, **options)
    output = bytearray()
    pending = bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                if time.monotonic() - started >= timeout:
                    raise DockerMaintenanceError('command_timeout', f'{arguments[0]} did not finish within {timeout} seconds.',
                        'The package operation may be incomplete. Ask the administrator to check dpkg before retrying; no rollback was attempted.')
                for key, _ in selector.select(timeout=min(0.25, max(0.01, timeout))):
                    data = os.read(key.fileobj.fileno(), 16384)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    output.extend(data)
                    _require(len(output) <= MAX_OUTPUT, 'output_limit', 'Docker maintenance output exceeded its safety limit.',
                             'The package operation may be incomplete. Check dpkg before retrying.')
                    if log:
                        pending.extend(data)
                        while b'\n' in pending:
                            line, _, remainder = pending.partition(b'\n')
                            pending = bytearray(remainder)
                            log(_safe_line(line.decode('utf-8', errors='replace')))
            if log and pending:
                log(_safe_line(pending.decode('utf-8', errors='replace')))
        remaining = max(0.01, timeout - (time.monotonic() - started))
        return CommandResult(process.wait(timeout=remaining), output.decode('utf-8', errors='replace'))
    except BaseException:
        # Never touch another APT process or remove a lock file. An interrupted operation is
        # reported as incomplete; dpkg recovery belongs to the administrator.
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        raise
    finally:
        process.stdout.close()


def _run(runner, arguments, *, account=None, timeout=30, log=None, allowed=(0,)):
    result = runner(tuple(arguments), account=account, timeout=timeout, log=log)
    _require(isinstance(result.stdout, str) and len(result.stdout.encode()) <= MAX_OUTPUT,
             'output_limit', 'Docker maintenance returned too much output.')
    if result.returncode not in allowed:
        details = '\n'.join(_safe_line(line) for line in result.stdout.splitlines()[-20:])
        locked = any(text in result.stdout.lower() for text in ('could not get lock', 'unable to acquire', 'is another process using it'))
        raise DockerMaintenanceError('package_lock' if locked else 'command_failed',
            f'{arguments[0]} exited with status {result.returncode}.\n{details}',
            'Wait for the other package manager to finish, then review the update again. Bloom never removes package locks.' if locked
            else 'The package operation may be incomplete. Review this output and check dpkg before retrying. No rollback was attempted.')
    return result


def _protected(path, *, directory=False):
    path = Path(path)
    _require(path.is_absolute() and '..' not in path.parts, 'unsafe_path', 'Docker maintenance found an invalid system path.')
    # Ubuntu legitimately symlinks python3 and os-release. Both the link path and its resolved
    # target must be protected; a user-owned target is never executed with administrator rights.
    resolved = path.resolve(strict=True)
    for item in (path, *path.parents, resolved, *resolved.parents):
        info = item.lstat()
        _require(info.st_uid == 0 and not info.st_mode & 0o022, 'unsafe_path',
                 f'Docker maintenance requires a root-protected path: {item}')
    info = resolved.lstat()
    _require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode),
             'unsafe_path', f'Docker maintenance found an unexpected path type: {path}')
    return resolved


def _validate_host(config):
    _require(os.geteuid() == 0, 'root_required', 'Docker package updates require the managed maintenance supervisor.')
    uid, gid, home = config.get('uid'), config.get('gid'), config.get('service_home')
    _require(type(uid) is int and uid > 0 and type(gid) is int and gid > 0, 'invalid_account', 'Use the managed non-root Bloom account.')
    account = pwd.getpwuid(uid)
    _require(account.pw_gid == gid and account.pw_dir == home and isinstance(home, str) and
             home.startswith('/') and '..' not in Path(home).parts and home != '/', 'invalid_account',
             'The maintenance account no longer matches the Bloom installation.')
    release = _protected('/etc/os-release').read_text()
    _require(re.search(r'^ID=["\']?ubuntu["\']?$', release, re.M), 'unsupported_system', 'Managed Docker updates support Ubuntu packages only.')
    for path in ('/usr/bin/apt-get', '/usr/bin/apt-cache', '/usr/bin/dpkg-query', '/usr/bin/dpkg',
                 '/usr/bin/python3', '/usr/bin/systemctl', '/usr/bin/docker', '/usr/bin/rootlesskit',
                 '/usr/share/docker.io/contrib/dockerd-rootless.sh'):
        _protected(path)
    for path in ('/etc/apt', '/var/lib/dpkg', '/var/lib/apt/lists', '/var/cache/apt'):
        _protected(path, directory=True)
    for path in Path('/etc/apt').rglob('*'):
        _protected(path, directory=path.is_dir())
    return account


# Only the service user reads its home. Malicious paths cannot redirect privileged reads, and
# no script or plugin beneath that home is ever executed as root.
USER_PROBE = r'''
import hashlib, json, os, pathlib, stat, sys
home = pathlib.Path(sys.argv[1])
def checked(path, kind):
    value = path.lstat()
    if value.st_uid != os.getuid() or value.st_mode & 0o022 or not kind(value.st_mode):
        raise RuntimeError("The managed Docker configuration has unsafe ownership or permissions.")
    return value
for path in (home, home / 'bloom', home / 'bloom/bin', home / 'bloom/docker', home / '.config', home / '.config/docker',
             home / '.config/systemd', home / '.config/systemd/user', pathlib.Path('/run/user') / str(os.getuid())):
    checked(path, stat.S_ISDIR)
files = [home / 'bloom/docker/.bloom-managed', home / '.config/docker/daemon.json', home / '.config/systemd/user/docker.service']
contents = []
for path in files:
    value = checked(path, stat.S_ISREG)
    if value.st_size > 65536: raise RuntimeError("The Docker configuration is too large.")
    contents.append(path.read_bytes())
if contents[0] != b'Bloom rootless Docker v1\n': raise RuntimeError("Docker was not set up by Bloom.")
if json.loads(contents[1]).get('data-root') != str(home / 'bloom/docker/data'): raise RuntimeError("Docker uses an unmanaged data directory.")
starts = [line.split('=', 1)[1].strip() for line in contents[2].decode().splitlines() if line.startswith('ExecStart=')]
if starts not in [[str(home / 'bloom/bin/dockerd-rootless.sh')], ['/usr/share/docker.io/contrib/dockerd-rootless.sh']]:
    raise RuntimeError("The Docker user service uses an unsupported executable.")
for name, target in {'docker': '/usr/bin/docker', 'rootlesskit': '/usr/bin/rootlesskit',
                     'dockerd-rootless.sh': '/usr/share/docker.io/contrib/dockerd-rootless.sh'}.items():
    path = home / 'bloom/bin' / name
    if not path.is_symlink() or os.readlink(path) != target: raise RuntimeError("The Docker tools were replaced outside Bloom setup.")
print(json.dumps({'fingerprint': hashlib.sha256(b'\0'.join(contents)).hexdigest()}))
'''


def _managed(account, runner):
    raw = _run(runner, ('/usr/bin/python3', '-I', '-c', USER_PROBE, account.pw_dir), account=account).stdout
    value = json.loads(raw)
    _require(re.fullmatch(r'[0-9a-f]{64}', value.get('fingerprint', '')), 'unmanaged_docker', 'The rootless Docker configuration could not be verified.')
    raw = _run(runner, ('/usr/bin/systemctl', '--user', 'show', 'docker.service', '--property=FragmentPath', '--property=DropInPaths', '--property=LoadState'), account=account).stdout
    properties = dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)
    _require(properties.get('LoadState') == 'loaded' and properties.get('FragmentPath') == account.pw_dir + '/.config/systemd/user/docker.service'
             and not properties.get('DropInPaths'), 'unmanaged_docker', 'Docker has an unmanaged service or service overrides.',
             'Review the Docker user service before using managed updates.')
    return value['fingerprint']


def _versions(runner):
    raw = _run(runner, ('/usr/bin/dpkg-query', '--show', '--showformat=${binary:Package}\t${db:Status-Status}\t${Version}\n', *PACKAGES)).stdout
    versions = {}
    for line in raw.splitlines():
        columns = line.split('\t')
        _require(len(columns) == 3, 'package_state', 'Docker package status is incomplete.')
        name, status_text, version = columns
        name = name.split(':')[0]
        _require(name in PACKAGES and name not in versions and status_text == 'installed' and VERSION.fullmatch(version),
                 'package_state', 'Docker has missing, unconfigured or unexpected packages.', 'Finish Docker setup and repair dpkg before updating.')
        versions[name] = version
    _require(set(versions) == set(PACKAGES), 'package_state', 'Some Bloom Docker packages are missing.')
    raw = _run(runner, ('/usr/bin/dpkg-query', '--search', '/usr/bin/docker', '/usr/bin/rootlesskit', '/usr/share/docker.io/contrib/dockerd-rootless.sh')).stdout
    owners = dict(line.rsplit(': ', 1)[::-1] for line in raw.splitlines() if ': ' in line)
    for path, package in {'/usr/bin/docker': 'docker.io', '/usr/bin/rootlesskit': 'rootlesskit',
                          '/usr/share/docker.io/contrib/dockerd-rootless.sh': 'docker.io'}.items():
        _require(owners.get(path, '').split(':')[0] == package, 'unmanaged_docker', 'Docker executables are not owned by the expected Ubuntu packages.')
    return versions


def _candidates(runner):
    raw = _run(runner, ('/usr/bin/apt-cache', 'policy', *PACKAGES)).stdout
    result, package = {}, None
    for line in raw.splitlines():
        if line and not line[0].isspace() and line.endswith(':'):
            package = line[:-1].split(':')[0]
        match = re.match(r'\s+Candidate:\s+(\S+)\s*$', line)
        if match and package in PACKAGES:
            _require(package not in result and VERSION.fullmatch(match[1]), 'candidate_unavailable', 'No usable APT candidate is available for ' + package + '.')
            result[package] = match[1]
    _require(set(result) == set(PACKAGES), 'candidate_unavailable', 'APT did not return every Docker package candidate.')
    return result


def _apt_arguments(updates, simulate=False):
    return ('/usr/bin/apt-get', *APT_OPTIONS, 'install', '--simulate' if simulate else '-y',
            '--only-upgrade', '--no-remove', '--no-install-recommends',
            *(package + '=' + updates[package] for package in PACKAGES if package in updates))


def _simulate(runner, updates):
    raw = _run(runner, _apt_arguments(updates, simulate=True), timeout=60).stdout
    installed = {}
    for line in raw.splitlines():
        _require(not line.startswith('Remv '), 'package_changes', 'APT would remove packages. This update was refused.')
        if line.startswith('Inst '):
            match = re.match(r'Inst (\S+) \[([^]]+)\] \((\S+)', line)
            _require(match is not None, 'package_changes', 'APT would install a new package or returned an unknown plan.')
            name = match[1].split(':')[0]
            _require(name in updates and updates[name] == match[3] and name not in installed,
                     'package_changes', 'APT requires package changes outside this reviewed Docker update.',
                     'Ask the administrator to review dependency changes, then prepare a new update in Bloom.')
            installed[name] = match[3]
    _require(installed == updates, 'package_changes', 'APT cannot perform exactly the reviewed Docker package changes.')


def prepare(config, *, runner=run_command):
    account = _validate_host(config)
    fingerprint = _managed(account, runner)
    versions, candidates = _versions(runner), _candidates(runner)
    updates = {package: candidate for package, candidate in candidates.items()
               if _run(runner, ('/usr/bin/dpkg', '--compare-versions', candidate, 'gt', versions[package]), allowed=(0, 1)).returncode == 0}
    _require(updates, 'up_to_date', 'Docker packages are already up to date in this server’s APT package lists.')
    _simulate(runner, updates)
    return dict(schema=1, account=dict(uid=account.pw_uid, gid=account.pw_gid, home=account.pw_dir),
                installed=versions, candidates=candidates, updates=updates, managedFingerprint=fingerprint,
                targetVersion=updates.get('docker.io', versions['docker.io']),
                summary='Upgrade only the reviewed Ubuntu Docker packages: ' + ', '.join(f'{name} {version}' for name, version in updates.items())
                    + '. Docker services and containers may restart. Container data is kept; automatic rollback is not available.',
                restarts=['Bloom rootless Docker', 'Docker containers and any package-managed Docker services'])


def inspect(config, *, runner=run_command):
    try:
        plan = prepare(config, runner=runner)
        return dict(id='docker', title='Docker', installedVersion=plan['installed']['docker.io'],
                    availableVersion=plan['targetVersion'], canUpdate=True, detail=plan['summary'])
    except DockerMaintenanceError as error:
        return dict(id='docker', title='Docker', installedVersion=None, availableVersion=None, canUpdate=False,
                    detail=str(error) + ' ' + error.recovery)


def apply(config, plan, log, *, runner=run_command):
    _require(isinstance(plan, dict) and plan.get('schema') == 1, 'invalid_plan', 'Review the Docker update again.')
    account = _validate_host(config)
    _require(plan.get('account') == dict(uid=account.pw_uid, gid=account.pw_gid, home=account.pw_dir),
             'stale_plan', 'The Bloom service account changed after this update was reviewed.')
    updates = plan.get('updates')
    _require(isinstance(updates, dict) and updates and set(updates).issubset(PACKAGES)
             and all(isinstance(value, str) and VERSION.fullmatch(value) for value in updates.values()),
             'invalid_plan', 'This plan contains unreviewed Docker packages or versions.')
    _require(_managed(account, runner) == plan.get('managedFingerprint'), 'stale_plan', 'Docker configuration changed. Review the update again.')
    _require(_versions(runner) == plan.get('installed') and _candidates(runner) == plan.get('candidates'),
             'stale_plan', 'Installed or available package versions changed. Review the update again.')
    for package, version in updates.items():
        _require(version == plan['candidates'].get(package)
                 and _run(runner, ('/usr/bin/dpkg', '--compare-versions', version, 'gt', plan['installed'][package]), allowed=(0, 1)).returncode == 0,
                 'invalid_plan', 'The reviewed update is not a pinned package upgrade.')
    _simulate(runner, updates)
    log('Installing the exact reviewed Docker package versions. Services and containers may restart.')
    _run(runner, _apt_arguments(updates), timeout=1800, log=log)
    expected = dict(plan['installed'], **updates)
    _require(_versions(runner) == expected, 'version_mismatch', 'Installed Docker packages do not match the reviewed versions.',
             'Inspect dpkg state and the update log. No automatic rollback was attempted.')
    _validate_host(config)
    _require(_managed(account, runner) == plan['managedFingerprint'], 'configuration_changed',
             'Docker configuration changed during the update. The service was not restarted.')
    log('Restarting and verifying Bloom’s private Docker service.')
    _run(runner, ('/usr/bin/systemctl', '--user', 'restart', 'docker.service'), account=account, timeout=180, log=log)
    endpoint = f'unix:///run/user/{account.pw_uid}/docker.sock'
    raw = _run(runner, ('/usr/bin/docker', '--host', endpoint, 'info', '--format', '{{json .}}'), account=account, timeout=60).stdout
    info = json.loads(raw)
    _require(info.get('DockerRootDir') == account.pw_dir + '/bloom/docker/data'
             and any(value == 'name=rootless' or value.startswith('name=rootless,') for value in info.get('SecurityOptions', [])),
             'verification_failed', 'Docker did not restart with its expected private rootless configuration.',
             'Review the Docker user service. Container data was not removed and no rollback was attempted.')
    log('Docker package versions and the private rootless daemon were verified.')
    return dict(version=expected['docker.io'], message='Docker was updated and its private rootless service is running. Container data was kept.')
