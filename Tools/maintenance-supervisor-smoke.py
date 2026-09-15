#!/usr/bin/env python3
"""Root-only disposable Linux integration: real runtime, release acquisition, commit and rollback.

Run in an isolated container, never on a deployed server. GitHub is a local HTTPS server that
answers for api.github.com and its asset storage host, reached through /etc/hosts and a throwaway
certificate authority. Nothing in the supervisor is replaced: its release lookup, release
description check, redirect validation, digest verification and download all run as they would
against GitHub. No package manager, real GitHub request or system service is invoked.
"""
import argparse
import contextlib
import hashlib
import http.server
import importlib.util
import json
import os
import pathlib
import pwd
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import uuid

PACKAGE = 'bloom-server-linux-x86_64.tar.gz'
DESCRIPTION = 'bloom-server-linux-x86_64.json'
# The asset host is where GitHub redirects a download. npm is routed here too, so a tool check
# fails at once against the fake rather than waiting on the network or reaching the registry.
HOSTS = ('api.github.com', 'github.com', 'release-assets.githubusercontent.com', 'registry.npmjs.org')
TERMINAL = ('succeeded', 'failed', 'cancelled', 'rolledBack', 'interrupted')
# The wire protocol of the package under test, read from its manifest in verify. A literal here
# kept this smoke on 14 after the package moved to 15.
WIRE = None


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


def envelope(operation, request_id):
    return json.dumps(dict(version=WIRE, id=request_id, operation=operation)).encode() + b'\n'


def rpc(path, operation, request_id=None):
    request_id = request_id or str(uuid.uuid4())
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(45)
        connection.connect(str(path))
        connection.sendall(envelope(operation, request_id))
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


def bundle(source, destination, version, broken=False, protocol=None):
    shutil.copytree(source, destination, symlinks=False)
    for path in [destination, *destination.rglob('*')]:
        path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)
    (destination / 'manifest.json').write_text(json.dumps(dict(
        architecture='x86_64', protocolVersion=protocol or WIRE, maintenanceProtocolVersion=1, version=version)))
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


class FakeGitHub:
    """Serves one stable release the way GitHub does, and records every request it answers."""

    def __init__(self):
        self.lock = threading.Lock()
        self.release = None
        self.assets = {}
        self.requests = []
        self.stall = None
        self.stalled = threading.Event()
        self.resume = threading.Event()

    def publish(self, version, package, description):
        with self.lock:
            package_id = 100 + len(self.assets)
            described = json.dumps(description).encode()
            self.assets[package_id], self.assets[package_id + 1] = package, described
            self.release = dict(tag_name=version, draft=False, prerelease=False, assets=[
                dict(id=package_id, name=PACKAGE, size=len(package), digest='sha256:' + hashlib.sha256(package).hexdigest()),
                dict(id=package_id + 1, name=DESCRIPTION, size=len(described), digest='sha256:' + hashlib.sha256(described).hexdigest()),
            ])
        return package_id

    def downloaded(self, asset_id):
        with self.lock:
            return ('release-assets.githubusercontent.com', f'/assets/{asset_id}') in self.requests

    def looked_up(self):
        with self.lock:
            return ('api.github.com', '/repos/spatie/bloom/releases/latest') in self.requests

    def stall_download(self, asset_id):
        """Pause this asset after its first bytes, until `resume` is set, to act mid download."""
        with self.lock:
            self.stall = asset_id
            self.stalled.clear()
            self.resume.clear()

    def handler(self):
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def reply(self, status, body, kind='application/json'):
                self.send_response(status)
                self.send_header('Content-Type', kind)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                host = (self.headers.get('Host') or '').split(':')[0]
                with fake.lock:
                    fake.requests.append((host, self.path))
                    release = fake.release
                if host == 'api.github.com' and self.path == '/repos/spatie/bloom/releases/latest' and release:
                    return self.reply(200, json.dumps(release).encode())
                asset = re.fullmatch(r'/repos/spatie/bloom/releases/assets/([0-9]+)', self.path)
                if host == 'api.github.com' and asset and int(asset[1]) in fake.assets:
                    if self.headers.get('Accept') != 'application/octet-stream':
                        return self.reply(415, b'{}')
                    # GitHub answers an asset download with a redirect to its storage host, which
                    # the supervisor must follow only because that host is on its trusted list.
                    self.send_response(302)
                    self.send_header('Location', 'https://release-assets.githubusercontent.com/assets/' + asset[1])
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                stored = re.fullmatch(r'/assets/([0-9]+)', self.path)
                if host == 'release-assets.githubusercontent.com' and stored and int(stored[1]) in fake.assets:
                    data = fake.assets[int(stored[1])]
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data[:65536])
                    self.wfile.flush()
                    if fake.stall == int(stored[1]):
                        fake.stalled.set()
                        # Stay under the supervisor's fifteen second read timeout.
                        fake.resume.wait(10)
                    self.wfile.write(data[65536:])
                    return
                self.reply(404, b'{}')

        return Handler


def openssl(*arguments):
    subprocess.run(['openssl', *map(str, arguments)], check=True, capture_output=True)


@contextlib.contextmanager
def github_on_localhost(directory, fake):
    authority, authority_key = directory / 'authority.pem', directory / 'authority.key'
    certificate, key, request, extensions = (directory / name for name in ('github.pem', 'github.key', 'github.csr', 'github.cnf'))
    openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=Bloom smoke test authority',
            '-keyout', authority_key, '-out', authority,
            '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
    extensions.write_text('subjectAltName=' + ','.join('DNS:' + host for host in HOSTS) + '\n'
                          'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n'
                          'extendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n')
    openssl('req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=api.github.com', '-keyout', key, '-out', request)
    openssl('x509', '-req', '-in', request, '-CA', authority, '-CAkey', authority_key, '-CAcreateserial',
            '-days', '2', '-out', certificate, '-extfile', extensions)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 443), fake.handler())
    server.daemon_threads = True
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    hosts = pathlib.Path('/etc/hosts')
    original = hosts.read_text()
    environment = {name: os.environ.get(name) for name in ('SSL_CERT_FILE', 'SSL_CERT_DIR', 'https_proxy', 'HTTPS_PROXY', 'no_proxy', 'NO_PROXY')}
    try:
        # Docker bind mounts /etc/hosts, so it is rewritten in place rather than replaced.
        hosts.write_text(original.rstrip('\n') + '\n127.0.0.1 ' + ' '.join(HOSTS) + '\n')
        require(socket.gethostbyname('api.github.com') == '127.0.0.1', 'api.github.com did not resolve to the local fake')
        for name in environment:
            os.environ.pop(name, None)
        # OpenSSL reads this when each default context is made, which is every supervisor request.
        os.environ['SSL_CERT_FILE'] = str(authority)
        thread.start()
        yield
    finally:
        if thread.is_alive():
            server.shutdown()
        server.server_close()
        hosts.write_text(original)
        for name, value in environment.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


def verify(binary, account):
    require(sys.platform == 'linux' and os.getuid() == 0, 'Run only as root inside a disposable Linux container')
    require(account.pw_uid > 0 and account.pw_gid > 0, 'The runtime account must not be root')
    source = binary.parent.parent
    require(binary.name == 'bloom-server' and (source / 'lib').is_dir(), 'Pass bin/bloom-server from an extracted Linux package')
    global WIRE
    WIRE = json.loads((source / 'manifest.json').read_bytes())['protocolVersion']
    require(type(WIRE) is int and WIRE > 0, 'The package manifest names no wire protocol')
    socket_parent = pathlib.Path('/run/bloom-maintenance')
    created_socket_parent = not socket_parent.exists()
    socket_parent.mkdir(mode=0o755, exist_ok=True)
    supervisor = control = thread = None
    sockets = []
    github = FakeGitHub()
    with tempfile.TemporaryDirectory(prefix='bloom-maintenance-smoke-', dir='/var/lib') as temporary:
        root = pathlib.Path(temporary)
        root.chmod(0o755)
        certificates = root / 'certificates'
        certificates.mkdir(mode=0o700)
        with github_on_localhost(certificates, github):
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
                    executable_version='v0.0.1', runtime_socket=str(sockets[1]),
                    maintenance_socket=str(sockets[0]), release_repository='spatie/bloom',
                    access_token_sha256=hashlib.sha256(token.encode()).hexdigest())
                config_path = state / 'config.json'
                config_path.write_text(json.dumps(config)); config_path.chmod(0o600)
                supervisor = maintenance.Supervisor(maintenance.load_config(config_path), docker=None, config_path=str(config_path))
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

                def publish(version, broken=False, protocol=None, manifest_protocol=None):
                    protocol = protocol or WIRE
                    staged, archive = root / ('candidate-' + version), root / (version + '.tar.gz')
                    bundle(source, staged, version, broken, manifest_protocol)
                    with tarfile.open(archive, 'w:gz', compresslevel=1) as output:
                        output.add(staged, arcname='bloom-server-linux-x86_64')
                    package = archive.read_bytes()
                    shutil.rmtree(staged); archive.unlink()
                    # The published description, as the release workflow writes it. Only its
                    # protocol differs from the package's own manifest in the incompatible case,
                    # so refusing that release proves the description was read before download.
                    return github.publish(version, package, dict(name=PACKAGE, tag=version, version=version,
                        protocolVersion=protocol, maintenanceProtocolVersion=1, architecture='x86_64', glibc=None,
                        sha256=hashlib.sha256(package).hexdigest(), size=len(package)))

                def settled(expected, installed, package_id):
                    require(rpc(sockets[0], {'catalogue': {}}) == baseline, 'Catalogue changed or became unreadable')
                    require(account_database(account, home, data / 'server.sqlite', 'SELECT value FROM smoke_marker') == "[('preserved',)]",
                            'Database snapshot was not preserved/restored')
                    require(supervisor.current['version'] == installed, f'Committed release pointer is {supervisor.current["version"]}, not {installed}')
                    require(not supervisor.marker.exists(), 'Finished transaction checkpoint remained')
                    require(github.downloaded(package_id), 'The package was not downloaded through the GitHub asset redirect')

                denied = request('start', credential='wrong', planID='untrusted', mode='now')
                require(not denied['authorized'] and denied['error']['code'] == 'unauthorized', 'Unauthorised maintenance accepted')
                require(supervisor.store.active() is None, 'Unauthorised request created a job')

                for version, broken, expected, installed in (('v0.0.2', False, 'succeeded', 'v0.0.2'), ('v0.0.3', True, 'rolledBack', 'v0.0.2')):
                    package_id = publish(version, broken)
                    prepared = request('prepare', component='server')
                    require(prepared.get('error') is None and prepared.get('plan', {}).get('targetVersion') == version, f'Could not prepare {version}: {prepared}')
                    require(github.looked_up(), 'The supervisor did not look up the latest release')
                    request_id = str(uuid.uuid4())
                    accepted = request('start', request_id, planID=prepared['plan']['id'], mode='now')
                    require(accepted.get('error') is None and accepted['jobs'], f'Update was not accepted: {accepted}')
                    job_id = accepted['jobs'][0]['id']
                    replay = request('start', request_id, planID=prepared['plan']['id'], mode='now')
                    require(replay['jobs'][0]['id'] == job_id, 'Idempotent replay created another job')
                    wait_for(lambda: supervisor.worker is not None and not supervisor.worker.is_alive(), 'Update worker timed out', timeout=120)
                    job = request('status', jobID=job_id)['jobs'][0]
                    require(job['phase'] == expected, f'Expected {expected}, got {job}')
                    settled(expected, installed, package_id)
                    print(f'Supervisor {version}: {expected} through the GitHub lookup and download, same-ID replay and database verified.', flush=True)

                package_id = publish('v0.0.4', protocol=WIRE - 1)
                refused = request('prepare', component='server')
                require((refused.get('error') or {}).get('code') == 'incompatible_release' and 'Update Server' in refused['error']['recovery']
                        and refused.get('plan') is None, f'An incompatible release was offered: {refused}')
                component = next(item for item in request('inspect')['components'] if item['id'] == 'server')
                require(component['availableVersion'] == 'v0.0.4' and not component['canUpdate'] and component.get('incompatible') is True
                        and f'older protocol {WIRE - 1}' in component['detail'], f'Inspection did not explain the incompatible release: {component}')
                require(not github.downloaded(package_id), 'The incompatible package was downloaded')
                require(supervisor.store.active() is None and supervisor.current['version'] == 'v0.0.2', 'The incompatible release changed the installation')
                print('Supervisor v0.0.4: refused from its release description before download.', flush=True)

                # The next wire protocol, in both the description and the manifest, must install in
                # place: a rule refusing it strands every server on the first protocol bump.
                package_id = publish('v0.0.5', protocol=WIRE + 1, manifest_protocol=WIRE + 1)
                prepared = request('prepare', component='server')
                require(prepared.get('error') is None and prepared.get('plan'), f'Could not prepare v0.0.5: {prepared}')
                github.stall_download(package_id)
                start = dict(action='start', credential=token, planID=prepared['plan']['id'], mode='now')
                dropped = socket.socket(socket.AF_UNIX)
                dropped.connect(str(sockets[0]))
                dropped.sendall(envelope({'maintenance': {'_0': start}}, str(uuid.uuid4())))
                require(github.stalled.wait(60), 'The dropped client’s update never started downloading')
                # The requesting client goes away mid download without reading a reply, as a
                # laptop lid closing would. Only the durable job may decide what happens next.
                dropped.close()
                github.resume.set()
                observed = {}

                def finished():
                    # Every poll is a fresh connection: a new client that never saw the start.
                    jobs = request('status')['jobs']
                    observed['job'] = next((job for job in jobs if job['planID'] == prepared['plan']['id']), None)
                    return observed['job'] is not None and observed['job']['phase'] in TERMINAL
                wait_for(finished, 'A new client did not see the dropped update finish', timeout=180)
                require(observed['job']['phase'] == 'succeeded', f'The dropped update did not succeed: {observed["job"]}')
                wait_for(lambda: supervisor.worker is not None and not supervisor.worker.is_alive(), 'Update worker did not finish', timeout=60)
                settled('succeeded', 'v0.0.5', package_id)
                print('Supervisor v0.0.5: completed after its requesting client disconnected, observed by a new client.', flush=True)
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
    print('Real runtime, control socket, release acquisition and snapshot integration passed against a local GitHub. No package installers were tested.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=pathlib.Path)
    parser.add_argument('--user', default='nobody')
    parser.add_argument('--disposable-container', action='store_true', help='Acknowledge this container may be discarded after the run')
    arguments = parser.parse_args()
    require(arguments.disposable_container, 'Pass --disposable-container only in an isolated CI container')
    verify(arguments.binary.resolve(), pwd.getpwnam(arguments.user))
