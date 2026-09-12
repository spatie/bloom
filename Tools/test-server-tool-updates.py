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

    def test_malformed_package_metadata_does_not_abort_inspection(self):
        _, target = self.npm()
        metadata = target.parent.parent / 'package.json'
        for value in ['[]', 'null', '"codex"', '{invalid', '[' * 1500 + ']' * 1500]:
            with self.subTest(value=value):
                metadata.write_text(value)
                with mock.patch.object(helper, 'run') as run:
                    result = helper.installation('codex', self.home)
                self.assertIsNone(result['method'])
                self.assertIn('metadata', result['detail'])
                run.assert_not_called()

    def test_oversized_package_metadata_is_not_an_update_candidate(self):
        _, target = self.npm()
        metadata = target.parent.parent / 'package.json'
        metadata.write_text(json.dumps({'name': helper.PACKAGES['codex'], 'padding': 'x' * 65536}))
        with mock.patch.object(helper, 'run', return_value=(0, 'codex-cli 1.2.3')) as run:
            result = helper.installation('codex', self.home)
        self.assertIsNone(result['method'])
        run.assert_not_called()

    def test_fifo_package_metadata_cannot_hang_remote_inspection(self):
        _, target = self.npm()
        metadata = target.parent.parent / 'package.json'
        metadata.unlink()
        os.mkfifo(metadata, 0o600)
        # Run the exact helper in another process so a regression fails on the deadline,
        # rather than blocking the test runner on a FIFO with no writer.
        invocation = script + "\nprint(json.dumps(installation('codex', pathlib.Path(sys.argv[1]))))"
        result = subprocess.run([sys.executable, '-c', "__name__ = 'test_helper'\n" + invocation, str(self.home)],
            capture_output=True, text=True, timeout=2, check=True)
        value = json.loads(result.stdout)
        self.assertIsNone(value['method'])
        self.assertIn('metadata', value['detail'])

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

    def test_helper_inspection_is_not_mistaken_for_a_running_agent(self):
        proc = self.home / 'proc/123'
        proc.mkdir(parents=True)
        (proc / 'cmdline').write_bytes(b'python3\0-c\0' + script.encode() + b'\0inspect\0')
        (proc / 'exe').symlink_to(sys.executable)
        self.assertFalse(helper.active_agents(self.home, proc.parent))

    def test_detects_node_agent_package_entry_point(self):
        proc = self.home / 'proc/123'
        proc.mkdir(parents=True)
        entry = str(self.home / '.local/lib/node_modules/@anthropic-ai/claude-code/cli.js')
        (proc / 'cmdline').write_bytes(b'node\0' + entry.encode() + b'\0--print\0')
        self.assertTrue(helper.active_agents(self.home, proc.parent))

    def test_detects_relative_node_agent_package_entry_points(self):
        proc = self.home / 'proc/123'
        proc.mkdir(parents=True)
        (proc / 'exe').symlink_to('/usr/bin/node')
        for entry in ['.local/lib/node_modules/@anthropic-ai/claude-code/cli.js',
                      './node_modules/@anthropic-ai/claude-code/cli.js',
                      '../node_modules/@openai/codex/bin/entry.js',
                      'node_modules/@openai/codex/bin/entry.js']:
            with self.subTest(entry=entry):
                (proc / 'cmdline').write_bytes(b'node\0' + entry.encode() + b'\0--print\0')
                self.assertTrue(helper.active_agents(self.home, proc.parent))

    def test_inline_interpreter_source_is_not_an_agent_entry_point(self):
        proc = self.home / 'proc/123'
        proc.mkdir(parents=True)
        (proc / 'exe').symlink_to(sys.executable)
        source = b"print('/node_modules/@anthropic-ai/claude-code/cli.js')"
        for interpreter, option in [(b'python3', b'-c'), (b'node', b'-e'),
                                    (b'node', b'--eval'), (b'node', b'--print'),
                                    (b'bash', b'-lc')]:
            with self.subTest(interpreter=interpreter, option=option):
                (proc / 'cmdline').write_bytes(interpreter + b'\0' + option + b'\0' + source + b'\0')
                self.assertFalse(helper.active_agents(self.home, proc.parent))
        # A prompt or expression can be exactly a tool name too.
        (proc / 'cmdline').write_bytes(b'python3\0-c\0claude\0')
        self.assertFalse(helper.active_agents(self.home, proc.parent))

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
