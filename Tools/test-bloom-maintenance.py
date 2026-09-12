#!/usr/bin/env python3
"""Isolated supervisor regressions. No network, service changes or privileged host mutations."""
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
import uuid
from unittest import mock

SOURCE = pathlib.Path(__file__).with_name('bloom-maintenance.py').resolve()
spec = importlib.util.spec_from_file_location('bloom_maintenance', SOURCE)
maintenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maintenance)


def fresh_id():
    return str(uuid.uuid4())


def job(plan_id=None):
    return dict(id=fresh_id(), planID=plan_id or fresh_id(), component='server', targetVersion='v2',
                phase='queued', canCancel=True, updatedAt=maintenance.timestamp(), logs=[], nextSequence=0)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.releases = self.root / 'releases'
        self.releases.mkdir()
        self.config = dict(uid=os.getuid(), gid=os.getgid(), service_home=str(self.root), data_dir=str(self.root / 'data'),
                           state_dir=str(self.state), install_root=str(self.releases), executable='/old/bin/bloom-server',
                           executable_version='v1', runtime_socket=str(self.root / 'runtime.sock'),
                           maintenance_socket=str(self.root / 'maintenance.sock'), release_repository='spatie/bloom',
                           access_token_sha256=hashlib.sha256(b'fixture-admin-credential').hexdigest())
        self.store = maintenance.JobStore(self.state)
        self.addCleanup(self.store.close)


class StoreTests(Fixture):
    def test_acceptance_is_idempotent_but_rejects_reused_intent(self):
        value, request = job(), fresh_id()
        accepted, fresh = self.store.accept(request, dict(planID=value['planID'], mode='now'), value)
        self.assertTrue(fresh)
        repeated, fresh = self.store.accept(request, dict(planID=value['planID'], mode='now'), job())
        self.assertFalse(fresh)
        self.assertEqual(accepted['id'], repeated['id'])
        with self.assertRaisesRegex(maintenance.MaintenanceError, 'different update'):
            self.store.accept(request, dict(planID=value['planID'], mode='whenIdle'), job())

    def test_only_one_active_job_and_completed_job_releases_slot(self):
        value = job()
        self.store.accept(fresh_id(), dict(mode='now'), value)
        with self.assertRaisesRegex(maintenance.MaintenanceError, 'still active'):
            self.store.accept(fresh_id(), dict(mode='now'), job())
        value['phase'] = 'succeeded'
        self.store.update(value)
        self.store.accept(fresh_id(), dict(mode='now'), job())

    def test_log_cursor_remains_monotonic_after_retention(self):
        value = job()
        self.store.accept(fresh_id(), {}, value)
        for number in range(300):
            self.store.log(value['id'], f'Progress {number}')
        logs = self.store.logs(value['id'])
        self.assertEqual(len(logs), 250)
        self.assertEqual(logs[0]['sequence'], 51)
        self.assertEqual(logs[-1]['sequence'], 300)

    def test_acceptance_survives_reopening(self):
        value = job()
        self.store.accept(fresh_id(), {}, value)
        other = maintenance.JobStore(self.state)
        try:
            self.assertEqual(other.active()['id'], value['id'])
        finally:
            other.close()

    def test_unauthorized_request_never_reaches_worker(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=mock.Mock())
        with mock.patch.object(supervisor, 'components') as components:
            response = supervisor.handle(fresh_id(), dict(action='inspect', credential='wrong'))
        self.assertFalse(response['authorized'])
        self.assertEqual(response['error']['code'], 'unauthorized')
        components.assert_not_called()
        self.assertIsNone(self.store.active())

    def test_credential_never_enters_durable_request_or_job(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=mock.Mock())
        plan = dict(id=fresh_id(), component='server', targetVersion='v2', fromVersion='v1', _expires=time.time() + 60)
        self.store.plan(plan)
        with mock.patch.object(threading.Thread, 'start'):
            response = supervisor.handle(fresh_id(), dict(action='start', credential='fixture-admin-credential', planID=plan['id'], mode='now'))
        self.assertEqual(len(response['jobs']), 1)
        for path in self.state.iterdir():
            self.assertNotIn(b'fixture-admin-credential', path.read_bytes())

    def test_retry_after_plan_expiry_returns_original_acceptance(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=mock.Mock())
        plan = dict(id=fresh_id(), component='server', targetVersion='v2', fromVersion='v1', _expires=time.time() + 60)
        self.store.plan(plan)
        request = fresh_id()
        with mock.patch.object(threading.Thread, 'start'):
            first = supervisor.start_job(request, plan['id'], 'now')
            with mock.patch.object(maintenance.time, 'time', return_value=time.time() + 120):
                second = supervisor.start_job(request, plan['id'], 'now')
        self.assertEqual(first['id'], second['id'])


class AdmissionTests(Fixture):
    def test_accepted_job_remains_queryable_during_recovery(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=mock.Mock())
        plan = dict(id=fresh_id(), component='server', targetVersion='v2', fromVersion='v1', _expires=time.time() + 60)
        self.store.plan(plan)
        request = fresh_id()
        with mock.patch.object(threading.Thread, 'start'):
            first = supervisor.start_job(request, plan['id'], 'now')
        supervisor.recovering = True
        second = supervisor.start_job(request, plan['id'], 'now')
        self.assertEqual(first['id'], second['id'])

    def test_terminal_job_cannot_overlap_previous_worker_cleanup(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=mock.Mock())
        supervisor.worker = mock.Mock()
        supervisor.worker.is_alive.return_value = True
        plan = dict(id=fresh_id(), component='server', targetVersion='v2', fromVersion='v1', _expires=time.time() + 60)
        self.store.plan(plan)
        with self.assertRaisesRegex(maintenance.MaintenanceError, 'finishing its cleanup'):
            supervisor.start_job(fresh_id(), plan['id'], 'now')
        self.assertIsNone(self.store.active())

    def test_marker_cleanup_cannot_delete_another_jobs_transaction(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=mock.Mock())
        transaction = dict(jobID=fresh_id(), stage='trial')
        maintenance.atomic_json(supervisor.marker, transaction)
        with self.assertRaisesRegex(maintenance.MaintenanceError, 'transaction changed'):
            supervisor.clear_marker(fresh_id())
        self.assertEqual(json.loads(supervisor.marker.read_bytes()), transaction)

    def test_unknown_fields_and_invalid_types_are_rejected_before_actions(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=mock.Mock())
        for extra in [dict(command='rm'), dict(component=[]), dict(mode='later'), dict(afterSequence=True)]:
            with self.subTest(extra=extra):
                response = supervisor.handle(fresh_id(), dict(action='status', credential='fixture-admin-credential', **extra))
                self.assertEqual(response['error']['code'], 'invalid_request')

    def test_versions_never_silently_downgrade_or_compare_unknown_builds(self):
        for candidate, current, expected in [('v1.3.0', 'v1.2.0', True), ('v1.2.0', 'v1.3.0', False),
                ('v1.2.0', 'v1.2.0', False), ('1.2.0', '1.2.0-beta.1', True),
                ('1.2.0-beta.2', '1.2.0-beta.10', False), ('1.2.0', 'commitdeadbeef', False),
                ('v1.2.0', '0.0.0-dev', True)]:
            with self.subTest(candidate=candidate, current=current):
                self.assertEqual(maintenance.newer_version(candidate, current), expected)


class FakeRuntime:
    def __init__(self, fail_trial=False):
        self.expected_trial = None
        self.fail_trial = fail_trial
        self.starts = []
        self.actions = []
        self.alive = True
        self.ready = True

    def start(self, executable=None, trial=None):
        self.starts.append((executable, trial))
        self.expected_trial = trial
        self.alive = True

    def stop(self):
        self.alive = False

    def running(self):
        return self.alive

    def wait_ready(self):
        if self.expected_trial and self.fail_trial and self.starts[-1][0] == '/new/bin/bloom-server':
            raise maintenance.MaintenanceError('runtime_not_ready', 'Trial startup failed.')

    def control(self, action):
        self.actions.append(action)
        if action == 'commit':
            self.expected_trial = None
        return dict(ready=True, busy=False)


class RecoveryTests(Fixture):
    def supervisor(self, fail_trial=False):
        runtime = FakeRuntime(fail_trial)
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=runtime)
        supervisor.download = mock.Mock(return_value='/new/bin/bloom-server')
        supervisor.database_snapshot = mock.Mock(return_value=str(self.state / 'snapshot-fixture.tar'))
        supervisor.database_restore = mock.Mock()
        return supervisor, runtime

    def accepted(self):
        value = job()
        self.store.accept(fresh_id(), {}, value)
        return value, dict(id=value['planID'], component='server', fromVersion='v1', targetVersion='v2')

    def test_failed_snapshot_removes_partial_copy_before_old_runtime_restarts(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=FakeRuntime())
        value, _ = self.accepted()

        def fail(*args, **kwargs):
            kwargs['stdout'].write(b'partial database')
            raise maintenance.MaintenanceError('worker_failed', 'Snapshot failed.')

        supervisor.account_command = fail
        with self.assertRaises(maintenance.MaintenanceError):
            supervisor.database_snapshot(value['id'])
        self.assertFalse((self.state / ('snapshot-' + value['id'] + '.tar')).exists())

    def test_failed_trial_restores_snapshot_once_before_old_child(self):
        supervisor, runtime = self.supervisor(fail_trial=True)
        value, plan = self.accepted()
        supervisor.run_job(value, plan, 'now')
        self.assertEqual(self.store.get(value['id'])['phase'], 'rolledBack')
        supervisor.database_snapshot.assert_called_once_with(value['id'])
        supervisor.database_restore.assert_called_once()
        self.assertEqual(runtime.starts, [('/new/bin/bloom-server', value['id']), ('/old/bin/bloom-server', value['id'])])
        self.assertEqual(runtime.actions.count('commit'), 1)
        self.assertFalse(supervisor.marker.exists())

    def test_commit_marker_is_durable_before_agent_work_is_released(self):
        supervisor, runtime = self.supervisor()
        value, plan = self.accepted()
        original = runtime.control

        def control(action):
            if action == 'commit':
                self.assertEqual(json.loads(supervisor.marker.read_bytes())['stage'], 'committed')
            return original(action)

        runtime.control = control
        supervisor.run_job(value, plan, 'now')
        self.assertEqual(self.store.get(value['id'])['phase'], 'succeeded')
        supervisor.database_restore.assert_not_called()
        self.assertEqual(supervisor.current['version'], 'v2')

    def test_lost_commit_reply_is_retried_without_rolling_back_or_restarting_work(self):
        supervisor, runtime = self.supervisor()
        value, plan = self.accepted()
        original = runtime.control
        commits = []

        def control(action):
            response = original(action)
            if action == 'commit':
                commits.append(action)
                if len(commits) == 1:
                    raise maintenance.MaintenanceError('runtime_unavailable', 'Lost commit reply.')
            return response

        runtime.control = control
        supervisor.run_job(value, plan, 'now')
        self.assertEqual(self.store.get(value['id'])['phase'], 'succeeded')
        self.assertEqual(len(commits), 2)
        self.assertEqual(len(runtime.starts), 1)
        supervisor.database_restore.assert_not_called()

    def test_recovery_before_commit_restores_old_data_before_launch(self):
        supervisor, runtime = self.supervisor()
        value, _ = self.accepted()
        transaction = dict(jobID=value['id'], stage='trial', old=supervisor.current,
                           new=dict(executable='/new/bin/bloom-server', version='v2'), snapshot=str(self.state / 'snapshot-fixture.tar'))
        maintenance.atomic_json(supervisor.marker, transaction)
        supervisor.recover()
        supervisor.database_restore.assert_called_once_with(transaction['snapshot'])
        self.assertEqual(runtime.starts, [('/old/bin/bloom-server', value['id'])])
        self.assertEqual(self.store.get(value['id'])['phase'], 'rolledBack')

    def test_rollback_commit_is_durable_before_restored_runtime_accepts_work(self):
        supervisor, runtime = self.supervisor(fail_trial=True)
        value, plan = self.accepted()
        original = runtime.control

        def control(action):
            if action == 'commit':
                marker = json.loads(supervisor.marker.read_bytes())
                self.assertEqual(marker['stage'], 'committed')
                self.assertEqual(marker['outcome'], 'rolledBack')
                self.assertEqual(marker['new']['version'], 'v1')
            return original(action)

        runtime.control = control
        supervisor.run_job(value, plan, 'now')
        self.assertEqual(self.store.get(value['id'])['phase'], 'rolledBack')

    def test_recovery_after_rollback_commit_keeps_newly_accepted_work(self):
        supervisor, runtime = self.supervisor()
        value, _ = self.accepted()
        transaction = dict(jobID=value['id'], stage='committed', outcome='rolledBack', old=supervisor.current,
                           new=supervisor.current, snapshot=str(self.state / 'snapshot-fixture.tar'))
        maintenance.atomic_json(supervisor.marker, transaction)
        supervisor.recover()
        supervisor.database_restore.assert_not_called()
        self.assertEqual(runtime.starts, [('/old/bin/bloom-server', None)])
        self.assertEqual(self.store.get(value['id'])['phase'], 'rolledBack')

    def test_recovery_after_commit_never_restores_old_database(self):
        supervisor, runtime = self.supervisor()
        value, _ = self.accepted()
        transaction = dict(jobID=value['id'], stage='committed', old=supervisor.current,
                           new=dict(executable='/new/bin/bloom-server', version='v2'), snapshot=str(self.state / 'snapshot-fixture.tar'))
        maintenance.atomic_json(supervisor.marker, transaction)
        supervisor.recover()
        supervisor.database_restore.assert_not_called()
        self.assertEqual(runtime.starts, [('/new/bin/bloom-server', None)])
        self.assertEqual(self.store.get(value['id'])['phase'], 'succeeded')

    def test_busy_now_resumes_admission_without_stopping_runtime(self):
        supervisor, runtime = self.supervisor()
        value, plan = self.accepted()
        runtime.control = mock.Mock(side_effect=[dict(ready=True, busy=True), dict(ready=True, busy=False)])
        supervisor.run_job(value, plan, 'now')
        self.assertEqual(self.store.get(value['id'])['phase'], 'failed')
        self.assertEqual(runtime.control.call_args_list, [mock.call('quiesce'), mock.call('resume')])
        self.assertTrue(runtime.alive)
        supervisor.database_snapshot.assert_not_called()

    def test_cancel_before_install_never_stops_runtime(self):
        supervisor, runtime = self.supervisor()
        value, plan = self.accepted()
        supervisor.cancel(value['id'])
        supervisor.run_job(value, plan, 'whenIdle')
        self.assertEqual(self.store.get(value['id'])['phase'], 'cancelled')
        self.assertEqual(runtime.starts, [])
        supervisor.database_snapshot.assert_not_called()


class ArchiveTests(Fixture):
    def archive(self, entries):
        path = self.root / 'release.tar.gz'
        with tarfile.open(path, 'w:gz') as archive:
            for member, data in entries:
                archive.addfile(member, io.BytesIO(data))
        return path

    def entry(self, name, data, mode=0o644):
        member = tarfile.TarInfo(name)
        member.size, member.mode = len(data), mode
        return member, data

    def test_rejects_symlinks_before_extracting_any_package_files(self):
        member = tarfile.TarInfo('bloom-server-linux-x86_64/bin/server')
        member.type, member.linkname = tarfile.SYMTYPE, '/etc/passwd'
        archive = self.archive([(member, b'')])
        with self.assertRaisesRegex(maintenance.MaintenanceError, 'unsafe archive'):
            maintenance.extract_release(archive, self.releases)
        self.assertEqual(list(self.releases.iterdir()), [])

    def test_requires_maintenance_capable_manifest_even_at_matching_wire_version(self):
        archive = self.archive([self.entry('bloom-server-linux-x86_64/manifest.json', b'{"architecture":"x86_64","protocolVersion":14}')])
        with self.assertRaisesRegex(maintenance.MaintenanceError, 'incompatible'):
            maintenance.extract_release(archive, self.releases)

    def test_digest_valid_archive_with_wrong_reviewed_version_is_rejected(self):
        directory = tarfile.TarInfo('bloom-server-linux-x86_64/lib')
        directory.type = tarfile.DIRTYPE
        manifest = maintenance.json_bytes(dict(architecture='x86_64', protocolVersion=14, maintenanceProtocolVersion=1, version='1.0.0'))
        archive = self.archive([self.entry('bloom-server-linux-x86_64/manifest.json', manifest),
                                self.entry('bloom-server-linux-x86_64/bin/bloom-server', b'executable', 0o755),
                                (directory, b'')])
        with self.assertRaisesRegex(maintenance.MaintenanceError, 'does not match the reviewed'):
            maintenance.extract_release(archive, self.releases, expected_version='v2.0.0')

    def test_cached_release_must_match_the_reviewed_version_too(self):
        digest = 'a' * 64
        release = self.releases / digest
        (release / 'bin').mkdir(parents=True)
        (release / 'lib').mkdir()
        (release / 'bin/bloom-server').write_bytes(b'executable')
        (release / 'bin/bloom-server').chmod(0o755)
        (release / 'manifest.json').write_bytes(maintenance.json_bytes(dict(architecture='x86_64',
            protocolVersion=14, maintenanceProtocolVersion=1, version='1.0.0')))
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=FakeRuntime())
        with mock.patch.object(maintenance, 'trusted_path'):
            with self.assertRaisesRegex(maintenance.MaintenanceError, 'does not match the reviewed'):
                supervisor.download(job(), dict(_asset=dict(sha256=digest), targetVersion='v2.0.0'))

    def test_rejects_parent_traversal(self):
        archive = self.archive([self.entry('bloom-server-linux-x86_64/../../outside', b'bad')])
        with self.assertRaises(maintenance.MaintenanceError):
            maintenance.extract_release(archive, self.releases)
        self.assertFalse((self.root / 'outside').exists())

    def test_rejects_incompatible_protocol(self):
        archive = self.archive([self.entry('bloom-server-linux-x86_64/manifest.json', b'{"architecture":"x86_64","protocolVersion":99}')])
        with self.assertRaisesRegex(maintenance.MaintenanceError, 'incompatible'):
            maintenance.extract_release(archive, self.releases)


class WireTests(Fixture):
    def exchange(self, request, supervisor=None):
        runtime = FakeRuntime()
        runtime.alive = False
        supervisor = supervisor or maintenance.Supervisor(self.config, store=self.store, runtime=runtime)
        server = maintenance.ControlServer(supervisor)
        local, remote = socket.socketpair()
        server.connections.acquire()
        thread = threading.Thread(target=server.serve_client, args=(remote,))
        thread.start()
        try:
            local.settimeout(2)
            local.sendall(maintenance.json_bytes(request) + b'\n')
            with local.makefile('rb') as reader:
                response = json.loads(reader.readline())
            return response
        finally:
            local.close()
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive())

    def test_status_is_available_without_a_running_runtime(self):
        request = dict(version=14, id=fresh_id(), operation=dict(maintenance={'_0': dict(action='status', credential='fixture-admin-credential')}))
        response = self.exchange(request)
        self.assertEqual(response['id'], request['id'])
        self.assertTrue(response['result']['maintenance']['_0']['authorized'])

    def test_unauthorized_maintenance_never_forwards_credential_to_runtime(self):
        runtime = FakeRuntime()
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=runtime)
        request = dict(version=14, id=fresh_id(), operation=dict(maintenance={'_0': dict(action='start', credential='wrong')}))
        with mock.patch.object(maintenance.ControlServer, 'forward') as forward:
            response = self.exchange(request, supervisor)
        forward.assert_not_called()
        self.assertEqual(response['result']['maintenance']['_0']['error']['code'], 'unauthorized')

    def test_lost_runtime_reply_closes_client_instead_of_fabricating_rejection(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=FakeRuntime())
        server = maintenance.ControlServer(supervisor)
        local, remote = socket.socketpair()
        server.connections.acquire()
        request = dict(version=14, id=fresh_id(), operation=dict(send=dict(sessionID='fixture', text='hello')))
        with mock.patch.object(server, 'forward', side_effect=ConnectionResetError('reply lost')):
            thread = threading.Thread(target=server.serve_client, args=(remote,))
            thread.start()
            try:
                local.settimeout(2)
                local.sendall(maintenance.json_bytes(request) + b'\n')
                self.assertEqual(local.recv(1024), b'')
            finally:
                local.close()
                thread.join(timeout=2)
        self.assertFalse(thread.is_alive())

    def test_large_normal_frames_do_not_use_maintenance_limit(self):
        text = 'x' * 140000
        request = dict(version=14, id=fresh_id(), operation=dict(send=dict(text=text)))
        expected = dict(version=14, id=request['id'], result=dict(file={'_0': dict(text=text)}))

        def forward(_, value, raw):
            self.assertGreater(len(raw), maintenance.MAX_FRAME)
            self.assertEqual(value['operation']['send']['text'], text)
            return maintenance.json_bytes(expected) + b'\n'

        with mock.patch.object(maintenance.ControlServer, 'forward', forward):
            response = self.exchange(request)
        self.assertEqual(response, expected)

    def test_slow_normal_request_does_not_block_next_reply_or_maintenance_status(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=FakeRuntime())
        server = maintenance.ControlServer(supervisor)
        local, remote = socket.socketpair()
        server.connections.acquire()
        entered, release = threading.Event(), threading.Event()
        first, second, status = fresh_id(), fresh_id(), fresh_id()

        def forward(request, _):
            if request['id'] == first:
                entered.set()
                release.wait(timeout=3)
            return maintenance.json_bytes(dict(version=14, id=request['id'], result=dict(hello=dict(name='fixture')))) + b'\n'

        with mock.patch.object(server, 'forward', forward):
            thread = threading.Thread(target=server.serve_client, args=(remote,))
            thread.start()
            try:
                local.settimeout(2)
                local.sendall(maintenance.json_bytes(dict(version=14, id=first, operation=dict(hello={}))) + b'\n')
                self.assertTrue(entered.wait(timeout=1))
                local.sendall(maintenance.json_bytes(dict(version=14, id=second, operation=dict(hello={}))) + b'\n')
                with local.makefile('rb') as reader:
                    self.assertEqual(json.loads(reader.readline())['id'], second)
                    local.sendall(maintenance.json_bytes(dict(version=14, id=status, operation=dict(maintenance={
                        '_0': dict(action='status', credential='fixture-admin-credential')}))) + b'\n')
                    self.assertEqual(json.loads(reader.readline())['id'], status)
                    release.set()
                    self.assertEqual(json.loads(reader.readline())['id'], first)
            finally:
                release.set()
                local.close()
                thread.join(timeout=3)
        self.assertFalse(thread.is_alive())

    def test_slow_drip_frame_has_an_absolute_deadline(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=FakeRuntime())
        server = maintenance.ControlServer(supervisor)
        server.frame_timeout = .08
        local, remote = socket.socketpair()
        server.connections.acquire()
        thread = threading.Thread(target=server.serve_client, args=(remote,))
        thread.start()
        try:
            local.settimeout(1)
            local.sendall(b'{')
            for _ in range(3):
                time.sleep(.02)
                try:
                    local.sendall(b' ')
                except BrokenPipeError:
                    break
            self.assertEqual(local.recv(1024), b'')
        finally:
            local.close()
            thread.join(timeout=1)
        self.assertFalse(thread.is_alive())

    def test_gateway_socket_requires_exact_configured_group(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=FakeRuntime())
        server = maintenance.ControlServer(supervisor)
        import stat
        info = mock.Mock(st_mode=stat.S_IFSOCK | 0o660, st_uid=self.config['uid'], st_gid=1234)
        self.config['gateway_group_id'] = 1234
        with mock.patch.object(maintenance.os, 'lstat', return_value=info), mock.patch.object(maintenance.socket, 'socket'):
            server.runtime_connection()
        self.config['gateway_group_id'] = 999
        with mock.patch.object(maintenance.os, 'lstat', return_value=info):
            with self.assertRaises(maintenance.MaintenanceError):
                server.runtime_connection()

    def test_hello_remains_available_while_runtime_is_down(self):
        response = self.exchange(dict(version=14, id=fresh_id(), operation=dict(hello={})))
        self.assertEqual(response['result']['hello']['name'], socket.gethostname())

    def test_diagnostics_advertise_maintenance_during_restart(self):
        response = self.exchange(dict(version=14, id=fresh_id(), operation=dict(diagnostics={})))
        self.assertTrue(response['result']['diagnostics']['_0']['maintenanceManagement'])


class RuntimeTests(Fixture):
    def test_real_socketpair_ready_control_and_child_reaping(self):
        executable = self.root / 'fake-runtime'
        executable.write_text('#!' + sys.executable + '''
import json,os,socket
connection=socket.socket(fileno=int(os.environ['BLOOM_MAINTENANCE_FD']))
connection.sendall(b'{"event":"ready"}\\n')
with connection.makefile('rb') as source:
    for line in source:
        request=json.loads(line)
        connection.sendall((json.dumps(dict(id=request['id'],ready=True,busy=False))+'\\n').encode())
''')
        executable.chmod(0o700)
        self.config['executable'] = str(executable)
        seen = []

        def spawn(*args, **kwargs):
            seen.append(dict(kwargs))
            for name in ('user', 'group', 'extra_groups'):
                kwargs.pop(name)
            return subprocess.Popen(*args, **kwargs)

        runtime = maintenance.RuntimeProcess(self.config, spawn=spawn)
        try:
            child = runtime.start()
            runtime.wait_ready(timeout=2)
            self.assertEqual(runtime.control('quiesce'), dict(id=mock.ANY, ready=True, busy=False))
            self.assertEqual(seen[0]['extra_groups'], [])
            self.assertEqual(seen[0]['user'], self.config['uid'])
        finally:
            runtime.stop(timeout=1)
        self.assertIsNotNone(child.poll())
        self.assertFalse(runtime.running())


@unittest.skipIf(os.getuid() == 0, 'The dropped-user worker tests run directly as the test account.')
class DatabaseWorkerTests(Fixture):
    def test_snapshot_and_restore_preserve_database_wal_and_shm(self):
        directory = self.root / 'data'
        directory.mkdir()
        names = ('server.sqlite', 'server.sqlite-wal', 'server.sqlite-shm')
        for name in names:
            (directory / name).write_bytes(('original-' + name).encode())
        snapshot = subprocess.run([sys.executable, str(SOURCE), '--database-worker', 'snapshot', str(directory)],
                                  capture_output=True, timeout=3, check=True).stdout
        for name in names:
            (directory / name).write_bytes(b'changed')
        subprocess.run([sys.executable, str(SOURCE), '--database-worker', 'restore', str(directory)],
                       input=snapshot, capture_output=True, timeout=3, check=True)
        for name in names:
            self.assertEqual((directory / name).read_bytes(), ('original-' + name).encode())

    def test_snapshot_requires_main_database_not_only_sidecars(self):
        directory = self.root / 'data'
        directory.mkdir()
        (directory / 'server.sqlite-wal').write_bytes(b'private-wal')
        result = subprocess.run([sys.executable, str(SOURCE), '--database-worker', 'snapshot', str(directory)],
                                capture_output=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b'private-wal', result.stdout)

    def test_empty_snapshot_cannot_delete_existing_database(self):
        directory = self.root / 'data'
        directory.mkdir()
        (directory / 'server.sqlite').write_bytes(b'keep-database')
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w'):
            pass
        result = subprocess.run([sys.executable, str(SOURCE), '--database-worker', 'restore', str(directory)],
                                input=output.getvalue(), capture_output=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((directory / 'server.sqlite').read_bytes(), b'keep-database')

    def test_snapshot_refuses_a_database_symlink(self):
        directory = self.root / 'data'
        directory.mkdir()
        outside = self.root / 'outside'
        outside.write_bytes(b'private')
        (directory / 'server.sqlite').symlink_to(outside)
        result = subprocess.run([sys.executable, str(SOURCE), '--database-worker', 'snapshot', str(directory)],
                                capture_output=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b'private', result.stdout)
        self.assertEqual(outside.read_bytes(), b'private')


if __name__ == '__main__':
    unittest.main()
