#!/usr/bin/env python3
"""Exercise the real packaged runtime's supervisor channel using only isolated data."""
import argparse
import json
import os
import pathlib
import re
import signal
import socket
import subprocess
import tempfile
import uuid


def receive(source):
    value = source.readline(65537)
    if not value or len(value) > 65536 or not value.endswith(b'\n'):
        raise RuntimeError('Runtime did not return a bounded supervisor message')
    return json.loads(value)


class Runtime:
    def __init__(self, binary, data, trial=False):
        self.parent, inherited = socket.socketpair()
        self.parent.settimeout(15)
        self.source = self.parent.makefile('rb')
        self.trial = str(uuid.uuid4()) if trial else None
        self.log = tempfile.TemporaryFile()
        self.data = data
        environment = dict(os.environ, BLOOM_MAINTENANCE_FD=str(inherited.fileno()))
        environment.pop('BLOOM_MAINTENANCE_TRIAL', None)
        if self.trial:
            environment['BLOOM_MAINTENANCE_TRIAL'] = self.trial
        self.process = subprocess.Popen([str(binary), 'serve', '--data-dir', str(data)],
            env=environment, stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log,
            pass_fds=(inherited.fileno(),), start_new_session=True)
        inherited.close()

    def started(self):
        value = receive(self.source)
        expected = 'prepared' if self.trial else 'ready'
        assert value.get('event') == expected, value
        if self.trial:
            assert value.get('jobID') == self.trial, value
        # Foundation and realpath canonicalise /private/var differently on macOS. Use the
        # endpoint announced by this isolated child rather than guessing its canonical path.
        log = os.pread(self.log.fileno(), 65536, 0).decode('utf-8', 'replace')
        match = re.search(r'Bloom server listening at (/tmp/bloom-bridge-[0-9a-f]{8}\.sock)', log)
        assert match, 'The isolated runtime did not announce its socket'
        self.socket_path = match[1]

    def control(self, action):
        request_id = str(uuid.uuid4())
        self.parent.sendall(json.dumps(dict(id=request_id, action=action)).encode() + b'\n')
        value = receive(self.source)
        assert str(uuid.UUID(value.get('id'))) == request_id, value
        return value

    def rpc(self, operation):
        request_id = str(uuid.uuid4())
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(10)
            connection.connect(self.socket_path)
            connection.sendall(json.dumps(dict(version=14, id=request_id, operation=operation)).encode() + b'\n')
            with connection.makefile('rb') as source:
                value = receive(source)
        assert str(uuid.UUID(value.get('id'))) == request_id, value
        return value['result']

    def detach_supervisor(self):
        self.source.close()
        self.parent.close()
        self.process.wait(timeout=15)
        assert self.process.returncode == 0, 'Losing the supervisor did not stop the runtime cleanly'

    def close(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
                raise
        self.source.close()
        self.parent.close()
        self.log.close()


def verify(binary):
    with tempfile.TemporaryDirectory(prefix='bloom-maintenance-runtime-') as temporary:
        data = pathlib.Path(temporary).resolve() / 'data'
        data.mkdir(mode=0o700)
        normal = Runtime(binary, data)
        try:
            normal.started()
            assert 'catalogue' in normal.rpc({'catalogue': {}})
            status = normal.control('quiesce')
            assert status['ready'] and not status['busy'], status
            denied = normal.rpc({'renameSession': {'sessionID': str(uuid.uuid4()), 'title': 'Unaccepted work'}})
            assert 'preparing an update' in denied['failure']['_0'], denied
            assert 'catalogue' in normal.rpc({'catalogue': {}})
            assert normal.control('resume')['ready']
        finally:
            normal.close()
        trial = Runtime(binary, data, trial=True)
        try:
            trial.started()
            assert 'failure' in trial.rpc({'catalogue': {}})
            assert not trial.control('resume')['ready']
            assert trial.control('commit')['ready']
            assert 'catalogue' in trial.rpc({'catalogue': {}})
            assert trial.control('commit')['ready']
        finally:
            trial.close()
        orphan = Runtime(binary, data, trial=True)
        try:
            orphan.started()
            orphan.detach_supervisor()
        finally:
            orphan.close()
    print('Packaged maintenance runtime: admission, trial commit and supervisor-loss checks passed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=pathlib.Path)
    verify(parser.parse_args().binary.resolve())
