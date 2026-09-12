#!/usr/bin/env python3
"""Stable Bloom maintenance supervisor. Its root-owned configuration is the authority."""
import argparse
import contextlib
import hashlib
import hmac
import json
import os
import pathlib
import signal
import socket
import sqlite3
import stat
import subprocess
import sys
import threading
import time
import uuid

from bloom_install_process import InstallOutputRedactor, InstallProcessFailure, redact_install_text, stream_install_command
try:
    import bloom_maintenance_docker as DOCKER_ADAPTER
except ImportError:
    DOCKER_ADAPTER = None

MAX_FRAME = 65536
MAX_RUNTIME_FRAME = 16_777_216
TERMINAL_STATES = ('succeeded', 'failed', 'cancelled', 'rolledBack')


class MaintenanceError(Exception):
    def __init__(self, code, message, recovery=None):
        super().__init__(message)
        self.code = code
        self.recovery = recovery


def require(condition, code, message):
    if not condition:
        raise MaintenanceError(code, message)


def identifier(value):
    require(isinstance(value, str), 'invalid_request', 'A request identifier is required.')
    try:
        return str(uuid.UUID(value))
    except ValueError:
        raise MaintenanceError('invalid_request', 'The request identifier is invalid.') from None


def json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def trusted_path(path, owner=0, directory=False):
    path = pathlib.Path(path)
    require(path.is_absolute() and '..' not in path.parts, 'unsafe_path', 'A managed path is invalid.')
    for item in [path, *path.parents]:
        info = item.lstat()
        require(not stat.S_ISLNK(info.st_mode) and info.st_uid == owner and not info.st_mode & 0o022,
                'unsafe_path', 'A managed path is not protected from other accounts.')
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode),
            'unsafe_path', 'A managed path has an unexpected file type.')
    return path


def atomic_json(path, value):
    path = pathlib.Path(path)
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex)
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'wb') as output:
            output.write(json_bytes(value))
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


class JobStore:
    """SQLite commits acceptance and its intent together, before a worker can mutate anything."""
    def __init__(self, directory):
        self.path = pathlib.Path(directory) / 'maintenance.sqlite'
        self.lock = threading.RLock()
        require(not self.path.is_symlink(), 'unsafe_path', 'The maintenance database cannot be a symbolic link.')
        self.db = sqlite3.connect(self.path, check_same_thread=False, isolation_level=None)
        self.path.chmod(0o600)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS plans (id TEXT PRIMARY KEY, body TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, request_id TEXT UNIQUE NOT NULL,
                intent TEXT NOT NULL, state TEXT NOT NULL, body TEXT NOT NULL);
            CREATE UNIQUE INDEX IF NOT EXISTS one_active_job ON jobs ((1))
                WHERE state NOT IN ('succeeded','failed','cancelled','rolledBack');
            CREATE TABLE IF NOT EXISTS commands (id TEXT PRIMARY KEY, intent TEXT NOT NULL, job_id TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS logs (job_id TEXT NOT NULL, seq INTEGER NOT NULL,
                body TEXT NOT NULL, PRIMARY KEY(job_id,seq));
        ''')

    def close(self):
        self.db.close()

    def plan(self, value):
        with self.lock:
            self.db.execute('INSERT INTO plans VALUES (?,?)', (identifier(value['id']), json_bytes(value).decode()))
        return value

    def get_plan(self, plan_id):
        with self.lock:
            row = self.db.execute('SELECT body FROM plans WHERE id=?', (identifier(plan_id),)).fetchone()
        require(row is not None, 'plan_missing', 'Prepare and review the update again.')
        return json.loads(row[0])

    def accept(self, request_id, intent, job):
        request_id = identifier(request_id)
        digest = hashlib.sha256(json_bytes(intent)).hexdigest()
        with self.lock:
            self.db.execute('BEGIN IMMEDIATE')
            try:
                existing = self.db.execute('SELECT intent,body FROM jobs WHERE request_id=?', (request_id,)).fetchone()
                if existing:
                    require(hmac.compare_digest(existing[0], digest), 'request_reused',
                            'This request identifier was already used for a different update.')
                    self.db.execute('COMMIT')
                    return json.loads(existing[1]), False
                self.db.execute('INSERT INTO jobs VALUES (?,?,?,?,?)',
                                (identifier(job['id']), request_id, digest, job['phase'], json_bytes(job).decode()))
                self.db.execute('COMMIT')
                return job, True
            except sqlite3.IntegrityError:
                self.db.execute('ROLLBACK')
                raise MaintenanceError('maintenance_busy', 'Another maintenance job is still active.') from None
            except BaseException:
                self.db.execute('ROLLBACK')
                raise

    def get(self, job_id):
        with self.lock:
            row = self.db.execute('SELECT body FROM jobs WHERE id=?', (identifier(job_id),)).fetchone()
        require(row is not None, 'job_missing', 'This maintenance job was not found.')
        return json.loads(row[0])

    def active(self):
        with self.lock:
            row = self.db.execute("SELECT body FROM jobs WHERE state NOT IN ('succeeded','failed','cancelled','rolledBack')").fetchone()
        return json.loads(row[0]) if row else None

    def update(self, job):
        with self.lock:
            result = self.db.execute('UPDATE jobs SET state=?,body=? WHERE id=?',
                                     (job['phase'], json_bytes(job).decode(), identifier(job['id'])))
            require(result.rowcount == 1, 'job_missing', 'This maintenance job was not found.')

    def log(self, job_id, message):
        require(isinstance(message, str) and len(message.encode()) <= 4096,
                'invalid_log', 'The maintenance log entry is too large.')
        with self.lock:
            last = self.db.execute('SELECT COALESCE(MAX(seq),0) FROM logs WHERE job_id=?', (job_id,)).fetchone()[0]
            self.db.execute('INSERT INTO logs VALUES (?,?,?)', (job_id, last + 1, message))
            self.db.execute('DELETE FROM logs WHERE job_id=? AND seq<=?', (job_id, last - 249))
            while self.db.execute('SELECT COALESCE(SUM(length(CAST(body AS BLOB))),0) FROM logs WHERE job_id=?', (job_id,)).fetchone()[0] > 262144:
                self.db.execute('DELETE FROM logs WHERE job_id=? AND seq=(SELECT MIN(seq) FROM logs WHERE job_id=?)', (job_id, job_id))

    def logs(self, job_id):
        with self.lock:
            return [dict(sequence=seq, message=body) for seq, body in
                    self.db.execute('SELECT seq,body FROM logs WHERE job_id=? ORDER BY seq', (identifier(job_id),))]


class RuntimeProcess:
    def __init__(self, config, spawn=subprocess.Popen):
        self.config = config
        self.spawn = spawn
        self.child = None
        self.lock = threading.RLock()
        self.condition = threading.Condition(self.lock)
        self.channel = None
        self.responses = {}
        self.ready = False
        self.expected_trial = None
        self.generation = 0

    def start(self, executable=None, trial=None):
        with self.lock:
            require(self.child is None or self.child.poll() is not None, 'runtime_running', 'The runtime is already running.')
            executable = executable or self.config['executable']
            import pwd
            account = pwd.getpwuid(self.config['uid']).pw_name
            environment = {'HOME': self.config['service_home'],
                           'PATH': self.config['service_home'] + '/.local/bin:/usr/local/bin:/usr/bin:/bin',
                           'USER': account, 'LOGNAME': account, 'XDG_RUNTIME_DIR': '/run/user/' + str(self.config['uid']),
                           'LANG': 'C.UTF-8', 'BLOOM_MAINTENANCE_MANAGED': '1'}
            parent, inherited = socket.socketpair()
            environment['BLOOM_MAINTENANCE_FD'] = str(inherited.fileno())
            if self.config.get('gateway_group_id') is not None:
                environment['BLOOM_SERVER_GATEWAY_GID'] = str(self.config['gateway_group_id'])
            if trial:
                environment['BLOOM_MAINTENANCE_TRIAL'] = trial
            self.expected_trial = trial
            self.ready = False
            self.responses = {}
            self.generation += 1
            generation = self.generation
            try:
                self.child = self.spawn([executable, 'serve', '--data-dir', self.config['data_dir']],
                                    env=environment, cwd=self.config['service_home'], stdin=subprocess.DEVNULL,
                                    start_new_session=True, user=self.config['uid'], group=self.config['gid'],
                                        extra_groups=[], umask=0o077, pass_fds=(inherited.fileno(),))
            except BaseException:
                parent.close()
                raise
            finally:
                inherited.close()
            self.channel = parent
            threading.Thread(target=self._read_control, args=(parent, generation), daemon=True).start()
            return self.child

    def _read_control(self, channel, generation):
        try:
            with channel.makefile('rb') as source:
                while line := source.readline(MAX_FRAME + 1):
                    if len(line) > MAX_FRAME or not line.endswith(b'\n'):
                        return
                    value = json.loads(line)
                    with self.condition:
                        if generation != self.generation:
                            return
                        if value.get('event') == 'ready' and self.expected_trial is None:
                            self.ready = True
                        elif value.get('event') == 'prepared' and value.get('jobID') == self.expected_trial and self.expected_trial:
                            self.ready = True
                        elif isinstance(value.get('id'), str) and value['id'] in self.responses:
                            self.responses[value['id']] = value
                        self.condition.notify_all()
        except (OSError, ValueError):
            pass
        finally:
            with self.condition:
                self.condition.notify_all()

    def wait_ready(self, timeout=30):
        deadline = time.monotonic() + timeout
        with self.condition:
            while not self.ready and self.running() and time.monotonic() < deadline:
                self.condition.wait(min(.25, max(0, deadline - time.monotonic())))
            require(self.ready and self.running(), 'runtime_not_ready', 'Bloom Server did not become ready.')

    def control(self, action, timeout=5):
        require(action in ('quiesce', 'status', 'resume', 'commit'), 'invalid_action', 'Unknown runtime control action.')
        request_id = str(uuid.uuid4())
        with self.condition:
            require(self.running() and self.channel is not None, 'runtime_unavailable', 'Bloom Server is not running.')
            self.responses[request_id] = None
            try:
                self.channel.sendall(json_bytes(dict(id=request_id, action=action)) + b'\n')
                deadline = time.monotonic() + timeout
                while self.responses[request_id] is None and self.running() and time.monotonic() < deadline:
                    self.condition.wait(min(.25, max(0, deadline - time.monotonic())))
                response = self.responses[request_id]
                require(response is not None and type(response.get('ready')) is bool and type(response.get('busy')) is bool,
                        'runtime_unavailable', 'Bloom Server did not confirm the maintenance state.')
                if action == 'commit' and response['ready']:
                    self.expected_trial = None
                return response
            finally:
                self.responses.pop(request_id, None)

    def stop(self, timeout=15):
        with self.lock:
            child = self.child
            if child is None:
                return
            if child.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
            self.child = None
            self.ready = False
            if self.channel:
                self.channel.close()
                self.channel = None
            self.condition.notify_all()

    def running(self):
        with self.lock:
            return self.child is not None and self.child.poll() is None


def timestamp():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')


def require_version(value):
    import re
    require(isinstance(value, str) and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?', value),
            'invalid_version', 'The release version could not be verified.')
    return value


def newer_version(candidate, current):
    import re

    def parse(value):
        match = re.fullmatch(r'v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?', value or '')
        if not match:
            return None
        return tuple(int(part) for part in match.group(1, 2, 3)), match.group(4)

    left, right = parse(candidate), parse(current)
    if left is None or right is None:
        return False
    if left[0] != right[0]:
        return left[0] > right[0]
    if left[1] is None or right[1] is None:
        return left[1] is None and right[1] is not None
    for first, second in zip(left[1].split('.'), right[1].split('.')):
        if first == second:
            continue
        if first.isdigit() and second.isdigit():
            return int(first) > int(second)
        if first.isdigit() != second.isdigit():
            return not first.isdigit()
        return first > second
    return len(left[1].split('.')) > len(right[1].split('.'))


def account_owned(path, home):
    path, home = pathlib.Path(path), pathlib.Path(home)
    try:
        path.relative_to(home)
        for candidate in [path, *path.parents]:
            info = candidate.lstat()
            if stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
                return False
            if candidate == home:
                return True
    except (ValueError, OSError):
        pass
    return False


PACKAGES = {'claude': '@anthropic-ai/claude-code', 'codex': '@openai/codex'}


def tool_installation(component, home):
    import shutil
    home = pathlib.Path(home)
    launcher = home / '.local/bin' / component
    value = dict(installedVersion=None, method=None)
    if not launcher.exists():
        value['detail'] = 'Not installed. Install and sign in from Accounts first.'
        return value
    target = launcher.resolve(strict=True)
    require(account_owned(launcher.parent, home) and account_owned(target, home),
            'unmanaged_tool', 'This installation is not safely owned by the Bloom account.')
    package = home / '.local/lib/node_modules' / PACKAGES[component]
    if not target.is_relative_to(package):
        value['detail'] = 'This installer cannot pin this native or custom installation. Use its original installer.'
        return value
    metadata = package / 'package.json'
    require(account_owned(metadata, home), 'unmanaged_tool', 'The tool package metadata is not safely owned.')
    descriptor = os.open(metadata, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_size <= 65536, 'unmanaged_tool', 'The tool package metadata is invalid.')
        data = source.read(65537)
    require(len(data) <= 65536, 'unmanaged_tool', 'The tool package metadata is too large.')
    try:
        metadata_value = json.loads(data)
    except (ValueError, RecursionError):
        raise MaintenanceError('unmanaged_tool', 'The tool package metadata is invalid. Repair the installation before updating.') from None
    require(isinstance(metadata_value, dict) and metadata_value.get('name') == PACKAGES[component],
            'unmanaged_tool', 'The tool package identity could not be verified.')
    version = require_version(metadata_value.get('version'))
    npm = shutil.which('npm', path='/usr/local/bin:/usr/bin:/bin')
    value.update(installedVersion=version, method='npm' if npm else None,
                 detail='Managed npm installation.' if npm else 'The system npm installation is unavailable.')
    return value


def refuse_external_agents(home, proc=pathlib.Path('/proc')):
    require(proc.is_dir(), 'process_inspection_unavailable', 'Linux process inspection is required before updating tools.')
    for entry in proc.iterdir():
        if not entry.name.isdigit() or int(entry.name) == os.getpid():
            continue
        try:
            if entry.stat().st_uid != os.getuid():
                continue
            args = (entry / 'cmdline').read_bytes().split(b'\0')
            candidates = []
            for index, value in enumerate(args[:3]):
                previous = args[index - 1] if index else b''
                if value.startswith(b'-') or previous in (b'-c', b'-lc', b'-e', b'--eval', b'-p', b'--print'):
                    continue
                candidates.append(pathlib.PurePosixPath(value.decode('utf-8', 'replace')))
            known = any(path.name in ('claude', 'codex', 'claude.js', 'codex.js') for path in candidates)
            package = any(any(path.parts[index:index + 3] in (('node_modules', '@anthropic-ai', 'claude-code'),
                              ('node_modules', '@openai', 'codex')) for index in range(len(path.parts) - 2)) for path in candidates)
            native = (entry / 'exe').resolve().is_relative_to(home / '.local/share/claude/versions')
            require(not (known or package or native), 'agent_running',
                    'An agent is still running outside Bloom. Close its terminal or process before updating.')
        except (FileNotFoundError, ProcessLookupError):
            continue
        except PermissionError:
            raise MaintenanceError('process_inspection_unavailable', 'Running agents could not be checked safely.') from None


def tool_worker(action, component, version, from_version=None):
    import pwd
    require(os.getuid() != 0 and component in PACKAGES, 'unsafe_account', 'Tools must run as the Bloom account.')
    home = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)
    value = tool_installation(component, home)
    if action == 'inspect':
        print(json.dumps(value), flush=True)
        return
    require(action == 'install' and value['method'] == 'npm', 'unmanaged_tool', 'This tool cannot be updated by this installer.')
    version = require_version(version)
    from_version = require_version(from_version)
    require(newer_version(version, from_version), 'invalid_plan', 'The reviewed tool target is not newer than its installed version.')
    # A second OS lock also excludes legacy maintenance processes using this account.
    import fcntl
    import shutil
    descriptor = os.open(home / '.local/.bloom-tool-update.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077,
                'unsafe_lock', 'The tool update lock is not private.')
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise MaintenanceError('maintenance_busy', 'Another tool updater is running.') from None
        current = tool_installation(component, home)
        require(current.get('method') == 'npm' and current.get('installedVersion') == from_version,
                'installation_changed', 'The tool installation changed after review. Prepare a new update before installing.')
        refuse_external_agents(home)
        npm = shutil.which('npm', path='/usr/local/bin:/usr/bin:/bin')
        require(npm is not None, 'npm_missing', 'npm is unavailable.')
        environment = {'HOME': str(home), 'PATH': str(home / '.local/bin') + ':/usr/local/bin:/usr/bin:/bin',
                       'LANG': 'C.UTF-8', 'CI': '1', 'NO_COLOR': '1',
                       'NPM_CONFIG_USERCONFIG': '/dev/null', 'NPM_CONFIG_GLOBALCONFIG': '/dev/null'}
        def output(line):
            print(json.dumps(dict(event='output', message=line)), flush=True)
        try:
            result = stream_install_command([npm, 'install', '--global', '--prefix', str(home / '.local'),
                '--registry=https://registry.npmjs.org', '--no-audit', '--no-fund',
                '--allow-scripts=' + PACKAGES[component], PACKAGES[component] + '@' + version],
                env=environment, cwd=home, timeout=360, output=output, capture_limit=0, detail_limit=8192, event_limit=500)
        except InstallProcessFailure as error:
            raise MaintenanceError(error.code, 'npm maintenance could not finish.\n' + error.details,
                                   'The installed version may be partially updated. Review this output and inspect the tool before retrying.') from None
        require(result.returncode == 0, 'tool_update_failed', 'npm exited with status ' + str(result.returncode) + '.\n' + result.details)
        latest = tool_installation(component, home)
        require(latest['installedVersion'] == version, 'verification_failed', 'The installed tool does not match the reviewed version.')
        check = subprocess.run([str(home / '.local/bin' / component), '--version'], env=environment,
                               cwd=home, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        require(check.returncode == 0, 'verification_failed', 'The updated tool did not pass its version check.')
    finally:
        os.close(descriptor)


def database_worker(action, directory):
    """Run only after dropping privilege. No root file operation follows a service-owned path."""
    import tarfile
    require(os.getuid() != 0, 'unsafe_account', 'Database maintenance must run as the Bloom account.')
    directory = pathlib.Path(directory)
    names = ('server.sqlite', 'server.sqlite-wal', 'server.sqlite-shm')
    require(directory.is_absolute(), 'unsafe_path', 'The database directory is invalid.')
    if action == 'snapshot':
        with tarfile.open(fileobj=os.fdopen(os.dup(1), 'wb'), mode='w|') as archive:
            for name in names:
                try:
                    descriptor = os.open(directory / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                except FileNotFoundError:
                    require(name != 'server.sqlite', 'snapshot_failed', 'The main server database is missing. No update was installed.')
                    continue
                with os.fdopen(descriptor, 'rb') as source:
                    info = os.fstat(source.fileno())
                    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_size <= 2 * 1024**3,
                            'snapshot_failed', 'The database has unsafe ownership, type or size.')
                    member = tarfile.TarInfo(name)
                    member.size, member.mode = info.st_size, 0o600
                    archive.addfile(member, source)
    elif action == 'restore':
        staged = {}
        try:
            with tarfile.open(fileobj=os.fdopen(os.dup(0), 'rb'), mode='r|') as archive:
                for member in archive:
                    require(member.name in names and member.name not in staged and member.isfile() and member.size <= 2 * 1024**3,
                            'snapshot_failed', 'The database snapshot is invalid.')
                    temporary = directory / ('.maintenance-' + uuid.uuid4().hex)
                    staged[member.name] = temporary
                    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                    with os.fdopen(descriptor, 'wb') as output, archive.extractfile(member) as source:
                        import shutil
                        shutil.copyfileobj(source, output)
                        output.flush()
                        os.fsync(output.fileno())
            require('server.sqlite' in staged, 'snapshot_failed', 'The snapshot does not contain the main server database.')
            # Restore every member before restarting any runtime. Crash recovery repeats this
            # complete restore from the immutable snapshot before allowing the old child to start.
            for name in names:
                if name in staged:
                    os.replace(staged[name], directory / name)
                else:
                    (directory / name).unlink(missing_ok=True)
            descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        finally:
            for temporary in staged.values():
                temporary.unlink(missing_ok=True)
    else:
        raise MaintenanceError('invalid_action', 'Unknown database maintenance action.')


def load_config(path):
    import re
    path = trusted_path(path)
    require(path.stat().st_mode & 0o077 == 0, 'unsafe_config', 'The supervisor configuration must be private.')
    data = path.read_bytes()
    require(len(data) <= MAX_FRAME, 'unsafe_config', 'The supervisor configuration is too large.')
    config = json.loads(data)
    require(isinstance(config, dict), 'unsafe_config', 'The supervisor configuration is invalid.')
    for key in ('uid', 'gid'):
        require(type(config.get(key)) is int and config[key] > 0, 'unsafe_config', 'A non-root service account is required.')
    if 'gateway_group_id' in config:
        require(type(config['gateway_group_id']) is int and config['gateway_group_id'] > 0,
                'unsafe_config', 'The gateway group identifier is invalid.')
    for key in ('state_dir', 'install_root'):
        trusted_path(config[key], directory=True)
    trusted_path(config['executable'])
    require(pathlib.Path(config['executable']).is_relative_to(config['install_root']),
            'unsafe_config', 'The server executable must belong to the protected release directory.')
    for key in ('service_home', 'data_dir', 'runtime_socket', 'maintenance_socket'):
        require(isinstance(config.get(key), str) and pathlib.Path(config[key]).is_absolute() and '\x00' not in config[key],
                'unsafe_config', 'An installation path is invalid.')
    require(re.fullmatch(r'[0-9a-f]{64}', config.get('access_token_sha256', '')) is not None,
            'unsafe_config', 'An administrator credential digest is required.')
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', config.get('release_repository', '')) is not None,
            'unsafe_config', 'A fixed GitHub release repository is required.')
    trusted_path(pathlib.Path(config['maintenance_socket']).parent, directory=True)
    fingerprint = 2166136261
    for byte in (config['data_dir'] + '/server.sqlite').encode():
        fingerprint = ((fingerprint ^ byte) * 16777619) & 0xffffffff
    require(config['maintenance_socket'] == f'/run/bloom-maintenance/{fingerprint:08x}.sock',
            'unsafe_config', 'The maintenance socket does not match this server installation.')
    return config


def fetch_json(url, maximum=1024 * 1024):
    import urllib.request
    with https_open(url, accept='application/vnd.github+json' if 'api.github.com' in url else 'application/json') as response:
        data = response.read(maximum + 1)
    require(len(data) <= maximum, 'release_unavailable', 'The release metadata is too large.')
    return json.loads(data)


def https_open(url, accept='application/octet-stream'):
    import urllib.parse
    import urllib.request
    allowed = ('api.github.com', 'github.com', 'release-assets.githubusercontent.com', 'registry.npmjs.org')

    def validate(value):
        parsed = urllib.parse.urlparse(value)
        require(parsed.scheme == 'https' and parsed.hostname in allowed and parsed.port in (None, 443)
                and parsed.username is None and parsed.password is None,
                'release_unavailable', 'The release download destination is not trusted.')

    class Redirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, response, code, message, headers, destination):
            validate(destination)
            return super().redirect_request(request, response, code, message, headers, destination)

    validate(url)
    opener = urllib.request.build_opener(Redirect())
    request = urllib.request.Request(url, headers={'Accept': accept, 'User-Agent': 'Bloom-Maintenance'})
    return opener.open(request, timeout=15)


def release_asset(config):
    import re
    value = fetch_json('https://api.github.com/repos/' + config['release_repository'] + '/releases/latest')
    require(isinstance(value, dict) and not value.get('draft') and not value.get('prerelease'),
            'release_unavailable', 'A stable server release is not available.')
    assets = [asset for asset in value.get('assets', []) if asset.get('name') == 'bloom-server-linux-x86_64.tar.gz']
    require(len(assets) == 1, 'release_unavailable', 'The stable release does not include a Linux server package.')
    asset = assets[0]
    digest = asset.get('digest', '')
    require(re.fullmatch(r'sha256:[0-9a-f]{64}', digest) is not None and type(asset.get('id')) is int and asset['id'] > 0,
            'release_unavailable', 'GitHub did not publish a verified digest for this server package.')
    version = value.get('tag_name')
    require(isinstance(version, str) and len(version) <= 100 and re.fullmatch(r'[A-Za-z0-9._-]+', version),
            'release_unavailable', 'The release version is invalid.')
    return dict(version=version, assetID=asset['id'], sha256=digest[7:])


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def extract_release(archive_path, destination, protocol_version=14, expected_version=None):
    import tarfile
    import shutil
    prefix = 'bloom-server-linux-x86_64'
    total, names = 0, set()
    with tarfile.open(archive_path, mode='r:gz') as archive:
        members = []
        for member in archive:
            name = pathlib.PurePosixPath(member.name)
            require(not name.is_absolute() and '..' not in name.parts and name.parts and name.parts[0] == prefix
                    and len(member.name) <= 512 and (member.isfile() or member.isdir()) and name not in names,
                    'unsafe_release', 'The server package contains an unsafe archive entry.')
            require(len(members) < 20000 and member.size >= 0, 'unsafe_release', 'The server package contains too many entries.')
            total += member.size
            require(total <= 1024**3, 'unsafe_release', 'The extracted server package is too large.')
            names.add(name)
            members.append(member)
        for member in sorted(members, key=lambda item: (not item.isdir(), item.name)):
            target = pathlib.Path(destination).joinpath(*pathlib.PurePosixPath(member.name).parts)
            if member.isdir():
                target.mkdir(mode=0o755, parents=True, exist_ok=True)
                target.chmod(0o755)
            else:
                target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                with archive.extractfile(member) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
                    output.flush()
                    os.fsync(output.fileno())
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
    bundle = pathlib.Path(destination) / prefix
    executable = validate_release_manifest(bundle, protocol_version, expected_version)
    directories = [bundle, *(item for item in bundle.rglob('*') if item.is_dir())]
    for directory in sorted(directories, key=lambda item: len(item.parts), reverse=True):
        directory.chmod(0o755)
        fsync_directory(directory)
    return executable


def validate_release_manifest(bundle, protocol_version=14, expected_version=None):
    bundle = pathlib.Path(bundle)
    manifest_path = bundle / 'manifest.json'
    require(manifest_path.is_file() and manifest_path.stat().st_size <= MAX_FRAME,
            'unsafe_release', 'The package manifest is missing or too large.')
    manifest = json.loads(manifest_path.read_bytes())
    executable = bundle / 'bin/bloom-server'
    require(isinstance(manifest, dict) and manifest.get('protocolVersion') == protocol_version
            and manifest.get('maintenanceProtocolVersion') == 1
            and manifest.get('architecture') == 'x86_64' and executable.is_file()
            and executable.stat().st_mode & 0o111 and (bundle / 'lib').is_dir(),
            'incompatible_release', 'The server package is incompatible with this supervisor and protocol.')
    if expected_version is not None:
        require(isinstance(manifest.get('version'), str)
                and manifest['version'].removeprefix('v') == expected_version.removeprefix('v'),
                'release_version_mismatch', 'The server package version does not match the reviewed release.')
    return executable


class Supervisor:
    def __init__(self, config, store=None, runtime=None, docker=DOCKER_ADAPTER):
        self.config = config
        self.state = pathlib.Path(config['state_dir'])
        self.store = store or JobStore(self.state)
        self.runtime = runtime or RuntimeProcess(config)
        self.docker = docker
        self.log_redactors = {}
        self.lock = threading.RLock()
        self.cancelled = threading.Event()
        self.stopping = threading.Event()
        self.worker = None
        self.marker = self.state / 'transaction.json'
        self.current_file = self.state / 'current.json'
        self.current = dict(executable=config['executable'], version=config.get('executable_version', 'Installed build'))
        if self.current_file.exists():
            self.current = json.loads(self.current_file.read_bytes())
        self.components_cache = None
        self.cache_time = 0
        self.recovering = False
        self.recovery_failed = False
        self.recovery_thread = None

    def authenticated(self, credential):
        value = credential if isinstance(credential, str) and len(credential) <= 4096 else ''
        digest = hashlib.sha256(value.encode()).hexdigest()
        return bool(value) and hmac.compare_digest(digest, self.config['access_token_sha256'])

    def account_command(self, arguments, timeout=40, stdin=None, stdout=subprocess.PIPE, log=None):
        import sys
        environment = {'HOME': self.config['service_home'], 'PATH': '/usr/local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8'}
        child = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).resolve()), *arguments],
                                 user=self.config['uid'], group=self.config['gid'], extra_groups=[], umask=0o077,
                                 env=environment, cwd=self.config['service_home'], stdin=stdin or subprocess.DEVNULL,
                                 stdout=stdout, stderr=subprocess.STDOUT if stdout == subprocess.PIPE else subprocess.PIPE, start_new_session=True)
        try:
            output = bytearray()
            pending_output = bytearray()
            redactor = InstallOutputRedactor()
            deadline = time.monotonic() + timeout
            stream = child.stdout if stdout == subprocess.PIPE else child.stderr
            if stream is not None:
                import selectors
                with selectors.DefaultSelector() as selector:
                    os.set_blocking(stream.fileno(), False)
                    selector.register(stream, selectors.EVENT_READ)
                    while selector.get_map():
                        require(time.monotonic() < deadline, 'worker_timeout', 'The account maintenance step timed out. Inspect its outcome before retrying.')
                        for key, _ in selector.select(.2):
                            chunk = os.read(key.fd, 4096)
                            if not chunk:
                                selector.unregister(key.fileobj)
                            else:
                                if log is None:
                                    output.extend(chunk)
                                    require(len(output) <= MAX_FRAME, 'worker_failed', 'The account maintenance response is too large.')
                                else:
                                    pending_output.extend(chunk)
                                    while b'\n' in pending_output:
                                        line, _, rest = pending_output.partition(b'\n')
                                        pending_output = bytearray(rest)
                                        require(len(line) <= MAX_FRAME, 'worker_failed', 'A maintenance output event is too large.')
                                        event = json.loads(line)
                                        if event.get('event') == 'output' and isinstance(event.get('message'), str):
                                            log(redactor.redact(event['message']))
                                        else:
                                            output = bytearray(line)
                                    require(len(pending_output) <= MAX_FRAME, 'worker_failed', 'A maintenance output event is too large.')
            child.wait(timeout=max(.01, deadline - time.monotonic()))
            if log is not None and pending_output:
                output = pending_output
            if child.returncode != 0:
                try:
                    value = json.loads(output)
                    message = value.get('error')
                except (ValueError, AttributeError):
                    value = None
                    message = None
                # Worker errors are emitted only by the protected script, with fixed text.
                if isinstance(message, str):
                    message = redact_install_text(message, limit=16384)
                    if log:
                        for line in message.splitlines():
                            log(line)
                code = value.get('code') if isinstance(value, dict) else None
                recovery = value.get('recovery') if isinstance(value, dict) else None
                raise MaintenanceError(code if isinstance(code, str) and len(code) <= 100 else 'worker_failed',
                    message if isinstance(message, str) else 'The account maintenance step failed. Inspect the server before retrying.',
                    redact_install_text(recovery) if isinstance(recovery, str) else None)
            return bytes(output) if stdout == subprocess.PIPE else None
        finally:
            if child.poll() is None:
                # The shared streaming runner owns a separate installer process group.
                # Give its signal handler time to unwind and reap that group first.
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(child.pid, signal.SIGTERM)
                with contextlib.suppress(subprocess.TimeoutExpired):
                    child.wait(timeout=3)
            with contextlib.suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=5)
            if child.stdout:
                child.stdout.close()
            if child.stderr:
                child.stderr.close()

    def components(self, refresh=False):
        if not refresh and self.components_cache is not None and time.monotonic() - self.cache_time < 900:
            return self.components_cache
        values = []
        server = dict(id='server', title='Bloom Server', installedVersion=self.current.get('version'),
                      availableVersion=None, canUpdate=False, detail='Checking stable server releases.')
        try:
            asset = release_asset(self.config)
            server.update(availableVersion=asset['version'], canUpdate=newer_version(asset['version'], self.current.get('version')),
                          detail='Updates use the stable GitHub release and its published SHA-256 digest.')
        except (MaintenanceError, OSError, ValueError):
            server['detail'] = 'A verified stable server package is not available. Try refreshing later.'
        values.append(server)
        for component, package in PACKAGES.items():
            value = dict(id=component, title='Claude Code' if component == 'claude' else 'Codex',
                         installedVersion=None, availableVersion=None, canUpdate=False, detail='Installation could not be inspected.')
            try:
                installation = json.loads(self.account_command(['--tool-worker', 'inspect', component]))
                value.update(installedVersion=installation.get('installedVersion'), detail=installation['detail'])
                if installation.get('method') == 'npm':
                    latest = require_version(fetch_json('https://registry.npmjs.org/' + package + '/latest').get('version'))
                    value.update(availableVersion=latest, canUpdate=newer_version(latest, installation.get('installedVersion')),
                                 detail='The exact reviewed npm version is installed under the Bloom account.')
            except (MaintenanceError, OSError, ValueError):
                pass
            values.append(value)
        if self.docker:
            values.append(self.docker.inspect(self.config))
        else:
            values.append(dict(id='docker', title='Docker', installedVersion=None, availableVersion=None, canUpdate=False,
                               detail='The Docker maintenance component is unavailable. Update the supervisor installation first.'))
        self.components_cache, self.cache_time = values, time.monotonic()
        return values

    def prepare(self, component):
        if component == 'docker':
            return self.prepare_docker()
        require(component in ('server', 'claude', 'codex'), 'unsupported', 'This component does not support reviewed updates.')
        values = self.components(refresh=True)
        value = next(item for item in values if item['id'] == component)
        require(value['canUpdate'], 'update_unavailable', value['detail'])
        import datetime
        expires = time.time() + 1800
        plan = dict(id=str(uuid.uuid4()), component=component, fromVersion=value['installedVersion'],
                    targetVersion=value['availableVersion'], summary='Install the reviewed version. Bloom Server restarts; project containers keep running.',
                    restarts=['Bloom Server'], expiresAt=datetime.datetime.fromtimestamp(expires, datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
                    _expires=expires)
        if component == 'server':
            asset = release_asset(self.config)
            require(asset['version'] == plan['targetVersion'], 'release_changed', 'The stable release changed. Review it again.')
            plan['_asset'] = asset
            plan['summary'] = 'Install this exact server release. Bloom snapshots its database and restores the previous release if startup verification fails.'
        self.store.plan(plan)
        return {key: value for key, value in plan.items() if not key.startswith('_')}

    def docker_call(self, action, *arguments):
        require(self.docker is not None, 'unsupported', 'The Docker maintenance component is unavailable.')
        try:
            return getattr(self.docker, action)(self.config, *arguments)
        except self.docker.DockerMaintenanceError as error:
            raise MaintenanceError(error.code, redact_install_text(str(error)), redact_install_text(error.recovery)) from None

    def prepare_docker(self):
        import datetime
        payload = self.docker_call('prepare')
        expires = time.time() + 1800
        plan = dict(id=str(uuid.uuid4()), component='docker', fromVersion=payload['installed']['docker.io'],
                    targetVersion=payload['targetVersion'], summary=payload['summary'],
                    restarts=list(dict.fromkeys(['Bloom Server', *payload['restarts']])),
                    expiresAt=datetime.datetime.fromtimestamp(expires, datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
                    _expires=expires, _docker=payload)
        self.store.plan(plan)
        return {key: value for key, value in plan.items() if not key.startswith('_')}

    def job_log(self, job_id, message):
        with self.lock:
            redactor = self.log_redactors.setdefault(job_id, InstallOutputRedactor())
            for line in message.splitlines():
                safe = redactor.redact(line).encode()[:4096].decode('utf-8', 'ignore').strip()
                if safe:
                    self.store.log(job_id, safe)

    def job_view(self, job, after=0):
        result = dict(job)
        logs = self.store.logs(job['id'])
        result['logs'] = [value for value in logs if value['sequence'] > after]
        result['nextSequence'] = logs[-1]['sequence'] if logs else 0
        return result

    def jobs(self, job_id=None, after=0):
        if job_id:
            return [self.job_view(self.store.get(job_id), after)]
        with self.store.lock:
            rows = self.store.db.execute('SELECT body FROM jobs ORDER BY rowid DESC LIMIT 10').fetchall()
        return [self.job_view(json.loads(row[0])) for row in rows]

    def start_job(self, request_id, plan_id, mode):
        require(mode in ('now', 'whenIdle'), 'invalid_request', 'Choose when the update should run.')
        intent = dict(planID=identifier(plan_id), mode=mode)
        with self.lock, self.store.lock:
            require(self.store.db.execute('SELECT 1 FROM commands WHERE id=?', (identifier(request_id),)).fetchone() is None,
                    'request_reused', 'This request identifier belongs to another maintenance action.')
            existing = self.store.db.execute('SELECT intent,body FROM jobs WHERE request_id=?', (identifier(request_id),)).fetchone()
            if existing:
                require(hmac.compare_digest(existing[0], hashlib.sha256(json_bytes(intent)).hexdigest()),
                        'request_reused', 'This request identifier belongs to a different update.')
                return self.job_view(json.loads(existing[1]))
            require(not self.recovering and not self.recovery_failed, 'runtime_recovering', 'Wait for server recovery before starting another update.')
            require(self.worker is None or not self.worker.is_alive(), 'maintenance_busy', 'The previous maintenance job is finishing its cleanup.')
            plan = self.store.get_plan(plan_id)
            require(plan['_expires'] >= time.time(), 'plan_expired', 'This update review expired. Prepare and review it again.')
            job = dict(id=str(uuid.uuid4()), planID=plan_id, component=plan['component'], targetVersion=plan['targetVersion'],
                       phase='queued', logs=[], nextSequence=0, canCancel=True, message='Update accepted.', updatedAt=timestamp())
            accepted, fresh = self.store.accept(request_id, intent, job)
            if fresh:
                self.cancelled.clear()
                self.worker = threading.Thread(target=self.run_job, args=(accepted, plan, mode), daemon=True)
                self.worker.start()
            return self.job_view(accepted)

    def recover_job(self, request_id, job_id):
        request_id, job_id = identifier(request_id), identifier(job_id)
        intent = hashlib.sha256(json_bytes(dict(action='recover', jobID=job_id))).hexdigest()
        with self.lock, self.store.lock:
            previous = self.store.db.execute('SELECT intent,job_id FROM commands WHERE id=?', (request_id,)).fetchone()
            if previous:
                require(hmac.compare_digest(previous[0], intent), 'request_reused', 'This request identifier belongs to a different recovery.')
                return self.job_view(self.store.get(previous[1]))
            require(self.store.db.execute('SELECT 1 FROM jobs WHERE request_id=?', (request_id,)).fetchone() is None,
                    'request_reused', 'This request identifier belongs to another maintenance action.')
            require(not self.recovering and (self.worker is None or not self.worker.is_alive()),
                    'maintenance_busy', 'Maintenance is still finishing. Wait before requesting recovery.')
            job = self.store.get(job_id)
            require(job['phase'] == 'interrupted', 'recovery_unavailable', 'Only an interrupted maintenance job needs recovery.')
            job.update(phase='restarting', canCancel=False, message='Recovering Bloom Server without repeating the component installation.', updatedAt=timestamp())
            self.store.db.execute('BEGIN IMMEDIATE')
            try:
                self.store.db.execute('INSERT INTO commands VALUES (?,?,?)', (request_id, intent, job_id))
                self.store.update(job)
                self.store.db.execute('COMMIT')
            except BaseException:
                self.store.db.execute('ROLLBACK')
                raise
            self.worker = threading.Thread(target=self.run_recovery, args=(job,), daemon=True)
            self.worker.start()
            return self.job_view(job)

    def run_recovery(self, job):
        try:
            self.phase(job, 'restarting', 'Recovering the existing maintenance checkpoint. No package installer will run again.')
            if self.marker.exists():
                transaction = json.loads(self.marker.read_bytes())
                require(transaction.get('jobID') == job['id'], 'transaction_changed', 'The saved recovery checkpoint belongs to another job.')
                if transaction['stage'] != 'committed':
                    # Candidates and rollback trials have never admitted workspace work.
                    require(not self.runtime.running() or self.runtime.expected_trial == job['id'],
                            'runtime_busy', 'The live runtime is not this job’s paused candidate. Inspect it before recovery.')
                    self.rollback(job, transaction)
                else:
                    self.current = transaction['new']
                    atomic_json(self.current_file, self.current)
                    if self.runtime.running():
                        response = self.runtime.control('commit')
                        require(response['ready'], 'commit_unconfirmed', 'The committed runtime did not confirm activation.')
                    else:
                        self.runtime.start(self.current['executable'])
                        self.runtime.wait_ready()
                    restored = transaction.get('outcome') == 'rolledBack'
                    self.phase(job, 'rolledBack' if restored else 'succeeded',
                               'The restored server is running.' if restored else 'The committed update is running and verified.')
                    self.clear_marker(job['id'])
            else:
                if self.runtime.running():
                    response = self.runtime.control('resume')
                    require(response['ready'], 'runtime_unavailable', 'The live runtime did not confirm that workspace admission resumed.')
                else:
                    self.runtime.start(self.current['executable'])
                    self.runtime.wait_ready()
                self.phase(job, 'failed', 'Bloom Server is running again. The component update outcome remains unconfirmed. Inspect its installed version; no installer or container rollback was repeated.')
            self.recovery_failed = False
            self.components_cache = None
        except Exception as error:
            self.job_log(job['id'], str(error) if isinstance(error, MaintenanceError) else 'The recovery checkpoint could not be completed.')
            self.phase(job, 'interrupted', 'Recovery could not be confirmed. The saved checkpoint is retained. Inspect the supervisor service before trying again.')

    def phase(self, job, phase, message, cancellable=False):
        with self.lock:
            summary = redact_install_text(message, limit=4096)
            job.update(phase=phase, message=summary, canCancel=cancellable, updatedAt=timestamp())
            self.store.update(job)
            self.job_log(job['id'], message)

    def check_cancelled(self):
        require(not self.cancelled.is_set() and not self.stopping.is_set(), 'cancelled', 'Maintenance was cancelled before installation started.')

    def cancel(self, job_id):
        with self.lock:
            job = self.store.get(job_id)
            require(job['canCancel'] and job['phase'] not in TERMINAL_STATES, 'cannot_cancel', 'Installation has started and cannot be cancelled safely.')
            self.cancelled.set()
            return self.job_view(job)

    def handle(self, request_id, request):
        if not isinstance(request, dict) or not self.authenticated(request.get('credential')):
            return dict(authorized=False, components=[], jobs=[], error=dict(code='unauthorized', message='Administrator access is required.',
                        recovery='Enter the maintenance credential created during server setup.'))
        try:
            allowed = {'action', 'credential', 'component', 'planID', 'jobID', 'mode', 'afterSequence'}
            require(set(request).issubset(allowed), 'invalid_request', 'The maintenance request contains unsupported fields.')
            for key in ('action', 'credential', 'component', 'planID', 'jobID', 'mode'):
                require(key not in request or request[key] is None or isinstance(request[key], str),
                        'invalid_request', 'A maintenance request field has an invalid type.')
            if request.get('component') is not None:
                require(request['component'] in ('server', 'claude', 'codex', 'docker'), 'invalid_request', 'Unknown maintenance component.')
            if request.get('mode') is not None:
                require(request['mode'] in ('now', 'whenIdle'), 'invalid_request', 'Unknown maintenance scheduling mode.')
            if request.get('afterSequence') is not None:
                require(type(request['afterSequence']) is int and 0 <= request['afterSequence'] <= 2**53,
                        'invalid_request', 'The log cursor is invalid.')
            action = request.get('action')
            result = dict(authorized=True, components=[], jobs=[])
            if action == 'inspect':
                result.update(components=self.components(), jobs=self.jobs())
            elif action == 'prepare':
                result['plan'] = self.prepare(request.get('component'))
            elif action == 'start':
                result['jobs'] = [self.start_job(request_id, request.get('planID'), request.get('mode') or 'now')]
            elif action == 'status':
                after = request.get('afterSequence') or 0
                require(type(after) is int and 0 <= after <= 2**53, 'invalid_request', 'The log cursor is invalid.')
                result['jobs'] = self.jobs(request.get('jobID'), after)
            elif action == 'cancel':
                result['jobs'] = [self.cancel(request.get('jobID'))]
            elif action == 'recover':
                result['jobs'] = [self.recover_job(request_id, request.get('jobID'))]
            else:
                raise MaintenanceError('invalid_request', 'Unknown maintenance action.')
            return result
        except MaintenanceError as error:
            return dict(authorized=True, components=[], jobs=[], error=dict(code=error.code, message=str(error),
                        recovery=error.recovery or 'Refresh the maintenance status before preparing another update.'))
        except (OSError, ValueError, KeyError, TypeError, sqlite3.Error):
            return dict(authorized=True, components=[], jobs=[], error=dict(code='maintenance_failed',
                        message='The maintenance request could not be completed.', recovery='Refresh status and check the protected supervisor service logs.'))

    def download(self, job, plan):
        import shutil
        asset = plan['_asset']
        destination = pathlib.Path(self.config['install_root']) / asset['sha256']
        if destination.exists():
            trusted_path(destination, directory=True)
            executable = destination / 'bin/bloom-server'
            trusted_path(executable)
            trusted_path(destination / 'manifest.json')
            validate_release_manifest(destination, self.config.get('protocol_version', 14), plan['targetVersion'])
            return str(executable)
        staging = pathlib.Path(self.config['install_root']) / ('.staging-' + job['id'])
        staging.mkdir(mode=0o700)
        archive = staging / 'download.tar.gz'
        try:
            digest, total = hashlib.sha256(), 0
            url = 'https://api.github.com/repos/' + self.config['release_repository'] + '/releases/assets/' + str(asset['assetID'])
            with https_open(url) as response, archive.open('xb') as output:
                while chunk := response.read(1024 * 1024):
                    self.check_cancelled()
                    total += len(chunk)
                    require(total <= 512 * 1024**2, 'release_too_large', 'The server package exceeds the download limit.')
                    digest.update(chunk)
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
            require(hmac.compare_digest(digest.hexdigest(), asset['sha256']), 'checksum_mismatch', 'The server package does not match the reviewed SHA-256 digest.')
            executable = extract_release(archive, staging, self.config.get('protocol_version', 14), plan['targetVersion'])
            os.replace(executable.parent.parent, destination)
            fsync_directory(destination.parent)
            return str(destination / 'bin/bloom-server')
        finally:
            shutil.rmtree(staging)

    def database_snapshot(self, job_id):
        target = self.state / ('snapshot-' + identifier(job_id) + '.tar')
        try:
            with target.open('xb') as output:
                self.account_command(['--database-worker', 'snapshot', self.config['data_dir']], timeout=180, stdout=output)
                output.flush()
                os.fsync(output.fileno())
            target.chmod(0o600)
            return str(target)
        except BaseException:
            # A failed copy must not consume the remaining disk and prevent the unchanged
            # old runtime from reopening its database. No transaction points to this file yet.
            target.unlink(missing_ok=True)
            fsync_directory(self.state)
            raise

    def database_restore(self, snapshot):
        path = pathlib.Path(snapshot)
        require(path.parent == self.state and path.name.startswith('snapshot-') and path.suffix == '.tar',
                'invalid_snapshot', 'The rollback snapshot is outside the protected state directory.')
        trusted_path(path)
        with path.open('rb') as source:
            self.account_command(['--database-worker', 'restore', self.config['data_dir']], timeout=180, stdin=source)

    def clear_marker(self, expected_job_id):
        if self.marker.exists():
            transaction = json.loads(self.marker.read_bytes())
            require(transaction.get('jobID') == identifier(expected_job_id), 'transaction_changed', 'The maintenance transaction changed during cleanup.')
            snapshot = self.state / ('snapshot-' + identifier(transaction['jobID']) + '.tar')
        else:
            snapshot = None
        self.marker.unlink(missing_ok=True)
        descriptor = os.open(self.state, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        if snapshot:
            snapshot.unlink(missing_ok=True)
            fsync_directory(self.state)

    def rollback(self, job, transaction):
        self.runtime.stop()
        if transaction.get('snapshot'):
            self.database_restore(transaction['snapshot'])
        else:
            (self.state / ('snapshot-' + identifier(job['id']) + '.tar')).unlink(missing_ok=True)
        self.current = transaction['old']
        atomic_json(self.current_file, self.current)
        self.runtime.start(self.current['executable'], trial=job['id'])
        self.runtime.wait_ready()
        # The restored runtime can also accept new work. Commit the rollback decision
        # durably before opening its admission gate, or a crash could erase that work.
        transaction.update(stage='committed', new=dict(self.current), outcome='rolledBack')
        atomic_json(self.marker, transaction)
        response = self.runtime.control('commit')
        require(response['ready'], 'commit_unconfirmed', 'The restored runtime did not confirm activation.')
        self.phase(job, 'rolledBack', 'The new server failed verification. The previous release and database were restored.')
        self.clear_marker(job['id'])

    def recover(self):
        """Resolve the durable commit point before starting any child against the database."""
        with self.lock:
            active = self.store.active()
            if self.marker.exists():
                transaction = json.loads(self.marker.read_bytes())
                job = self.store.get(transaction['jobID'])
                if transaction['stage'] == 'committed':
                    self.current = transaction['new']
                    atomic_json(self.current_file, self.current)
                    self.runtime.start(self.current['executable'])
                    self.runtime.wait_ready()
                    restored = transaction.get('outcome') == 'rolledBack'
                    self.phase(job, 'rolledBack' if restored else 'succeeded',
                               'The restored server resumed safely.' if restored else 'The committed server update resumed after maintenance restarted.')
                    self.clear_marker(job['id'])
                else:
                    self.rollback(job, transaction)
                return
            uncertain_component = active and active['component'] != 'server' and active['phase'] in ('installing', 'restarting', 'verifying', 'interrupted')
            if active:
                self.phase(active, 'restarting', 'Restarting Bloom Server before resolving the interrupted maintenance job.')
            try:
                self.runtime.start(self.current['executable'])
                self.runtime.wait_ready()
            except Exception:
                if active:
                    self.phase(active, 'interrupted', 'Bloom Server could not restart after maintenance. Choose Recover to retry runtime recovery without repeating any installer.')
                raise
            if active:
                if uncertain_component:
                    self.phase(active, 'failed', 'Maintenance was interrupted. The installed component version is unconfirmed; inspect it before retrying.')
                else:
                    self.phase(active, 'cancelled', 'Maintenance stopped before a server release was committed. Prepare and review another update.')

    def run_job(self, job, plan, mode):
        transaction = None
        committed = False
        runtime_stopped = False
        gated = False
        try:
            self.check_cancelled()
            if plan['component'] == 'server':
                self.phase(job, 'downloading', 'Downloading and verifying the exact reviewed server package.', True)
                executable = self.download(job, plan)
                require(self.current.get('version') == plan.get('fromVersion'), 'installation_changed', 'The installed server changed since review. Prepare another update.')
            elif plan['component'] == 'docker':
                require(isinstance(plan.get('_docker'), dict), 'invalid_plan', 'Review the Docker package update again.')
            else:
                value = json.loads(self.account_command(['--tool-worker', 'inspect', plan['component']]))
                require(value.get('method') == 'npm' and value.get('installedVersion') == plan.get('fromVersion'),
                        'installation_changed', 'The tool installation changed since review. Prepare another update.')
            self.check_cancelled()
            # The gate may close even when its acknowledgement is lost. Record that
            # intent before sending, so every failure path reopens or exposes recovery.
            gated = True
            response = self.runtime.control('quiesce')
            if response['busy'] and mode == 'now':
                raise MaintenanceError('server_busy', 'Work is still running. Close terminal connections and choose When Idle or try again later.')
            self.phase(job, 'waiting', 'Waiting for running work to finish. Close terminal connections to continue.', True)
            while response['busy']:
                self.check_cancelled()
                self.cancelled.wait(.5)
                response = self.runtime.control('status')
            with self.lock:
                self.check_cancelled()
                self.phase(job, 'installing', 'Preparing the reviewed update. Installation can no longer be cancelled.')
            if plan['component'] == 'server':
                transaction = dict(jobID=job['id'], stage='snapshot_pending', old=dict(self.current),
                                   new=dict(executable=executable, version=plan['targetVersion']))
                atomic_json(self.marker, transaction)
            self.runtime.stop()
            runtime_stopped = True
            if plan['component'] == 'server':
                transaction['snapshot'] = self.database_snapshot(job['id'])
                transaction['stage'] = 'trial'
                atomic_json(self.marker, transaction)
                self.phase(job, 'restarting', 'Starting the new server with workspace actions paused.')
                self.runtime.start(executable, trial=job['id'])
                self.phase(job, 'verifying', 'Verifying the new server before allowing workspace actions.')
                self.runtime.wait_ready()
                # This is the irreversible point: once commit is sent, queued work may write
                # the migrated database. Recovery must never restore the old snapshot afterward.
                transaction['stage'] = 'committed'
                atomic_json(self.marker, transaction)
                committed = True
                self.current = transaction['new']
                atomic_json(self.current_file, self.current)
                response = self.runtime.control('commit')
                require(response['ready'], 'commit_unconfirmed', 'The updated runtime did not confirm activation.')
                self.phase(job, 'succeeded', 'Bloom Server was updated and verified.')
                self.clear_marker(job['id'])
            else:
                if plan['component'] == 'docker':
                    self.phase(job, 'installing', 'Installing the reviewed Docker package versions. Docker services and containers may restart.')
                    outcome = self.docker_call('apply', plan['_docker'], lambda message: self.job_log(job['id'], message))
                    complete = outcome['message']
                else:
                    self.phase(job, 'installing', 'Installing ' + plan['component'] + ' ' + plan['targetVersion'] + ' as the Bloom account.')
                    self.account_command(['--tool-worker', 'install', plan['component'], plan['targetVersion'], plan['fromVersion']], timeout=400,
                                         log=lambda message: self.job_log(job['id'], message))
                    complete = 'The reviewed tool version was installed and verified.'
                self.phase(job, 'restarting', 'Restarting Bloom Server after the component update.')
                self.runtime.start(self.current['executable'])
                self.runtime.wait_ready()
                self.phase(job, 'succeeded', complete)
            self.components_cache = None
        except Exception as error:
            if transaction is not None and not committed:
                try:
                    self.rollback(job, transaction)
                except Exception:
                    self.phase(job, 'interrupted', 'Rollback could not finish. The database snapshot is retained; the supervisor must recover before more updates.')
                return
            if committed:
                # Commit is idempotent. A reply can be lost after work was admitted, so
                # retry the acknowledgement without stopping new work or restoring old data.
                try:
                    response = self.runtime.control('commit')
                    require(response['ready'], 'commit_unconfirmed', 'Activation could not be confirmed.')
                    self.phase(job, 'succeeded', 'The updated server confirmed activation after retrying.')
                    self.clear_marker(job['id'])
                except Exception:
                    # Leave the committed marker for restart recovery. Never roll back accepted work.
                    self.phase(job, 'interrupted', 'The release was committed but activation is unconfirmed. Restarting the supervisor resumes this release safely.')
                return
            if plan['component'] == 'docker':
                self.job_log(job['id'], str(error) if isinstance(error, MaintenanceError) else 'Docker maintenance stopped unexpectedly.')
                if isinstance(error, MaintenanceError) and error.recovery:
                    self.job_log(job['id'], error.recovery)
            if runtime_stopped:
                try:
                    self.runtime.start(self.current['executable'])
                    self.runtime.wait_ready()
                except Exception:
                    self.phase(job, 'interrupted', 'The tool update outcome is unconfirmed and Bloom Server could not restart. Inspect the server before retrying.')
                    return
            elif gated:
                try:
                    response = self.runtime.control('resume')
                    require(response['ready'], 'resume_unconfirmed', 'The runtime did not confirm reopening workspace admission.')
                except Exception:
                    self.job_log(job['id'], str(error) if isinstance(error, MaintenanceError) else 'The update stopped before installation.')
                    self.phase(job, 'interrupted', 'The update stopped, but workspace admission could not be confirmed. Choose Recover to resume the existing runtime safely.')
                    return
            cancelled = isinstance(error, MaintenanceError) and error.code == 'cancelled'
            message = str(error) if isinstance(error, MaintenanceError) else 'Maintenance failed. The installed version may be unchanged or partially updated; inspect it before retrying.'
            if plan['component'] == 'docker' and runtime_stopped:
                message = 'The Docker update could not be verified. Package changes may be partial; no container or package rollback was attempted. Review the job log.'
            self.phase(job, 'cancelled' if cancelled else 'failed', message)
            self.components_cache = None

    def close(self):
        self.stopping.set()
        self.cancelled.set()
        worker = self.worker
        if worker:
            worker.join(timeout=20)
        if self.recovery_thread:
            self.recovery_thread.join(timeout=20)
        self.runtime.stop()


class ControlServer:
    def __init__(self, supervisor):
        self.supervisor = supervisor
        self.config = supervisor.config
        self.socket = None
        self.connections = threading.BoundedSemaphore(32)
        self.runtime_workers = threading.BoundedSemaphore(8)
        self.inspection_workers = threading.BoundedSemaphore(2)
        self.clients = set()
        self.clients_lock = threading.Lock()
        self.frame_timeout = 30
        self.idle_timeout = 45
        self.runtime_timeout = 660

    def fallback(self, request, operation):
        import platform
        import pwd
        if operation == 'hello':
            result = dict(hello=dict(name=socket.gethostname()))
        elif operation == 'diagnostics':
            result = dict(diagnostics={'_0': dict(checkedAt=time.time() - 978307200, hostname=socket.gethostname(),
                          operatingSystem=platform.system(), account=pwd.getpwuid(self.config['uid']).pw_name,
                          checks=[], maintenanceManagement=True, storageManagement=True)})
        else:
            result = dict(failure={'_0': 'Bloom Server is restarting for maintenance. Reconnect after the update finishes.'})
        return dict(version=request['version'], id=request['id'], result=result)

    def runtime_connection(self):
        info = os.lstat(self.config['runtime_socket'])
        group_allowed = self.config.get('gateway_group_id')
        private = not info.st_mode & 0o077
        gateway = group_allowed is not None and info.st_gid == group_allowed and not info.st_mode & 0o007
        require(stat.S_ISSOCK(info.st_mode) and info.st_uid == self.config['uid'] and (private or gateway),
                'runtime_unavailable', 'The private runtime socket is unavailable.')
        connection = socket.socket(socket.AF_UNIX)
        try:
            connection.settimeout(self.runtime_timeout)
            connection.connect(self.config['runtime_socket'])
            return connection
        except BaseException:
            connection.close()
            raise

    def forward(self, request, raw):
        operation = next(iter(request['operation']))
        if not self.supervisor.runtime.running() or self.supervisor.runtime.expected_trial is not None:
            return json_bytes(self.fallback(request, operation)) + b'\n'
        try:
            runtime = self.runtime_connection()
        except (MaintenanceError, OSError):
            return json_bytes(self.fallback(request, operation)) + b'\n'
        with runtime, runtime.makefile('rb') as reader:
            runtime.sendall(raw)
            result = reader.readline(MAX_RUNTIME_FRAME + 1)
            require(result.endswith(b'\n') and len(result) <= MAX_RUNTIME_FRAME,
                    'runtime_unavailable', 'Bloom Server did not return a complete reply.')
            return result

    def serve_client(self, connection):
        with self.clients_lock:
            self.clients.add(connection)
        writes = threading.Lock()
        pending = threading.Condition()
        inflight = set()
        failed = threading.Event()
        buffered = bytearray()
        last_read = time.monotonic()
        frame_started = None

        def receive():
            import select
            nonlocal last_read, frame_started
            while not failed.is_set() and not self.supervisor.stopping.is_set():
                boundary = buffered.find(b'\n')
                if boundary >= 0:
                    value = bytes(buffered[:boundary + 1])
                    del buffered[:boundary + 1]
                    frame_started = time.monotonic() if buffered else None
                    return value
                require(len(buffered) <= MAX_RUNTIME_FRAME, 'invalid_request', 'The request frame is too large.')
                remaining = self.frame_timeout - (time.monotonic() - frame_started) if frame_started is not None else .5
                require(remaining > 0, 'frame_timeout', 'The request frame did not arrive in time.')
                readable, _, _ = select.select([connection], [], [], min(.5, remaining))
                if not readable:
                    with pending:
                        if not inflight and time.monotonic() - last_read >= self.idle_timeout:
                            return None
                    continue
                chunk = connection.recv(min(65536, MAX_RUNTIME_FRAME + 1 - len(buffered)))
                if not chunk:
                    return None
                last_read = time.monotonic()
                if frame_started is None:
                    frame_started = last_read
                buffered.extend(chunk)
            return None

        def send(reply):
            data = reply if isinstance(reply, bytes) else json_bytes(reply) + b'\n'
            with writes:
                connection.sendall(data)

        def abort():
            failed.set()
            with contextlib.suppress(OSError):
                connection.shutdown(socket.SHUT_RDWR)

        def maintenance_reply(request, payload):
            value = self.supervisor.handle(request['id'], payload)
            return dict(version=request['version'], id=request['id'], result=dict(maintenance={'_0': value}))

        def dispatch(request, raw, payload=None, maintenance=False):
            slots = self.inspection_workers if maintenance else self.runtime_workers
            if not slots.acquire(blocking=False):
                if maintenance:
                    authorized = self.supervisor.authenticated(payload.get('credential') if isinstance(payload, dict) else None)
                    value = dict(authorized=authorized, components=[], jobs=[], error=dict(
                        code='maintenance_busy' if authorized else 'unauthorized',
                        message='Another inspection is running. Try again shortly.' if authorized else 'Administrator access is required.',
                        recovery='Retry this request.'))
                    send(dict(version=request['version'], id=request['id'], result=dict(maintenance={'_0': value})))
                else:
                    send(dict(version=request['version'], id=request['id'], result=dict(failure={
                        '_0': 'Bloom Server is handling several requests. Retry shortly.'})))
                return
            token = object()
            with pending:
                inflight.add(token)

            def work():
                try:
                    reply = maintenance_reply(request, payload) if maintenance else self.forward(request, raw)
                    send(reply)
                except (MaintenanceError, OSError, ValueError):
                    # An upstream mutation may already have committed. Preserve uncertainty
                    # by closing this transport instead of inventing a definite rejection.
                    abort()
                finally:
                    slots.release()
                    with pending:
                        inflight.discard(token)
                        pending.notify_all()
            threading.Thread(target=work, daemon=True).start()

        try:
            connection.settimeout(45)
            with connection:
                while not self.supervisor.stopping.is_set() and not failed.is_set():
                    raw = receive()
                    if not raw:
                        break
                    if len(raw) > MAX_RUNTIME_FRAME or not raw.endswith(b'\n'):
                        abort()
                        break
                    try:
                        request = json.loads(raw)
                        require(isinstance(request, dict), 'invalid_request', 'Invalid request frame.')
                        request['id'] = identifier(request.get('id'))
                        require(request.get('version') == self.config.get('protocol_version', 14), 'unsupported_protocol', 'Unsupported protocol version.')
                        operation = request.get('operation')
                        require(isinstance(operation, dict) and len(operation) == 1, 'invalid_request', 'Invalid operation frame.')
                        if 'maintenance' in operation:
                            require(len(raw) <= MAX_FRAME, 'invalid_request', 'The maintenance request is too large.')
                            envelope = operation['maintenance']
                            payload = envelope.get('_0') if isinstance(envelope, dict) else None
                            if isinstance(payload, dict) and payload.get('action') in ('inspect', 'prepare'):
                                dispatch(request, raw, payload, maintenance=True)
                            else:
                                # Job status and cancellation never queue behind normal RPC or
                                # network/package inspection. Accepted work lives in the store.
                                send(maintenance_reply(request, payload))
                        else:
                            dispatch(request, raw)
                    except (ValueError, MaintenanceError, TypeError):
                        abort()
                        break
                # A client may half-close its write side after submitting the last frame.
                # Finish replies before closing ours, but never keep a disconnected reader.
                with pending:
                    while inflight and not failed.is_set() and not self.supervisor.stopping.is_set():
                        pending.wait(.5)
        except (OSError, ValueError, MaintenanceError):
            abort()
        finally:
            with self.clients_lock:
                self.clients.discard(connection)
            self.connections.release()

    def run(self):
        import fcntl
        lock = os.open(pathlib.Path(self.config['state_dir']) / 'supervisor.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            path = pathlib.Path(self.config['maintenance_socket'])
            if path.exists():
                info = path.lstat()
                require(stat.S_ISSOCK(info.st_mode) and info.st_uid == 0, 'unsafe_socket', 'The maintenance socket has unexpected ownership.')
                path.unlink()
            self.socket = socket.socket(socket.AF_UNIX)
            self.socket.bind(str(path))
            os.chown(path, 0, self.config['gid'])
            path.chmod(0o660)
            self.socket.listen(32)
            self.socket.settimeout(.5)
            # Recovery can copy a database or wait for startup. Keep authenticated job
            # status available throughout, on this stable listener rather than the child.
            def recover():
                try:
                    self.supervisor.recover()
                except Exception:
                    self.supervisor.recovery_failed = True
                    print('Bloom runtime recovery requires administrator attention.', flush=True)
                finally:
                    self.supervisor.recovering = False
            self.supervisor.recovering = True
            self.supervisor.recovery_thread = threading.Thread(target=recover, daemon=True)
            self.supervisor.recovery_thread.start()
            retry_at, retry_delay = 0, 1
            while not self.supervisor.stopping.is_set():
                try:
                    connection, _ = self.socket.accept()
                except socket.timeout:
                    if (not self.supervisor.recovering and not self.supervisor.recovery_failed
                            and self.supervisor.store.active() is None and not self.supervisor.runtime.running()
                            and time.monotonic() >= retry_at):
                        retry_at = time.monotonic() + retry_delay
                        retry_delay = min(30, retry_delay * 2)
                        with contextlib.suppress(Exception):
                            self.supervisor.runtime.start(self.supervisor.current['executable'])
                    elif self.supervisor.runtime.ready:
                        retry_delay = 1
                    continue
                if not self.connections.acquire(blocking=False):
                    connection.close()
                    continue
                threading.Thread(target=self.serve_client, args=(connection,), daemon=True).start()
        finally:
            self.supervisor.close()
            if self.socket:
                self.socket.close()
            with self.clients_lock:
                for client in self.clients:
                    with contextlib.suppress(OSError):
                        client.shutdown(socket.SHUT_RDWR)
            os.close(lock)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config')
    parser.add_argument('--tool-worker', nargs='+')
    parser.add_argument('--database-worker', nargs=2)
    args = parser.parse_args()
    os.umask(0o077)
    if args.tool_worker:
        require((len(args.tool_worker) == 2 and args.tool_worker[0] == 'inspect')
                or (len(args.tool_worker) == 4 and args.tool_worker[0] == 'install'), 'invalid_action', 'Invalid tool worker request.')
        tool_worker(args.tool_worker[0], args.tool_worker[1], args.tool_worker[2] if len(args.tool_worker) == 4 else None,
                    args.tool_worker[3] if len(args.tool_worker) == 4 else None)
    elif args.database_worker:
        database_worker(*args.database_worker)
    else:
        import sys
        require(sys.platform == 'linux', 'unsupported_platform', 'The maintenance supervisor requires Linux.')
        require(os.getuid() == 0 and args.config, 'unsafe_account', 'The maintenance supervisor requires its protected administrator configuration.')
        config = load_config(args.config)
        supervisor = Supervisor(config)
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, lambda *_: supervisor.stopping.set())
        ControlServer(supervisor).run()


if __name__ == '__main__':
    try:
        main()
    except (MaintenanceError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        # Only our own fixed messages may reach logs. Never print request/config/token values.
        message = str(error) if isinstance(error, MaintenanceError) else 'Bloom maintenance could not finish. Inspect the supervisor configuration and service.'
        print(json.dumps(dict(error=redact_install_text(message), code=error.code if isinstance(error, MaintenanceError) else 'worker_failed',
                              recovery=error.recovery if isinstance(error, MaintenanceError) else None)),
              file=sys.stderr if '--database-worker' in sys.argv else sys.stdout, flush=True)
        raise SystemExit(1) from None
