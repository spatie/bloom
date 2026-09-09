"""Exercise a disposable runtime through the authenticated HTTPS gateway."""
import pathlib
import json
import ssl
import urllib.request
import urllib.error
import uuid
import subprocess
import os
root = pathlib.Path(os.environ['BLOOM_HTTPS_FIXTURE'])
context = ssl.create_default_context(cafile=str(root / 'cert.pem'))
base = 'https://control.127.0.0.1.sslip.io:19444'

def rpc(operation, id=None, expected_failure=False):
    body = {'version': 9, 'id': id or str(uuid.uuid4()), 'operation': operation}
    request = urllib.request.Request(base + '/v1/rpc', data=json.dumps(body).encode(), headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + (root / 'access-token.txt').read_text()})
    with urllib.request.urlopen(request, context=context, timeout=60) as response:
        reply = json.load(response)
    assert reply['id'].lower() == body['id'].lower()
    result = reply['result']
    if not expected_failure:
        assert 'failure' not in result, result
    return result
if __name__ == '__main__':
    remote = os.environ.get('BLOOM_HTTPS_REPOSITORY')
    repo = pathlib.Path(remote) if remote else root / 'bloom-https-fixture-repo'
    if not remote:
        repo.mkdir(exist_ok=True)
    if not remote and (not (repo / '.git').exists()):
        subprocess.run(['git', 'init', '-b', 'main', str(repo)], check=True, capture_output=True)
        (repo / 'hello.txt').write_text('Initial HTTPS fixture\n')
        subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'commit.gpgsign=false', '-c', 'user.name=Bloom fixture', '-c', 'user.email=fixture@example.com', 'commit', '-m', 'Initial fixture'], check=True, capture_output=True)
    created = rpc({'create': {'_0': {'repositoryPath': str(repo), 'name': 'HTTPS integration', 'agent': 'claudeCode', 'model': 'fixture', 'effort': 'low', 'permissionMode': 'plan'}}})['created']
    root.joinpath('created.json').write_text(json.dumps(created))
    w = created['workspace']['id']
    s = created['session']['id']
    print('PASS: workspace and conversation created over HTTPS')

    def action(a, **kwargs):
        return rpc({'workspace': {'workspaceID': w, 'action': a}}, **kwargs)
    file = rpc({'file': {'workspaceID': w, 'path': 'hello.txt'}})['file']['_0']
    changed = action({'writeFile': {'path': 'hello.txt', 'text': 'Edited over HTTPS\n', 'revision': file['revision']}})['file']['_0']
    assert changed['text'] == 'Edited over HTTPS\n'
    assert 'failure' in action({'writeFile': {'path': 'hello.txt', 'text': 'stale edit', 'revision': file['revision']}}, expected_failure=True)
    assert 'failure' in rpc({'file': {'workspaceID': w, 'path': '../outside'}}, expected_failure=True)
    assert rpc({'changes': {'workspaceID': w, 'scope': 'uncommitted'}})['changes']['_0']
    patch = rpc({'patch': {'workspaceID': w, 'path': 'hello.txt', 'scope': 'uncommitted'}})['patch']['_0']
    assert 'Edited over HTTPS' in patch
    print('PASS: file read/write, stale-write protection, path traversal refusal and Git diff')
    action({'saveNotes': {'_0': 'HTTPS note'}})
    assert action({'notes': {}})['text']['_0'] == 'HTTPS note'
    action({'rename': {'_0': 'HTTPS verified'}})
    action({'setPinned': {'_0': True}})
    c = rpc({'catalogue': {}})['catalogue']['_0']
    assert any((v['id'] == w and v['name'] == 'HTTPS verified' and v['pinned'] for v in c['workspaces']))
    print('PASS: notes, rename, pin and catalogue persistence')
    operation = {'workspace': {'workspaceID': w, 'action': {'newSession': {'agent': 'claudeCode', 'model': 'fixture', 'effort': 'low', 'permissionMode': 'plan'}}}}
    identity = str(uuid.uuid4())
    a = rpc(operation, identity)
    b = rpc(operation, identity)
    assert a == b
    print('PASS: retried mutation returns the same result without duplicating a conversation')
