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

    def test_lost_quiesce_reply_resumes_admission_before_resolving_job(self):
        supervisor, runtime = self.supervisor()
        value, plan = self.accepted()
        gate = {'closed': False}
        actions = []

        def control(action):
            actions.append(action)
            if action == 'quiesce':
                gate['closed'] = True
                raise maintenance.MaintenanceError('runtime_unavailable', 'Quiesce acknowledgement was lost.')
            if action == 'resume':
                gate['closed'] = False
            return dict(ready=True, busy=False)

        runtime.control = control
        supervisor.run_job(value, plan, 'now')
        self.assertFalse(gate['closed'])
        self.assertEqual(actions, ['quiesce', 'resume'])
        self.assertEqual(self.store.get(value['id'])['phase'], 'failed')
        self.assertEqual(runtime.starts, [])

    def test_lost_resume_reply_leaves_recoverable_job_and_recovery_resumes_live_child(self):
        supervisor, runtime = self.supervisor()
        value, plan = self.accepted()
        runtime.control = mock.Mock(side_effect=[dict(ready=True, busy=True),
            maintenance.MaintenanceError('runtime_unavailable', 'Resume reply lost.')])
        supervisor.run_job(value, plan, 'now')
        self.assertEqual(self.store.get(value['id'])['phase'], 'interrupted')
        runtime.control = mock.Mock(return_value=dict(ready=True, busy=False))
        supervisor.run_recovery(self.store.get(value['id']))
        runtime.control.assert_called_once_with('resume')
        self.assertEqual(runtime.starts, [])
        self.assertTrue(runtime.running())
        self.assertEqual(self.store.get(value['id'])['phase'], 'failed')

    def test_failed_startup_recovery_keeps_component_job_recoverable(self):
        supervisor, runtime = self.supervisor()
        value, _ = self.accepted()
        value.update(component='codex', phase='installing')
        self.store.update(value)
        runtime.wait_ready = mock.Mock(side_effect=maintenance.MaintenanceError('runtime_not_ready', 'Startup failed.'))
        with self.assertRaises(maintenance.MaintenanceError):
            supervisor.recover()
        self.assertEqual(self.store.get(value['id'])['phase'], 'interrupted')
        supervisor.recovery_failed = True
        with mock.patch.object(threading.Thread, 'start'):
            recovered = supervisor.recover_job(fresh_id(), value['id'])
        self.assertEqual(recovered['phase'], 'restarting')

    def test_cancel_before_install_never_stops_runtime(self):
        supervisor, runtime = self.supervisor()
        value, plan = self.accepted()
        supervisor.cancel(value['id'])
        supervisor.run_job(value, plan, 'whenIdle')
        self.assertEqual(self.store.get(value['id'])['phase'], 'cancelled')
        self.assertEqual(runtime.starts, [])
        supervisor.database_snapshot.assert_not_called()


class DockerIntegrationTests(Fixture):
    def adapter(self):
        class DockerError(Exception):
            def __init__(self, code, message, recovery):
                super().__init__(message)
                self.code, self.recovery = code, recovery
        adapter = mock.Mock()
        adapter.DockerMaintenanceError = DockerError
        adapter.prepare.return_value = dict(schema=1, installed={'docker.io': '1.0'}, targetVersion='1.1',
            updates={'docker.io': '1.1'}, candidates={'docker.io': '1.1'},
            summary='Docker services and containers may restart. No automatic rollback.',
            restarts=['Bloom rootless Docker', 'Docker containers'])
        adapter.apply.return_value = dict(version='1.1', message='Docker packages and the private daemon were verified.')
        return adapter

    def accepted(self, supervisor):
        public = supervisor.prepare('docker')
        plan = self.store.get_plan(public['id'])
        value = job(public['id'])
        value.update(component='docker', targetVersion='1.1')
        self.store.accept(fresh_id(), {}, value)
        return value, plan, public

    def test_review_exposes_restart_impact_but_keeps_exact_apt_payload_server_owned(self):
        adapter = self.adapter()
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=FakeRuntime(), docker=adapter)
        _, plan, public = self.accepted(supervisor)
        self.assertNotIn('_docker', public)
        self.assertEqual(plan['_docker']['updates'], {'docker.io': '1.1'})
        self.assertEqual(public['restarts'], ['Bloom Server', 'Bloom rootless Docker', 'Docker containers'])
        self.assertIn('No automatic rollback', public['summary'])

    def test_docker_applies_only_reviewed_plan_after_bloom_stops(self):
        adapter, runtime = self.adapter(), FakeRuntime()
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=runtime, docker=adapter)
        value, plan, _ = self.accepted(supervisor)

        def apply(config, payload, log):
            self.assertFalse(runtime.running())
            self.assertEqual(payload, plan['_docker'])
            self.assertEqual(config, self.config)
            log('Installing docker.io=1.1')
            return dict(version='1.1', message='Docker was verified.')

        adapter.apply.side_effect = apply
        supervisor.run_job(value, plan, 'whenIdle')
        self.assertEqual(self.store.get(value['id'])['phase'], 'succeeded')
        self.assertTrue(runtime.running())
        self.assertEqual(runtime.actions, ['quiesce'])
        self.assertEqual(runtime.starts, [('/old/bin/bloom-server', None)])
        self.assertTrue(any('docker.io=1.1' in item['message'] for item in self.store.logs(value['id'])))

    def test_partial_docker_failure_preserves_diagnostics_and_restarts_bloom_without_reapply(self):
        adapter, runtime = self.adapter(), FakeRuntime()
        adapter.apply.side_effect = adapter.DockerMaintenanceError('package_lock',
            'apt-get exited with status 100. Could not get lock.', 'Wait for the other package manager. No rollback was attempted.')
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=runtime, docker=adapter)
        value, plan, _ = self.accepted(supervisor)
        supervisor.run_job(value, plan, 'now')
        failed = self.store.get(value['id'])
        self.assertEqual(failed['phase'], 'failed')
        self.assertIn('may be partial', failed['message'])
        self.assertTrue(runtime.running())
        output = '\n'.join(item['message'] for item in self.store.logs(value['id']))
        self.assertIn('status 100', output)
        self.assertIn('Wait for the other package manager', output)
        runtime.alive = False
        supervisor.recover()
        adapter.apply.assert_called_once()

    def test_cancelled_docker_plan_never_reaches_apt(self):
        adapter, runtime = self.adapter(), FakeRuntime()
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=runtime, docker=adapter)
        value, plan, _ = self.accepted(supervisor)
        supervisor.cancel(value['id'])
        supervisor.run_job(value, plan, 'whenIdle')
        adapter.apply.assert_not_called()
        self.assertEqual(self.store.get(value['id'])['phase'], 'cancelled')
        self.assertTrue(runtime.running())

    def test_docker_plan_failure_preserves_recovery_in_protocol(self):
        adapter = self.adapter()
        adapter.prepare.side_effect = adapter.DockerMaintenanceError('package_changes', 'Unreviewed dependency.', 'Ask an administrator to review APT dependencies.')
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=FakeRuntime(), docker=adapter)
        reply = supervisor.handle(fresh_id(), dict(action='prepare', component='docker', credential='fixture-admin-credential'))
        self.assertEqual(reply['error']['code'], 'package_changes')
        self.assertIn('APT dependencies', reply['error']['recovery'])


class OutputTests(Fixture):
    def test_real_worker_output_is_live_redacted_and_failure_tail_is_copyable(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=FakeRuntime())
        value = job()
        value['component'] = 'codex'
        self.store.accept(fresh_id(), {}, value)
        release = self.root / 'output-received'
        worker = self.root / 'fake-worker.py'
        worker.write_text("""import json,pathlib,time,sys
print(json.dumps(dict(event='output',message='npm EACCES authorization=super-secret-value')),flush=True)
while not pathlib.Path(sys.argv[1]).exists(): time.sleep(.01)
print(json.dumps(dict(error='npm exited with status 13. EACCES on installation directory.',code='tool_update_failed',recovery='Check ownership before retrying.')),flush=True)
sys.exit(1)
""")
        original = subprocess.Popen

        def spawn(_arguments, **kwargs):
            for name in ('user', 'group', 'extra_groups'):
                kwargs.pop(name)
            return original([sys.executable, str(worker), str(release)], **kwargs)

        def log(message):
            supervisor.job_log(value['id'], message)
            release.write_text('received before process exit')

        with mock.patch.object(maintenance.subprocess, 'Popen', spawn):
            with self.assertRaises(maintenance.MaintenanceError) as captured:
                supervisor.account_command(['--tool-worker', 'install', 'codex', '1.2.3'], timeout=2, log=log)
        self.assertEqual(captured.exception.code, 'tool_update_failed')
        self.assertIn('status 13', str(captured.exception))
        self.assertIn('ownership', captured.exception.recovery)
        output = '\n'.join(item['message'] for item in self.store.logs(value['id']))
        self.assertIn('EACCES', output)
        self.assertNotIn('super-secret-value', output)
        self.assertTrue(release.exists())

    def test_log_byte_budget_and_multiline_private_key_redaction(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=FakeRuntime())
        value = job()
        self.store.accept(fresh_id(), {}, value)
        supervisor.job_log(value['id'], '-----BEGIN OPENSSH PRIVATE KEY-----')
        supervisor.job_log(value['id'], 'sensitive-payload')
        supervisor.job_log(value['id'], '-----END OPENSSH PRIVATE KEY-----')
        output = '\n'.join(item['message'] for item in self.store.logs(value['id']))
        self.assertNotIn('sensitive-payload', output)
        for _ in range(80):
            supervisor.job_log(value['id'], '🌻' * 2000)
        logs = self.store.logs(value['id'])
        self.assertTrue(all(len(item['message'].encode()) <= 4096 for item in logs))
        self.assertLessEqual(sum(len(item['message'].encode()) for item in logs), 262144)


class ExplicitRecoveryTests(Fixture):
    def accepted(self, component='server'):
        value = job()
        value.update(component=component, phase='interrupted', canCancel=False)
        self.store.accept(fresh_id(), {}, value)
        return value

    def supervisor(self, runtime=None):
        runtime = runtime or FakeRuntime()
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=runtime, docker=mock.Mock())
        supervisor.account_command = mock.Mock()
        supervisor.database_restore = mock.Mock()
        return supervisor, runtime

    def test_recovery_acceptance_is_durable_and_replays_without_another_worker(self):
        value = self.accepted()
        supervisor, _ = self.supervisor()
        request_id = fresh_id()
        with mock.patch.object(threading.Thread, 'start') as start:
            first = supervisor.handle(request_id, dict(action='recover', jobID=value['id'], credential='fixture-admin-credential'))
            second = supervisor.handle(request_id, dict(action='recover', jobID=value['id'], credential='fixture-admin-credential'))
        self.assertEqual(first['jobs'][0]['phase'], 'restarting')
        self.assertEqual(first['jobs'][0]['id'], second['jobs'][0]['id'])
        start.assert_called_once()
        with self.assertRaisesRegex(maintenance.MaintenanceError, 'different recovery'):
            supervisor.recover_job(request_id, fresh_id())
        for path in self.state.iterdir():
            self.assertNotIn(b'fixture-admin-credential', path.read_bytes())

    def test_committed_live_runtime_recovery_only_retries_commit(self):
        value = self.accepted()
        supervisor, runtime = self.supervisor()
        runtime.expected_trial = value['id']
        maintenance.atomic_json(supervisor.marker, dict(jobID=value['id'], stage='committed', old=supervisor.current,
            new=dict(executable='/new/bin/bloom-server', version='v2'), snapshot=str(self.state / 'snapshot-fixture.tar')))
        supervisor.run_recovery(value)
        self.assertEqual(self.store.get(value['id'])['phase'], 'succeeded')
        self.assertEqual(runtime.actions, ['commit'])
        self.assertEqual(runtime.starts, [])
        supervisor.database_restore.assert_not_called()
        supervisor.account_command.assert_not_called()
        supervisor.docker.apply.assert_not_called()

    def test_precommit_recovery_restores_paused_candidate_without_installing_packages(self):
        value = self.accepted()
        supervisor, runtime = self.supervisor()
        runtime.expected_trial = value['id']
        maintenance.atomic_json(supervisor.marker, dict(jobID=value['id'], stage='trial', old=supervisor.current,
            new=dict(executable='/new/bin/bloom-server', version='v2'), snapshot=str(self.state / 'snapshot-fixture.tar')))
        supervisor.run_recovery(value)
        self.assertEqual(self.store.get(value['id'])['phase'], 'rolledBack')
        supervisor.database_restore.assert_called_once()
        self.assertEqual(runtime.starts, [('/old/bin/bloom-server', value['id'])])
        supervisor.account_command.assert_not_called()
        supervisor.docker.apply.assert_not_called()

    def test_unresponsive_committed_live_runtime_is_not_killed_or_rolled_back(self):
        value = self.accepted()
        supervisor, runtime = self.supervisor()
        runtime.control = mock.Mock(side_effect=maintenance.MaintenanceError('runtime_unavailable', 'No control reply.'))
        runtime.stop = mock.Mock()
        maintenance.atomic_json(supervisor.marker, dict(jobID=value['id'], stage='committed', old=supervisor.current,
            new=dict(executable='/new/bin/bloom-server', version='v2')))
        supervisor.run_recovery(value)
        self.assertEqual(self.store.get(value['id'])['phase'], 'interrupted')
        runtime.stop.assert_not_called()
        supervisor.database_restore.assert_not_called()
        self.assertTrue(supervisor.marker.exists())

    def test_docker_recovery_restarts_bloom_but_never_reapplies_apt(self):
        value = self.accepted('docker')
        supervisor, runtime = self.supervisor()
        runtime.alive = False
        supervisor.run_recovery(value)
        self.assertEqual(self.store.get(value['id'])['phase'], 'failed')
        self.assertIn('outcome remains unconfirmed', self.store.get(value['id'])['message'])
        self.assertEqual(runtime.starts, [('/old/bin/bloom-server', None)])
        supervisor.account_command.assert_not_called()
        supervisor.docker.apply.assert_not_called()

    def test_recovery_refuses_completed_job(self):
        value = self.accepted()
        value['phase'] = 'succeeded'
        self.store.update(value)
        supervisor, _ = self.supervisor()
        with self.assertRaisesRegex(maintenance.MaintenanceError, 'Only an interrupted'):
            supervisor.recover_job(fresh_id(), value['id'])
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM commands').fetchone()[0], 0)


@unittest.skipIf(os.getuid() == 0, 'The tool worker is intentionally refused for root.')
class ToolWorkerTests(Fixture):
    def test_npm_worker_pins_reviewed_version_and_uses_shared_streaming(self):
        import contextlib
        import types
        (self.root / '.local').mkdir()
        completed = subprocess.CompletedProcess([], 0)
        completed.details = ''
        with mock.patch('pwd.getpwuid', return_value=types.SimpleNamespace(pw_dir=str(self.root))), \
             mock.patch.object(maintenance, 'tool_installation', side_effect=[dict(method='npm', installedVersion='1.1.0'), dict(method='npm', installedVersion='1.1.0'), dict(installedVersion='1.2.3')]), \
             mock.patch.object(maintenance, 'refuse_external_agents'), \
             mock.patch('shutil.which', return_value='/usr/bin/npm'), \
             mock.patch.object(maintenance, 'stream_install_command', return_value=completed) as stream, \
             mock.patch.object(maintenance.subprocess, 'run', return_value=types.SimpleNamespace(returncode=0)), \
             contextlib.redirect_stdout(io.StringIO()):
            maintenance.tool_worker('install', 'codex', '1.2.3', '1.1.0')
        arguments = stream.call_args.args[0]
        self.assertEqual(arguments[-1], '@openai/codex@1.2.3')
        self.assertIn('--allow-scripts=@openai/codex', arguments)
        self.assertEqual(arguments[arguments.index('--prefix') + 1], str(self.root / '.local'))
        self.assertEqual(stream.call_args.kwargs['capture_limit'], 0)
        self.assertEqual(stream.call_args.kwargs['event_limit'], 500)
        self.assertTrue(callable(stream.call_args.kwargs['output']))

    def test_installation_change_while_waiting_is_rejected_under_the_os_lock(self):
        import types
        import fcntl
        (self.root / '.local').mkdir()
        inspected_under_lock = []

        def installation(*_):
            if not inspected_under_lock:
                inspected_under_lock.append(False)
                return dict(method='npm', installedVersion='1.1.0')
            with (self.root / '.local/.bloom-tool-update.lock').open('r') as lock:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            inspected_under_lock.append(True)
            return dict(method='npm', installedVersion='1.3.0')

        with mock.patch('pwd.getpwuid', return_value=types.SimpleNamespace(pw_dir=str(self.root))), \
             mock.patch.object(maintenance, 'tool_installation', side_effect=installation), \
             mock.patch.object(maintenance, 'stream_install_command') as stream:
            with self.assertRaisesRegex(maintenance.MaintenanceError, 'changed after review'):
                maintenance.tool_worker('install', 'codex', '1.2.3', '1.1.0')
        self.assertEqual(inspected_under_lock, [False, True])
        stream.assert_not_called()

    def test_npm_failure_keeps_exit_status_and_sanitised_failure_tail(self):
        import types
        (self.root / '.local').mkdir()
        failed = subprocess.CompletedProcess([], 13)
        failed.details = 'npm ERR! EACCES: permission denied'
        with mock.patch('pwd.getpwuid', return_value=types.SimpleNamespace(pw_dir=str(self.root))), \
             mock.patch.object(maintenance, 'tool_installation', return_value=dict(method='npm', installedVersion='1.1.0')), \
             mock.patch.object(maintenance, 'refuse_external_agents'), \
             mock.patch('shutil.which', return_value='/usr/bin/npm'), \
             mock.patch.object(maintenance, 'stream_install_command', return_value=failed):
            with self.assertRaises(maintenance.MaintenanceError) as captured:
                maintenance.tool_worker('install', 'codex', '1.2.3', '1.1.0')
        self.assertEqual(captured.exception.code, 'tool_update_failed')
        self.assertIn('status 13', str(captured.exception))
        self.assertIn('EACCES', str(captured.exception))


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

    def test_idle_deadline_does_not_close_a_pending_long_request(self):
        supervisor = maintenance.Supervisor(self.config, store=self.store, runtime=FakeRuntime())
        server = maintenance.ControlServer(supervisor)
        server.idle_timeout = .01
        local, remote = socket.socketpair()
        server.connections.acquire()
        request_id = fresh_id()
        entered, release = threading.Event(), threading.Event()

        def forward(request, raw):
            entered.set()
            release.wait(timeout=2)
            return maintenance.json_bytes(dict(version=14, id=request['id'], result=dict(hello=dict(name='done')))) + b'\n'

        with mock.patch.object(server, 'forward', forward):
            thread = threading.Thread(target=server.serve_client, args=(remote,))
            thread.start()
            try:
                local.settimeout(2)
                local.sendall(maintenance.json_bytes(dict(version=14, id=request_id, operation=dict(hello={}))) + b'\n')
                self.assertTrue(entered.wait(timeout=1))
                time.sleep(.55)
                self.assertTrue(thread.is_alive())
                release.set()
                with local.makefile('rb') as reader:
                    self.assertEqual(json.loads(reader.readline())['id'], request_id)
            finally:
                release.set()
                local.close()
                thread.join(timeout=2)
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
