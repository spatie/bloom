#!/usr/bin/env python3
"""Root-only disposable Linux integration: real runtime, update commit and database rollback.

Run in an isolated container, never on a deployed server. Only release metadata/downloads are
replaced with local fixtures. No package manager, GitHub request or system service is invoked.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import pwd
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import uuid


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def wait_for(predicate, message, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.1)
    raise RuntimeError(message)


def fingerprint(value):
    result = 2166136261
    for byte in value.encode():
        result = ((result ^ byte) * 16777619) & 0xffffffff
    return f'{result:08x}'


def rpc(path, operation, request_id=None):
    request_id = request_id or str(uuid.uuid4())
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(45)
        connection.connect(str(path))
        connection.sendall(json.dumps(dict(version=14, id=request_id, operation=operation)).encode() + b'\n')
        with connection.makefile('rb') as source:
            raw = source.readline(1048577)
    require(raw.endswith(b'\n') and len(raw) <= 1048576, 'Incomplete RPC response')
    reply = json.loads(raw)
    require(uuid.UUID(reply['id']) == uuid.UUID(request_id), 'RPC identity changed')
    return reply['result']


def account_database(account, home, database, query):
    script = 'import sqlite3,sys; db=sqlite3.connect(sys.argv[1]); result=db.executescript(sys.argv[2]) if sys.argv[2].startswith("CREATE") else db.execute(sys.argv[2]); print(result.fetchall()); db.commit(); db.close()'
    result = subprocess.run([sys.executable, '-c', script, str(database), query], check=True,
        capture_output=True, text=True, user=account.pw_uid, group=account.pw_gid, extra_groups=[],
        cwd=home, env={'HOME': str(home), 'PATH': '/usr/bin:/bin'}, umask=0o077)
    return result.stdout.strip()


def bundle(source, destination, version, broken=False):
    shutil.copytree(source, destination, symlinks=False)
    for path in [destination, *destination.rglob('*')]:
        path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)
    (destination / 'manifest.json').write_text(json.dumps(dict(
        architecture='x86_64', protocolVersion=14, maintenanceProtocolVersion=1, version=version)))
    if broken:
        executable = destination / 'bin/bloom-server'
        executable.rename(destination / 'bin/bloom-server-real')
        executable.write_text('''#!/usr/bin/python3
import os, pathlib, sqlite3, sys
# Change the real database before starting a real runtime with the wrong trial identity.
# Rollback must undo this write, not merely restart the previous executable.
data = pathlib.Path(sys.argv[sys.argv.index('--data-dir') + 1]) / 'server.sqlite'
with sqlite3.connect(data) as db:
    db.execute("UPDATE smoke_marker SET value='candidate-write'")
os.environ['BLOOM_MAINTENANCE_TRIAL'] = '00000000-0000-0000-0000-000000000001'
os.execv(str(pathlib.Path(__file__).with_name('bloom-server-real')), sys.argv)
''')
        executable.chmod(0o755)


def verify(binary, account):
    require(sys.platform == 'linux' and os.getuid() == 0, 'Run only as root inside a disposable Linux container')
    require(account.pw_uid > 0 and account.pw_gid > 0, 'The runtime account must not be root')
    source = binary.parent.parent
    require(binary.name == 'bloom-server' and (source / 'lib').is_dir(), 'Pass bin/bloom-server from an extracted Linux package')
    socket_parent = pathlib.Path('/run/bloom-maintenance')
    created_socket_parent = not socket_parent.exists()
    socket_parent.mkdir(mode=0o755, exist_ok=True)
    supervisor = control = thread = None
    sockets = []
    with tempfile.TemporaryDirectory(prefix='bloom-maintenance-smoke-', dir='/var/lib') as temporary:
        root = pathlib.Path(temporary)
        root.chmod(0o755)
        try:
            code, state, releases, home = [root / name for name in ('code', 'state', 'releases', 'home')]
            for path in (code, state, releases, home):
                path.mkdir(mode=0o755)
            data = home / 'bloom/data'
            data.mkdir(parents=True)
            for path in [home, *home.rglob('*')]:
                os.chown(path, account.pw_uid, account.pw_gid)
                path.chmod(0o700)
            for name in ('bloom-maintenance.py', 'bloom_install_process.py', 'bloom_maintenance_docker.py'):
                shutil.copyfile(pathlib.Path(__file__).with_name(name), code / name)
                (code / name).chmod(0o644)
            sys.path.insert(0, str(code))
            spec = importlib.util.spec_from_file_location('bloom_maintenance_smoke_production', code / 'bloom-maintenance.py')
            maintenance = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(maintenance)
            original = releases / 'original'
            bundle(source, original, 'v0.0.1')
            stamp = fingerprint(str(data / 'server.sqlite'))
            sockets = [socket_parent / (stamp + '.sock'), pathlib.Path('/tmp/bloom-bridge-' + stamp + '.sock')]
            token = uuid.uuid4().hex
            config = dict(uid=account.pw_uid, gid=account.pw_gid, service_home=str(home), data_dir=str(data),
                state_dir=str(state), install_root=str(releases), executable=str(original / 'bin/bloom-server'),
                executable_version='v0.0.1', protocol_version=14, runtime_socket=str(sockets[1]),
                maintenance_socket=str(sockets[0]), release_repository='spatie/bloom',
                access_token_sha256=hashlib.sha256(token.encode()).hexdigest())
            config_path = state / 'config.json'
            config_path.write_text(json.dumps(config)); config_path.chmod(0o600)
            supervisor = maintenance.Supervisor(maintenance.load_config(config_path), docker=None)
            control = maintenance.ControlServer(supervisor)
            thread = threading.Thread(target=control.run, daemon=True)
            thread.start()
            wait_for(lambda: supervisor.runtime.ready and not supervisor.recovering, 'Initial runtime did not become ready')
            require(not supervisor.recovery_failed, 'Initial supervisor recovery failed')
            baseline = rpc(sockets[0], {'catalogue': {}})
            require('catalogue' in baseline, 'Initial catalogue unavailable')
            status = pathlib.Path('/proc') / str(supervisor.runtime.child.pid) / 'status'
            require(f'Uid:\t{account.pw_uid}\t' in status.read_text(), 'Runtime did not drop UID')
            account_database(account, home, data / 'server.sqlite', "CREATE TABLE smoke_marker(value TEXT); INSERT INTO smoke_marker VALUES('preserved');")

            def request(action, request_id=None, credential=token, **fields):
                payload = dict(action=action, credential=credential, **fields)
                return rpc(sockets[0], {'maintenance': {'_0': payload}}, request_id)['maintenance']['_0']

            denied = request('start', credential='wrong', planID='untrusted', mode='now')
            require(not denied['authorized'] and denied['error']['code'] == 'unauthorized', 'Unauthorised maintenance accepted')
            require(supervisor.store.active() is None, 'Unauthorised request created a job')
            for version, broken, expected in (('v0.0.2', False, 'succeeded'), ('v0.0.3', True, 'rolledBack')):
                staged = root / ('candidate-' + version)
                bundle(source, staged, version, broken)
                archive = root / (version + '.tar.gz')
                with tarfile.open(archive, 'w:gz', compresslevel=1) as output:
                    output.add(staged, arcname='bloom-server-linux-x86_64')
                with archive.open('rb') as source_file:
                    checksum = hashlib.file_digest(source_file, 'sha256').hexdigest()
                # These are the only replaced production operations: acquisition metadata and bytes.
                maintenance.release_asset = lambda _: dict(version=version, assetID=1, sha256=checksum)
                maintenance.https_open = lambda *args, **kwargs: archive.open('rb')
                prepared = request('prepare', component='server')
                require(prepared.get('error') is None and prepared.get('plan'), f'Could not prepare fixture: {prepared}')
                request_id = str(uuid.uuid4())
                accepted = request('start', request_id, planID=prepared['plan']['id'], mode='now')
                require(accepted.get('error') is None and accepted['jobs'], f'Update was not accepted: {accepted}')
                job_id = accepted['jobs'][0]['id']
                replay = request('start', request_id, planID=prepared['plan']['id'], mode='now')
                require(replay['jobs'][0]['id'] == job_id, 'Idempotent replay created another job')
                wait_for(lambda: supervisor.worker is not None and not supervisor.worker.is_alive(), 'Update worker timed out', timeout=120)
                job = request('status', jobID=job_id)['jobs'][0]
                require(job['phase'] == expected, f'Expected {expected}, got {job}')
                require(rpc(sockets[0], {'catalogue': {}}) == baseline, 'Catalogue changed or became unreadable')
                require(account_database(account, home, data / 'server.sqlite', 'SELECT value FROM smoke_marker') == "[('preserved',)]", 'Database snapshot was not preserved/restored')
                require(supervisor.current['version'] == 'v0.0.2', 'Committed release pointer is incorrect')
                require(not supervisor.marker.exists(), 'Finished transaction checkpoint remained')
                print(f'Packaged supervisor {version}: {expected}, same-ID replay and database verified.', flush=True)
                shutil.rmtree(staged); archive.unlink()
        finally:
            if supervisor:
                supervisor.stopping.set()
            if thread:
                thread.join(timeout=30)
                require(not thread.is_alive(), 'Supervisor did not stop during cleanup')
            if supervisor:
                supervisor.store.close()
            for path in sockets:
                path.unlink(missing_ok=True)
            if created_socket_parent:
                socket_parent.rmdir()
    print('Real runtime/control/snapshot integration passed; network acquisition was fixture-backed. No package installers were tested.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=pathlib.Path)
    parser.add_argument('--user', default='nobody')
    parser.add_argument('--disposable-container', action='store_true', help='Acknowledge this container may be discarded after the run')
    arguments = parser.parse_args()
    require(arguments.disposable_container, 'Pass --disposable-container only in an isolated CI container')
    verify(arguments.binary.resolve(), pwd.getpwnam(arguments.user))
