#!/usr/bin/env python3
"""Real local child processes verify streaming, redaction and process-group cleanup."""
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from bloom_install_process import InstallProcessFailure, install_command_label, install_exception_details, stream_install_command


class InstallProcessTests(unittest.TestCase):
    def test_output_is_streamed_before_child_can_finish(self):
        with tempfile.TemporaryDirectory() as directory:
            gate = pathlib.Path(directory) / "continue"
            code = "import pathlib,time; print('waiting for acknowledgement',flush=True); p=pathlib.Path(__import__('sys').argv[1]);\nwhile not p.exists(): time.sleep(.01)\nprint('finished',flush=True)"
            lines = []
            def output(line):
                lines.append(line)
                if line == 'waiting for acknowledgement':
                    gate.write_text('continue')
            result = stream_install_command([sys.executable, '-c', code, str(gate)], timeout=3, output=output)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(lines, ['waiting for acknowledgement', 'finished'])

    def test_output_and_failure_tail_redact_credentials_keys_and_urls(self):
        content = '\n'.join(['token=short-secret', 'password: hidden-password', '--password hidden-option',
            '{"api_key":"hidden-json"}', 'Authorization: Bearer hidden-auth', 'https://user:pass@example.test/private?token=hidden',
            'ghp_hiddenvalue', 'sk-hiddenapikey', 'ssh-ed25519 AAAABBBB comment',
            '-----BEGIN OPENSSH PRIVATE KEY-----', 'very-short-key-material', '-----END OPENSSH PRIVATE KEY-----',
            '\x1b[31mDone\x1b[0m'])
        lines = []
        result = stream_install_command([sys.executable, '-c', 'import sys; print(sys.argv[1]);sys.exit(7)', content], timeout=3, output=lines.append)
        visible = json.dumps([lines, result.details, result.command])
        for secret in ['short-secret', 'hidden-password', 'hidden-option', 'hidden-json', 'hidden-auth', 'user:pass',
                       'ghp_hiddenvalue', 'sk-hiddenapikey', 'AAAABBBB', 'very-short-key-material']:
            self.assertNotIn(secret, visible)
        self.assertEqual(result.returncode, 7)
        self.assertIn('https://example.test/private', visible)
        self.assertIn('Done', visible)
        self.assertNotIn('-c', result.command)

    def test_safe_package_command_and_repository_locations_remain_diagnostic(self):
        command = ['apt-get', 'install', '-y', '--no-remove', 'nodejs', 'npm']
        self.assertEqual(install_command_label(command), 'apt-get install -y --no-remove nodejs npm')
        self.assertEqual(install_command_label(['systemctl', 'start', 'bloom-server.service']), 'systemctl start bloom-server.service')
        self.assertEqual(install_command_label(['python3', '-c', 'private inline script']), 'python3')
        lines = []
        value = 'HTTP 404 https://user:private-password@mirror.example:8443/ubuntu/dists/noble?token=private-query#private-fragment'
        result = stream_install_command([sys.executable, '-c', 'import sys;print(sys.argv[1]);sys.exit(1)', value], timeout=3, output=lines.append)
        self.assertIn('https://mirror.example:8443/ubuntu/dists/noble', result.details)
        self.assertNotIn('private-', result.details)
        self.assertNotIn('user:', result.details)

    def test_generic_subprocess_exceptions_never_reveal_inline_scripts(self):
        args = ['python3', '-c', 'private inline script and credentials']
        for error in (subprocess.TimeoutExpired(args, 3), subprocess.CalledProcessError(4, args)):
            detail = install_exception_details(error)
            self.assertIn('python3', detail)
            self.assertNotIn('private inline', detail)
            self.assertNotIn('-c', detail)

    def test_output_memory_and_events_are_bounded_but_keep_last_failure(self):
        lines = []
        code = "import sys; print('x'*2000000);\nfor i in range(2000): print('line '+str(i)+' '+'y'*100)\nprint('Final dependency failure');sys.exit(8)"
        result = stream_install_command([sys.executable, '-c', code], timeout=5, output=lines.append,
                                        event_limit=10, capture_limit=1024, detail_limit=4096)
        self.assertLessEqual(len(lines), 13)
        self.assertLessEqual(len(result.stdout), 1024)
        self.assertLessEqual(len(result.details), 4096)
        self.assertTrue(result.details.endswith('Final dependency failure'))
        self.assertIn('oversized output line omitted', lines[0])

    def test_late_progress_after_large_burst_arrives_before_child_finishes(self):
        with tempfile.TemporaryDirectory() as directory:
            gate = pathlib.Path(directory) / 'continue'
            code = "import pathlib,time,sys; p=pathlib.Path(sys.argv[1]);\nfor i in range(520): print('burst '+str(i),flush=True)\ntime.sleep(.15);print('late progress',flush=True)\nwhile not p.exists(): time.sleep(.01)\nprint('finished',flush=True)"
            lines = []
            def output(line):
                lines.append(line)
                if line == 'late progress':
                    gate.write_text('continue')
            result = stream_install_command([sys.executable, '-c', code, str(gate)], timeout=3, output=output)
            self.assertEqual(result.returncode, 0)
            self.assertIn('late progress', lines)
            self.assertIn('High output volume; showing the latest progress updates.', lines)
            self.assertEqual(lines[-1], 'finished')

    def test_both_large_pipes_drain_without_deadlock(self):
        code = "import os;\nfor i in range(40): os.write(1,b'o'*65536);os.write(2,b'e'*65536)"
        result = stream_install_command([sys.executable, '-c', code], timeout=5, capture_limit=2048)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stdout), 2048)
        self.assertLessEqual(len(result.details), 8192)

    def test_timeout_kills_descendant_that_keeps_pipes_open(self):
        with tempfile.TemporaryDirectory() as directory:
            heartbeat = pathlib.Path(directory) / 'heartbeat'
            code = "import os,pathlib,signal,time; p=pathlib.Path(__import__('sys').argv[1]); child=os.fork();\nif child==0:\n signal.signal(signal.SIGTERM,signal.SIG_IGN)\n while True: p.write_text(str(time.monotonic()));time.sleep(.01)\nelse: print('child started',flush=True);time.sleep(60)"
            start = time.monotonic()
            with self.assertRaises(InstallProcessFailure) as caught:
                stream_install_command([sys.executable, '-c', code, str(heartbeat)], timeout=.3)
            self.assertEqual(caught.exception.code, 'command_timeout')
            self.assertLess(time.monotonic() - start, 2)
            last = heartbeat.read_text()
            time.sleep(.1)
            self.assertEqual(heartbeat.read_text(), last)

    def test_termination_signal_cleans_up_and_reports_cancellation(self):
        with self.assertRaises(InstallProcessFailure) as caught:
            stream_install_command([sys.executable, '-c', 'import os,signal,time;os.kill(os.getppid(),signal.SIGTERM);time.sleep(60)'], timeout=3)
        self.assertEqual(caught.exception.code, 'cancelled')


if __name__ == '__main__':
    unittest.main()
