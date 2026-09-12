"""Protected supervisor provisioning used only by Bloom's administrator installer."""
import json
import os
import pathlib
import re
import shutil
import socket
import sqlite3
import stat
import tempfile
from contextlib import closing


class MaintenanceInstallFailure(Exception):
    def __init__(self, code, message, recovery):
        super().__init__(message)
        self.code, self.message, self.recovery = code, message, recovery


def maintenance_refuse(code, message):
    raise MaintenanceInstallFailure(code, message, 'Inspect the managed maintenance service as an administrator. Finish or recover pending updates before retrying setup.')


class MaintenanceInstallation:
    """The only mutable installation inputs are fixed local paths and a credential digest.

    Path/owner injection exists for isolated installer tests. CLI and RPC callers cannot select
    the privileged destination or supply supervisor source code.
    """
    def __init__(self, args, protect, *, base=pathlib.Path('/var/lib/bloom-maintenance'),
                 launcher=pathlib.Path('/usr/local/libexec/bloom-maintenance.py'),
                 runtime=pathlib.Path('/run/bloom-maintenance'), owner_uid=0):
        self.args, self.protect, self.owner_uid = args, protect, owner_uid
        self.base, self.launcher, self.runtime = base, launcher, runtime
        self.docker_module = launcher.with_name('bloom_maintenance_docker.py')
        self.state = base / args.service_name
        self.releases = self.state / 'releases'
        self.config_path = self.state / 'config.json'
        self.current_path = self.state / 'current.json'
        self.previous = None
        self.key_accepted = False

    @property
    def enabled(self):
        return bool(getattr(self.args, 'maintenance_key_sha256', None)) or self.config_path.exists() or self.config_path.is_symlink()

    @property
    def socket_path(self):
        value = 2166136261
        for byte in str(self.args.data_dir / 'server.sqlite').encode():
            value = ((value ^ byte) * 16777619) & 0xffffffff
        return self.runtime / f'{value:08x}.sock'

    def private_file(self, path, maximum=1024 * 1024):
        self.protect(path)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'rb') as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != self.owner_uid or info.st_mode & 0o077 or info.st_size > maximum:
                maintenance_refuse('untrusted_maintenance', 'Maintenance metadata must be a private root-owned regular file.')
            data = source.read(maximum + 1)
            if len(data) > maximum:
                maintenance_refuse('untrusted_maintenance', 'Maintenance metadata is too large.')
            return data

    def existing_config(self):
        self.protect(self.config_path)
        if not self.config_path.exists():
            return None
        try:
            value = json.loads(self.private_file(self.config_path))
            expected = dict(service_home=str(self.args.service_home), data_dir=str(self.args.data_dir),
                            state_dir=str(self.state), install_root=str(self.releases), maintenance_socket=str(self.socket_path))
            if not isinstance(value, dict) or any(value.get(key) != item for key, item in expected.items()):
                raise ValueError('different installation')
            if re.fullmatch(r'[0-9a-f]{64}', value.get('access_token_sha256', '')) is None:
                raise ValueError('invalid credential digest')
            return value
        except (ValueError, TypeError):
            maintenance_refuse('untrusted_maintenance', 'The supervisor configuration does not match this Bloom installation.')

    def ensure_idle(self):
        if not self.enabled:
            return
        self.existing_config()
        transaction = self.state / 'transaction.json'
        self.protect(transaction)
        if transaction.exists():
            maintenance_refuse('maintenance_busy', 'A supervised update or rollback still needs recovery. Setup will not replace its files.')
        database = self.state / 'maintenance.sqlite'
        self.protect(database)
        if database.exists():
            self.private_file(database, maximum=64 * 1024 * 1024)
            for suffix in ('-wal', '-shm'):
                companion = database.with_name(database.name + suffix)
                self.protect(companion)
                if companion.exists():
                    self.private_file(companion, maximum=64 * 1024 * 1024)
            try:
                with closing(sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=2)) as connection:
                    if connection.execute("SELECT 1 FROM jobs WHERE state NOT IN ('succeeded','failed','cancelled','rolledBack') LIMIT 1").fetchone():
                        maintenance_refuse('maintenance_busy', 'A maintenance job is still active. Finish or recover it before changing the installation.')
            except sqlite3.Error:
                maintenance_refuse('untrusted_maintenance', 'The durable maintenance job state could not be checked safely.')

    def validate_digest(self):
        supplied = getattr(self.args, 'maintenance_key_sha256', None)
        if supplied is not None and re.fullmatch(r'[0-9a-f]{64}', supplied) is None:
            maintenance_refuse('invalid_maintenance_key', 'The maintenance credential digest must be 64 lowercase hexadecimal characters.')
        existing = self.existing_config()
        if existing and supplied and supplied != existing['access_token_sha256']:
            maintenance_refuse('maintenance_key_conflict', 'This server already uses another maintenance access key. Setup will not replace it.')
        return supplied or (existing or {}).get('access_token_sha256')

    def validate_bundle(self, bundle):
        try:
            manifest = json.loads((bundle / 'manifest.json').read_bytes())
            if manifest.get('maintenanceProtocolVersion') != 1 or manifest.get('protocolVersion') != 14:
                raise ValueError('missing supervisor support')
            version = manifest.get('version')
            if not isinstance(version, str) or not version.strip() or len(version) > 200:
                raise ValueError('missing version')
            return version
        except (OSError, ValueError, TypeError):
            maintenance_refuse('maintenance_package_required', 'This server package does not support supervised maintenance. Choose a newly built Bloom Server package.')

    def directory(self, path):
        self.protect(path)
        path.mkdir(mode=0o755, parents=True, exist_ok=True)
        self.protect(path)
        if not path.is_dir():
            maintenance_refuse('untrusted_maintenance', 'A maintenance directory is not a directory.')
        path.chmod(0o755)

    def atomic_write(self, path, data, mode=0o600):
        self.protect(path)
        temporary = path.with_name('.' + path.name + '-' + os.urandom(8).hex())
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
        try:
            os.fchmod(descriptor, mode)
            with os.fdopen(descriptor, 'wb') as output:
                output.write(data); output.flush(); os.fsync(output.fileno())
            os.replace(temporary, path)
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            temporary.unlink(missing_ok=True)

    def publish(self, bundle, checksum, account, supervisor_source, docker_source):
        self.ensure_idle()
        digest = self.validate_digest()
        if digest is None:
            maintenance_refuse('maintenance_key_required', 'A maintenance access key is required for the supervised installation.')
        version = self.validate_bundle(bundle)
        if re.fullmatch(r'[0-9a-f]{64}', checksum) is None or not supervisor_source.strip() or not docker_source.strip():
            maintenance_refuse('maintenance_package_required', 'Verified supervisor source and package checksum are required.')
        for path in (self.base, self.state, self.releases, self.launcher.parent, self.runtime):
            self.directory(path)
        self.previous = {}
        for path in (self.config_path, self.current_path):
            self.previous[path] = self.private_file(path) if path.exists() else None
        for path in (self.launcher, self.docker_module):
            self.protect(path)
            if path.exists():
                info = path.stat()
                if not stat.S_ISREG(info.st_mode) or info.st_uid != self.owner_uid or info.st_mode & 0o022 or info.st_size > 1024 * 1024:
                    maintenance_refuse('untrusted_maintenance', 'A supervisor source file has unexpected ownership or permissions.')
                self.previous[path] = path.read_bytes()
            else:
                self.previous[path] = None
        for path in [bundle, *bundle.rglob('*')]:
            info = path.lstat()
            if info.st_uid != self.owner_uid or info.st_mode & 0o022 or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
                maintenance_refuse('untrusted_maintenance', 'The staged server package is not a protected regular-file bundle.')
        release = self.releases / checksum
        self.protect(release)
        if not release.exists():
            temporary = pathlib.Path(tempfile.mkdtemp(prefix='.release-', dir=self.releases))
            try:
                shutil.copytree(bundle, temporary / 'bundle', symlinks=False)
                for path in [temporary / 'bundle', *(temporary / 'bundle').rglob('*')]:
                    if path.is_symlink() or not (path.is_dir() or path.is_file()):
                        maintenance_refuse('untrusted_maintenance', 'A verified release contains an unexpected file type.')
                    path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)
                    if path.is_file():
                        with path.open('rb') as output:
                            os.fsync(output.fileno())
                for path in sorted([temporary / 'bundle', *((temporary / 'bundle').rglob('*'))], key=lambda item: len(item.parts), reverse=True):
                    if path.is_dir():
                        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                        try:
                            os.fsync(descriptor)
                        finally:
                            os.close(descriptor)
                os.replace(temporary / 'bundle', release)
                parent = os.open(self.releases, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    os.fsync(parent)
                finally:
                    os.close(parent)
            finally:
                shutil.rmtree(temporary)
        for path in [release, *release.rglob('*')]:
            self.protect(path)
        executable = str(release / 'bin/bloom-server')
        config = dict(uid=account.pw_uid, gid=account.pw_gid, state_dir=str(self.state), install_root=str(self.releases),
                      executable=executable, executable_version=version, protocol_version=14,
                      service_home=str(self.args.service_home), data_dir=str(self.args.data_dir),
                      runtime_socket=str(self.args.runtime_socket), maintenance_socket=str(self.socket_path),
                      access_token_sha256=digest, release_repository='spatie/bloom')
        self.atomic_write(self.docker_module, docker_source.encode(), mode=0o644)
        self.atomic_write(self.launcher, supervisor_source.encode(), mode=0o755)
        self.atomic_write(self.config_path, (json.dumps(config) + '\n').encode())
        self.atomic_write(self.current_path, (json.dumps(dict(executable=executable, version=version)) + '\n').encode())
        self.key_accepted = getattr(self.args, 'maintenance_key_sha256', None) == digest

    def rollback(self):
        if self.previous is None:
            return
        for path, value in self.previous.items():
            if value is None:
                self.protect(path); path.unlink(missing_ok=True)
            else:
                self.atomic_write(path, value, mode=0o755 if path == self.launcher else 0o644 if path == self.docker_module else 0o600)
        self.key_accepted = False

    def socket_ready(self, account):
        try:
            info = self.socket_path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != self.owner_uid or info.st_gid != account.pw_gid or info.st_mode & 0o007:
                return False
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(1)
                connection.connect(str(self.socket_path))
                return True
        except OSError:
            return False

    def unit_contents(self):
        return f'''# Managed by Bloom Add Server.
[Unit]
Description=Bloom Server with supervised maintenance
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
RuntimeDirectory=bloom-maintenance
RuntimeDirectoryMode=0755
ExecStart=/usr/bin/python3 {self.launcher} --config {self.config_path}
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
TimeoutStopSec=45

[Install]
WantedBy=multi-user.target
'''
