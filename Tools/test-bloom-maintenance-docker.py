#!/usr/bin/env python3
"""Fixture-only Docker maintenance checks. Never runs APT, Docker, systemd or root mutations."""
import importlib.util
import json
from pathlib import Path
import stat
import signal
import sys
from types import SimpleNamespace
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('bloom_maintenance_docker', Path(__file__).with_name('bloom_maintenance_docker.py'))
docker = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = docker
spec.loader.exec_module(docker)


class Runner:
    def __init__(self):
        self.installed = dict.fromkeys(docker.PACKAGES, '1.0-1')
        self.candidates = dict(self.installed, **{'docker.io': '2.0-1', 'docker-compose-v2': '2.1-1'})
        self.fingerprint = 'a' * 64
        self.calls = []
        self.extra_simulation = ''
        self.audit = ''
        self.locked = False
        self.owner = 'docker.io'
        self.rootless = True
        self.overrides = ''

    def __call__(self, arguments, **options):
        self.calls.append((arguments, options))
        command = arguments[0]
        if command == '/usr/bin/python3':
            assert options['account'].pw_uid == 995
            return docker.CommandResult(0, json.dumps(dict(fingerprint=self.fingerprint)))
        if command == '/usr/bin/systemctl':
            assert options['account'].pw_uid == 995
            return docker.CommandResult(0, 'LoadState=loaded\nFragmentPath=/home/bloom/.config/systemd/user/docker.service\nDropInPaths=' + self.overrides + '\n')
        if command == '/usr/bin/dpkg-query' and '--show' in arguments:
            return docker.CommandResult(0, ''.join(f'{name}\tinstalled\t{version}\n' for name, version in self.installed.items()))
        if command == '/usr/bin/dpkg-query' and '--search' in arguments:
            return docker.CommandResult(0, f'{self.owner}: /usr/bin/docker\nrootlesskit: /usr/bin/rootlesskit\ndocker.io: /usr/share/docker.io/contrib/dockerd-rootless.sh\n')
        if command == '/usr/bin/apt-cache':
            return docker.CommandResult(0, ''.join(f'{name}:\n  Installed: {self.installed[name]}\n  Candidate: {version}\n' for name, version in self.candidates.items()))
        if command == '/usr/bin/dpkg':
            if '--audit' in arguments:
                return docker.CommandResult(0, self.audit)
            return docker.CommandResult(0 if arguments[2] > arguments[4] else 1, '')
        if command == '/usr/bin/apt-get':
            if self.locked:
                return docker.CommandResult(100, 'E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 42.')
            pins = dict(arg.split('=', 1) for arg in arguments if '=' in arg and arg.split('=', 1)[0] in docker.PACKAGES)
            if '--simulate' in arguments:
                return docker.CommandResult(0, ''.join(f'Inst {name} [{self.installed[name]}] ({version} Ubuntu [amd64])\nConf {name} ({version} Ubuntu [amd64])\n' for name, version in pins.items()) + self.extra_simulation)
            assert options['account'] is None
            self.installed.update(pins)
            if options['log']:
                options['log']('Installing reviewed packages')
            return docker.CommandResult(0, '')
        if command == '/usr/bin/docker':
            assert options['account'].pw_uid == 995
            assert arguments[1:3] == ('--host', 'unix:///run/user/995/docker.sock')
            return docker.CommandResult(0, json.dumps(dict(ServerVersion='2.0', DockerRootDir='/home/bloom/bloom/docker/data',
                                                           SecurityOptions=['name=rootless'] if self.rootless else [])))
        raise AssertionError('Unexpected command: ' + str(arguments))


class DockerTests(unittest.TestCase):
    def setUp(self):
        self.account = SimpleNamespace(pw_uid=995, pw_gid=995, pw_dir='/home/bloom', pw_name='bloom')
        self.config = dict(uid=995, gid=995, service_home='/home/bloom')
        self.runner = Runner()
        patch = mock.patch.object(docker, '_validate_host', return_value=self.account)
        patch.start(); self.addCleanup(patch.stop)
        state = mock.patch.object(docker, '_apt_state', return_value='c' * 64)
        self.state = state.start(); self.addCleanup(state.stop)

    def plan(self):
        return docker.prepare(self.config, runner=self.runner)

    def test_exact_reviewed_versions_only_and_restart_drops_privileges(self):
        plan = self.plan()
        logs = []
        result = docker.apply(self.config, plan, logs.append, runner=self.runner)
        installs = [(args, options) for args, options in self.runner.calls if args[0] == '/usr/bin/apt-get' and '--simulate' not in args]
        self.assertEqual(len(installs), 1)
        self.assertEqual(installs[0][0], docker._apt_arguments(plan['updates'], state='c' * 64))
        self.assertIn('--only-upgrade', installs[0][0]); self.assertIn('--no-remove', installs[0][0])
        self.assertIn('--no-install-recommends', installs[0][0])
        self.assertEqual(installs[0][1]['timeout'], 1800)
        self.assertEqual(result['version'], '2.0-1')
        self.assertTrue(any('verified' in line for line in logs))
        for args, _ in self.runner.calls:
            self.assertFalse(set(args) & {'autoremove', 'prune', 'upgrade', 'dist-upgrade', 'remove', 'purge'})

    def test_plan_explains_restarts_and_no_automatic_rollback(self):
        plan = self.plan()
        self.assertIn('containers may restart', plan['summary'])
        self.assertIn('rollback is not available', plan['summary'])
        self.assertEqual(set(plan['updates']), {'docker.io', 'docker-compose-v2'})

    def test_up_to_date_still_shows_installed_and_available_version(self):
        self.runner.candidates = dict(self.runner.installed)
        component = docker.inspect(self.config, runner=self.runner)
        self.assertFalse(component['canUpdate'])
        self.assertEqual(component['installedVersion'], '1.0-1')
        self.assertEqual(component['availableVersion'], '1.0-1')

    def test_changed_installed_candidate_or_managed_configuration_refuses_before_install(self):
        for attribute, change in [('installed', '3.0-1'), ('candidates', '3.0-1'), ('fingerprint', 'b' * 64)]:
            with self.subTest(attribute=attribute):
                self.runner = Runner(); plan = self.plan()
                if attribute == 'fingerprint': self.runner.fingerprint = change
                else: getattr(self.runner, attribute)['docker.io'] = change
                with self.assertRaises(docker.DockerMaintenanceError):
                    docker.apply(self.config, plan, lambda _: None, runner=self.runner)
                self.assertFalse(any(args[0] == '/usr/bin/apt-get' and '--simulate' not in args for args, _ in self.runner.calls))

    def test_unreviewed_package_version_and_account_cannot_enter_root_argv(self):
        for mutation in (lambda plan: plan['updates'].update(curl='1.0'),
                         lambda plan: plan['updates'].update({'docker.io': '2.0; touch /tmp/no'}),
                         lambda plan: plan['account'].update(uid=0),
                         lambda plan: plan['updates'].update({'docker.io': '0.1'})):
            with self.subTest(mutation=mutation):
                plan = self.plan(); mutation(plan)
                with self.assertRaises(docker.DockerMaintenanceError):
                    docker.apply(self.config, plan, lambda _: None, runner=self.runner)
        self.assertFalse(any(args[0] == '/usr/bin/apt-get' and '--simulate' not in args for args, _ in self.runner.calls))

    def test_dependency_upgrades_new_installs_removals_and_unrelated_configuration_refused(self):
        for extra in ('Inst libc6 [1.0] (2.0 Ubuntu [amd64])\n', 'Inst curl (2.0 Ubuntu [amd64])\n',
                      'Remv unrelated [1.0]\n', 'Conf unrelated (1.0 Ubuntu [amd64])\n'):
            with self.subTest(extra=extra):
                self.runner.extra_simulation = extra
                with self.assertRaises(docker.DockerMaintenanceError): self.plan()

    def test_unfinished_dpkg_work_refuses_simulation(self):
        self.runner.audit = 'An unrelated package is unpacked but not configured.'
        with self.assertRaisesRegex(docker.DockerMaintenanceError, 'unfinished package work'): self.plan()
        self.assertFalse(any(args[0] == '/usr/bin/apt-get' for args, _ in self.runner.calls))

    def test_external_package_or_systemd_override_is_not_managed(self):
        self.runner.owner = 'docker-ce-cli'
        self.assertFalse(docker.inspect(self.config, runner=self.runner)['canUpdate'])
        self.runner.owner = 'docker.io'; self.runner.overrides = '/home/bloom/other.conf'
        self.assertFalse(docker.inspect(self.config, runner=self.runner)['canUpdate'])

    def test_package_lock_error_is_copyable_and_never_kills_another_process(self):
        plan = self.plan(); self.runner.locked = True
        with self.assertRaises(docker.DockerMaintenanceError) as error:
            docker.apply(self.config, plan, lambda _: None, runner=self.runner)
        self.assertEqual(error.exception.code, 'package_lock')
        self.assertIn('process 42', str(error.exception))
        self.assertIn('never removes package locks', error.exception.recovery)

    def test_rootful_daemon_verification_refused_after_update_without_data_deletion(self):
        plan = self.plan(); self.runner.rootless = False
        with self.assertRaises(docker.DockerMaintenanceError) as error:
            docker.apply(self.config, plan, lambda _: None, runner=self.runner)
        self.assertEqual(error.exception.code, 'verification_failed')
        self.assertIn('no rollback', error.exception.recovery)

    def test_simulation_is_checked_again_after_confirmation(self):
        plan = self.plan(); self.runner.extra_simulation = 'Remv changed-dependency [1.0]\n'
        with self.assertRaises(docker.DockerMaintenanceError):
            docker.apply(self.config, plan, lambda _: None, runner=self.runner)
        self.assertFalse(any(args[0] == '/usr/bin/apt-get' and '--simulate' not in args for args, _ in self.runner.calls))

    def test_log_redaction_removes_repository_credentials(self):
        line = docker._safe_line('Get: https://username:password@example.com/packages?token=secret authorization=verysecret')
        for secret in ('username', 'password', 'token=secret', 'verysecret'):
            self.assertNotIn(secret, line)

    def test_unicode_log_lines_are_bounded_in_bytes(self):
        self.assertLessEqual(len(docker._safe_line('界' * 3000).encode()), 3000)

    def test_timed_out_group_is_signalled_before_leader_is_reaped(self):
        actions = []
        process = SimpleNamespace(pid=234, wait=lambda **kwargs: actions.append('reap'))
        with mock.patch.object(docker.os, 'killpg', side_effect=lambda pid, sig: actions.append((pid, sig))), mock.patch.object(docker.time, 'sleep'):
            docker._stop_command_group(process)
        self.assertEqual(actions, [(234, signal.SIGTERM), (234, signal.SIGKILL), 'reap'])

    def test_package_state_change_during_simulation_refuses_install(self):
        plan = self.plan()
        self.state.side_effect = ['c' * 64, 'd' * 64]
        with self.assertRaisesRegex(docker.DockerMaintenanceError, 'changed while'):
            docker.apply(self.config, plan, lambda _: None, runner=self.runner)
        self.assertFalse(any(args[0] == '/usr/bin/apt-get' and '--simulate' not in args for args, _ in self.runner.calls))

    def test_pre_install_guard_rechecks_state_before_any_dpkg_mutation(self):
        with mock.patch.object(docker.os, 'geteuid', return_value=0):
            docker.verify_apt_state('c' * 64)
            self.state.return_value = 'd' * 64
            with self.assertRaisesRegex(docker.DockerMaintenanceError, 'No Docker packages were installed'):
                docker.verify_apt_state('c' * 64)


class TrustedPathTests(unittest.TestCase):
    def test_apt_directory_symlink_does_not_hide_untrusted_configuration_children(self):
        def protect(path, **kwargs):
            if str(path) == '/root-config/untrusted.conf':
                raise docker.DockerMaintenanceError('unsafe_path', 'Untrusted configuration')
            return Path('/root-config') if str(path) == '/etc/apt/apt.conf.d' else Path(path)
        def entries(path):
            return iter([Path('/etc/apt/apt.conf.d')] if str(path) == '/etc/apt' else [Path('/root-config/untrusted.conf')])
        with mock.patch.object(docker, '_protected', side_effect=protect), mock.patch.object(Path, 'is_dir', lambda path: str(path) != '/root-config/untrusted.conf'), mock.patch.object(Path, 'iterdir', entries):
            with self.assertRaisesRegex(docker.DockerMaintenanceError, 'Untrusted configuration'):
                docker._apt_configuration_paths()

    def test_root_owned_system_symlink_is_allowed_but_user_target_is_not(self):
        def metadata(path):
            mode = stat.S_IFLNK | 0o777 if str(path) == '/usr/bin/python3' else stat.S_IFREG | 0o755 if str(path) == '/usr/bin/python3.14' else stat.S_IFDIR | 0o755
            return SimpleNamespace(st_uid=0, st_mode=mode)
        with mock.patch.object(docker.os, 'readlink', return_value='python3.14'), mock.patch.object(Path, 'lstat', metadata):
            docker._protected('/usr/bin/python3')
        def unsafe(path):
            value = metadata(path)
            if str(path) == '/usr/bin/python3.14': value.st_uid = 995
            return value
        with mock.patch.object(docker.os, 'readlink', return_value='python3.14'), mock.patch.object(Path, 'lstat', unsafe):
            with self.assertRaises(docker.DockerMaintenanceError): docker._protected('/usr/bin/python3')

    def test_intermediate_user_owned_symlink_is_rejected_even_with_root_owned_final_target(self):
        def metadata(path):
            if str(path) == '/usr/bin/python3': return SimpleNamespace(st_uid=0, st_mode=stat.S_IFLNK | 0o777)
            if str(path) == '/untrusted/link': return SimpleNamespace(st_uid=995, st_mode=stat.S_IFLNK | 0o777)
            if str(path) == '/usr/bin/python3.14': return SimpleNamespace(st_uid=0, st_mode=stat.S_IFREG | 0o755)
            return SimpleNamespace(st_uid=0, st_mode=stat.S_IFDIR | 0o755)
        with mock.patch.object(docker.os, 'readlink', side_effect=lambda path: '/untrusted/link' if str(path) == '/usr/bin/python3' else '/usr/bin/python3.14'), mock.patch.object(Path, 'lstat', metadata):
            with self.assertRaises(docker.DockerMaintenanceError): docker._protected('/usr/bin/python3')


if __name__ == '__main__':
    unittest.main()
