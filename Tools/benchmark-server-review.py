#!/usr/bin/env python3
"""Compare legacy and cached diff RPCs over real SSH, with optional added per-request latency.

Runs an isolated daemon and creates a disposable 1,000-file repository. No agent is launched.
Example: python3 Tools/benchmark-server-review.py --host user@host --binary /path/bloom-server
"""
import argparse
import json
import pathlib
import shlex
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--host', required=True)
parser.add_argument('--binary', required=True)
parser.add_argument('--identity-file')
parser.add_argument('--files', type=int, default=1000)
parser.add_argument('--opened', type=int, default=30)
parser.add_argument('--added-rtt-ms', type=float, default=100)
parser.add_argument('--output', default='/tmp/bloom-review-benchmark.json')
args = parser.parse_args()
assert 1 <= args.opened <= args.files <= 10000
ssh = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10']
if args.identity_file:
    ssh += ['-o', 'IdentityAgent=none', '-o', 'IdentitiesOnly=yes', '-i', args.identity_file]
ssh += [args.host]

def remote(arguments, **kwargs):
    return subprocess.run(ssh + [shlex.join(arguments)], check=True, text=True, capture_output=True, **kwargs)

setup = '''import tempfile,pathlib,subprocess,json,sys
root=pathlib.Path(tempfile.mkdtemp(prefix="bloom-review-benchmark-"))
repo=root/"repo"; repo.mkdir();(root/"data").mkdir(mode=0o700)
def git(*args): subprocess.run(["git","-C",str(repo),*args],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
git("init","-b","main");git("config","user.name","Bloom benchmark");git("config","user.email","benchmark@example.invalid");git("config","commit.gpgsign","false")
for n in range(int(sys.argv[1])):(repo/f"file-{n:04}.txt").write_text("before\\n"*200)
git("add",".");git("commit","-m","Base")
for n in range(int(sys.argv[1])):(repo/f"file-{n:04}.txt").write_text("after!\\n"*200)
print(json.dumps({"root":str(root),"repo":str(repo),"data":str(root/"data")}))
'''
fixture = json.loads(remote(['python3', '-', str(args.files)], input=setup).stdout)
daemon = subprocess.Popen(ssh + [shlex.join([args.binary, 'serve', '--data-dir', fixture['data']])], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
client = None
try:
    startup = []
    while True:
        line = daemon.stderr.readline()
        startup.append(line)
        if 'listening at' in line: break
        if not line: raise RuntimeError('Benchmark daemon did not start: ' + ''.join(startup))
    client = subprocess.Popen(ssh + [shlex.join([args.binary, 'connect', '--data-dir', fixture['data']])], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    def rpc(operation, delay=True):
        request = json.dumps({'version': 12, 'id': str(uuid.uuid4()), 'operation': operation}, separators=(',', ':')) + '\n'
        started = time.perf_counter()
        if delay: time.sleep(args.added_rtt_ms / 1000)
        client.stdin.write(request); client.stdin.flush()
        line = client.stdout.readline()
        if not line: raise RuntimeError('Benchmark relay disconnected')
        value = json.loads(line)['result']
        if 'failure' in value: raise RuntimeError(value['failure'])
        return value, time.perf_counter() - started, len(request.encode()) + len(line.encode())
    # Register the existing dirty checkout as a workspace in the disposable database. This
    # fixture setup uses SQLite only before any review RPC and never touches the real database.
    register = '''import sqlite3,json,sys,time
c=sqlite3.connect(sys.argv[1]+"/server.sqlite")
# Use defaults from the migrated schema, assigning only the required values.
c.execute("insert into repos(id,name,path,default_branch,created_at) values(?,?,?,?,?)",("bench-repo","Benchmark",sys.argv[2],"main",time.time()))
c.execute("insert into workspaces(id,repo_id,name,branch,path,base_branch,created_at,last_activity_at) values(?,?,?,?,?,?,?,?)",("bench-workspace","bench-repo","Benchmark","main",sys.argv[2],"main",time.time(),time.time()))
c.commit()
'''
    remote(['python3', '-', fixture['data'], fixture['repo']], input=register)
    wid = 'bench-workspace'
    measurements = {}
    def measure(label, operations):
        total_time = total_bytes = 0
        replies = []
        for op in operations:
            value, elapsed, size = rpc(op)
            total_time += elapsed; total_bytes += size; replies.append(value)
        measurements[label] = {'requests': len(replies), 'elapsed_seconds': round(total_time, 3), 'wire_bytes': total_bytes}
        print(label, measurements[label], flush=True)
        return replies
    paths = [f'file-{n:04}.txt' for n in range(args.opened)]
    legacy = [{'patch': {'workspaceID': wid, 'path': p, 'scope': 'branch'}} for p in paths]
    new = [{'reviewPatch': {'workspaceID': wid, 'path': p, 'scope': 'branch', 'knownRevision': None}} for p in paths]
    measure('legacy_open_files', legacy)
    snapshot = measure('cached_initial_list', [{'reviewSnapshot': {'workspaceID': wid, 'scope': 'branch', 'knownRevision': None, 'wait': False}}])[0]['reviewSnapshot']['_0']
    opened = measure('cached_open_files', new)
    measure('cached_repeat_files', new)
    conditional = [{'reviewPatch': {'workspaceID': wid, 'path': p, 'scope': 'branch', 'knownRevision': result['reviewPatch']['_0']['revision']}} for p, result in zip(paths, opened)]
    replies = measure('unchanged_files', conditional)
    assert all(x['reviewPatch']['_0'].get('patch') is None for x in replies)
    measure('legacy_idle_refreshes', [{'changes': {'workspaceID': wid, 'scope': 'branch'}}] * 10)
    replies = measure('cached_idle_checks', [{'reviewSnapshot': {'workspaceID': wid, 'scope': 'branch', 'knownRevision': snapshot['revision'], 'wait': False}}] * 10)
    assert all(x['reviewSnapshot']['_0'].get('files') is None for x in replies)
    changed = 'import pathlib,sys;pathlib.Path(sys.argv[1],"file-0000.txt").write_text("other!\\n"*200)'
    remote(['python3', '-c', changed, fixture['repo']])
    notification = measure('change_notification', [{'reviewSnapshot': {'workspaceID': wid, 'scope': 'branch', 'knownRevision': snapshot['revision'], 'wait': True}}])[0]['reviewSnapshot']['_0']
    assert notification.get('files') and notification['revision'] != snapshot['revision']
    result = {'transport': 'persistent SSH', 'files': args.files, 'changed_lines_per_file': 400, 'opened_files': args.opened,
              'added_latency_ms_per_request': args.added_rtt_ms, 'measurements': measurements}
    pathlib.Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
finally:
    if client:
        client.stdin.close()
        try: client.wait(timeout=10)
        except subprocess.TimeoutExpired: client.terminate(); client.wait(timeout=10)
    daemon.terminate()
    try: daemon.wait(timeout=10)
    except subprocess.TimeoutExpired: daemon.kill(); daemon.wait()
    # A dropped SSH channel is not assumed to stop a daemon. Terminate only the fixture process
    # identified by its unique data-directory argument, then remove its disposable files.
    cleanup = '''import os,pathlib,signal,sys,shutil
root=pathlib.Path(sys.argv[1]);assert root.name.startswith("bloom-review-benchmark-") and root.parent==pathlib.Path("/tmp")
for p in pathlib.Path("/proc").iterdir():
 if not p.name.isdigit():continue
 try:argv=(p/"cmdline").read_bytes().split(b"\\0")
 except OSError:continue
 if b"serve" in argv and str(root/"data").encode() in argv:os.kill(int(p.name),signal.SIGTERM)
shutil.rmtree(root)
'''
    remote(['python3', '-', fixture['root']], input=cleanup)
