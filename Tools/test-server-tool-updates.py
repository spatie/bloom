#!/usr/bin/env python3
"""Exercise the exact SSH helper without modifying real tools or using the network."""
import contextlib
import fcntl
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

source = pathlib.Path(__file__).resolve().parents[1] / 'Sources/BloomCore/Server/ServerToolUpdates+Script.swift'
script = source.read_text().split('#"""\n', 1)[1].rsplit('\n"""', 1)[0]
helper = types.ModuleType('tool_updates')
exec(compile(script, str(source), 'exec'), helper.__dict__)


class ToolUpdatesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = pathlib.Path(self.temp.name).resolve()
        self.home.chmod(0o700)
        (self.home / '.local/bin').mkdir(parents=True)

    def npm(self, tool='codex'):
        root = self.home / '.local/lib/node_modules' / helper.PACKAGES[tool]
        (root / 'bin').mkdir(parents=True)
        (root / 'package.json').write_text(json.dumps({'name': helper.PACKAGES[tool]}))
        target = root / 'bin/cli.js'
        target.write_text('#!/usr/bin/env node\n')
        target.chmod(0o700)
        launcher = self.home / '.local/bin' / tool
        launcher.symlink_to(target)
        return launcher, target

    def inspect(self, tool='codex'):
        with mock.patch.object(helper, 'run', return_value=(0, 'codex-cli 1.2.3')):
            return helper.installation(tool, self.home)

    def test_recognises_user_npm_installation(self):
        launcher, _ = self.npm()
        value = self.inspect()
        self.assertEqual(value['method'], 'npm')
        self.assertEqual(value['path'], str(launcher))
        self.assertEqual(value['version'], 'codex-cli 1.2.3')

    def test_recognises_native_claude(self):
        target = self.home / '.local/share/claude/versions/2.1.0'
        target.parent.mkdir(parents=True)
        target.write_text('binary')
        target.chmod(0o700)
        (self.home / '.local/bin/claude').symlink_to(target)
        self.assertEqual(self.inspect('claude')['method'], 'native')

    def test_never_overwrites_system_installation(self):
        with mock.patch.object(helper.shutil, 'which', return_value='/usr/bin/codex'), \
             mock.patch.object(helper.pathlib.Path, 'resolve', return_value=pathlib.Path('/usr/bin/codex')), \
             mock.patch.object(helper, 'system_owned', return_value=False), \
             mock.patch.object(helper, 'run') as run:
            self.assertIsNone(helper.installation('codex', self.home)['method'])
            run.assert_not_called()

    def test_system_version_is_read_only(self):
        value = dict(version=None, method=None)
        with mock.patch.object(helper, 'system_owned', return_value=True), \
             mock.patch.object(helper, 'run', return_value=(0, 'codex-cli 0.149.0')) as run:
            result = helper.external_version(value, pathlib.Path('/usr/bin/codex'), pathlib.Path('/usr/lib/codex.js'), self.home)
        self.assertEqual(result['version'], 'codex-cli 0.149.0')
        self.assertIsNone(result['method'])
        self.assertEqual(run.call_args.args[0], ['/usr/bin/codex', '--version'])

    def test_refuses_custom_launcher(self):
        launcher = self.home / '.local/bin/codex'
        launcher.write_text('#!/bin/sh\n')
        launcher.chmod(0o700)
        self.assertIsNone(self.inspect()['method'])

    def test_refuses_package_name_mismatch(self):
        _, target = self.npm()
        (target.parent.parent / 'package.json').write_text('{"name":"other"}')
        self.assertIsNone(self.inspect()['method'])

    def test_refuses_writable_parent(self):
        self.npm()
        (self.home / '.local').chmod(0o777)
        self.assertIsNone(self.inspect()['method'])

    def test_refuses_symlink_escape(self):
        launcher, target = self.npm()
        launcher.unlink()
        launcher.symlink_to('/usr/bin/true')
        self.assertIsNone(self.inspect()['method'])

    def test_refuses_version_check_failure(self):
        self.npm()
        with mock.patch.object(helper, 'run', return_value=(1, 'failed')):
            self.assertIsNone(helper.installation('codex', self.home)['method'])

    def test_detects_running_agent(self):
        proc = self.home / 'proc/123'
        proc.mkdir(parents=True)
        (proc / 'cmdline').write_bytes(b'/home/bloom/.local/bin/codex\0app-server\0')
        self.assertTrue(helper.active_agents(self.home, proc.parent))

    def test_active_agent_prevents_update(self):
        self.npm()
        with mock.patch.object(helper, 'installation', return_value=dict(method='npm')), \
             mock.patch.object(helper, 'active_agents', return_value=True), \
             mock.patch.object(helper, 'run') as run:
            with self.assertRaisesRegex(helper.Refusal, 'agent is running'):
                helper.update('codex', self.home)
            run.assert_not_called()

    def test_update_lock_prevents_overlap(self):
        lock = self.home / '.local/.bloom-tool-update.lock'
        with lock.open('w') as handle:
            lock.chmod(0o600)
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(helper.Refusal, 'already running'):
                helper.update('codex', self.home)

    def test_lock_symlink_is_rejected(self):
        target = self.home / 'unrelated'
        target.write_text('keep')
        (self.home / '.local/.bloom-tool-update.lock').symlink_to(target)
        with self.assertRaises(OSError):
            helper.update('codex', self.home)
        self.assertEqual(target.read_text(), 'keep')

    def test_npm_uses_fixed_package_registry_and_prefix(self):
        self.npm()
        value = dict(method='npm', version='1.2.3')
        with mock.patch.object(helper, 'installation', return_value=value), \
             mock.patch.object(helper, 'active_agents', return_value=False), \
             mock.patch.object(helper.shutil, 'which', return_value='/usr/bin/npm'), \
             mock.patch.object(helper, 'run', return_value=(0, '')) as run, \
             contextlib.redirect_stdout(io.StringIO()):
            helper.update('codex', self.home)
            self.assertEqual(run.call_args.args[0], ['/usr/bin/npm', 'install', '--global', '--prefix',
                str(self.home / '.local'), '--registry=https://registry.npmjs.org', '--no-audit', '--no-fund', '@openai/codex@latest'])

    def test_native_update_keeps_vendor_channel(self):
        value = dict(method='native', path=str(self.home / '.local/bin/claude'), version='2.1.0')
        with mock.patch.object(helper, 'installation', return_value=value), \
             mock.patch.object(helper, 'active_agents', return_value=False), \
             mock.patch.object(helper, 'run', return_value=(0, '')) as run, \
             contextlib.redirect_stdout(io.StringIO()):
            helper.update('claude', self.home)
            self.assertEqual(run.call_args.args[0], [value['path'], 'update'])

    def test_failed_update_emits_error_without_false_completion(self):
        self.npm()
        output = io.StringIO()
        with mock.patch.object(helper, 'installation', return_value=dict(method='npm')), \
             mock.patch.object(helper, 'active_agents', return_value=False), \
             mock.patch.object(helper.shutil, 'which', return_value='/usr/bin/npm'), \
             mock.patch.object(helper, 'run', return_value=(42, 'download failed')), \
             contextlib.redirect_stdout(output):
            helper.update('codex', self.home)
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(events[-1]['event'], 'error')
        self.assertEqual(events[-1]['exitStatus'], 42)
        self.assertNotIn('complete', [event['event'] for event in events])

    def test_command_environment_excludes_credentials_and_npm_overrides(self):
        with mock.patch.dict(os.environ, {'OPENAI_API_KEY': 'secret', 'NPM_CONFIG_REGISTRY': 'http://bad'}):
            environment = helper.environment(self.home)
        self.assertNotIn('OPENAI_API_KEY', environment)
        self.assertNotIn('NPM_CONFIG_REGISTRY', environment)
        self.assertEqual(environment['NPM_CONFIG_USERCONFIG'], '/dev/null')

    def test_root_is_refused(self):
        with mock.patch.object(helper.sys, 'platform', 'linux'), mock.patch.object(helper.os, 'getuid', return_value=0):
            with self.assertRaisesRegex(helper.Refusal, 'unprivileged'):
                helper.main()

    def test_process_output_is_bounded(self):
        status, output = helper.run([sys.executable, '-c', "print('x' * 100000)"], self.home)
        self.assertEqual(status, 0)
        self.assertLessEqual(len(output), 65536)

    def test_hung_command_is_terminated(self):
        with self.assertRaisesRegex(helper.Refusal, 'timed out'):
            helper.run([sys.executable, '-c', 'import time; time.sleep(10)'], self.home, timeout=.05)


if __name__ == '__main__':
    unittest.main()
