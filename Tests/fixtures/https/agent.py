"""Check approval and process persistence using the deterministic agent fixture."""
import pathlib
import json
import time
import base64
import os
from rpc import rpc
p = pathlib.Path(os.environ['BLOOM_HTTPS_FIXTURE'])
created = json.loads((p / 'created.json').read_text())
w = created['workspace']['id']
s = rpc({'workspace': {'workspaceID': w, 'action': {'newSession': {'agent': 'claudeCode', 'model': 'fixture', 'effort': 'low', 'permissionMode': 'plan'}}}})['created']['session']['id']

def transcript():
    return rpc({'transcript': {'sessionID': s, 'afterSeq': -1}})['transcript']['_0']

def wait(check):
    until = time.monotonic() + 15
    while time.monotonic() < until:
        t = transcript()
        if check(t):
            return t
        time.sleep(0.1)
    raise AssertionError('Agent did not reach expected state')
assert rpc({'file': {'workspaceID': w, 'path': 'bloom-validation.txt'}})['file']['_0']['text'] == 'Bloom remote protocol fixture\n'
rpc({'send': {'sessionID': s, 'text': 'approval'}})
pending = wait(lambda t: t['pendingQuestions'] and t['isBusy'])
ask = json.loads(base64.b64decode(pending['pendingQuestions'][0]))
request_id = ask['request_id']
rpc({'answer': {'sessionID': s, 'requestID': request_id, 'answer': {'allowOnce': {}}}})
wait(lambda t: not t['isBusy'])
assert rpc({'file': {'workspaceID': w, 'path': 'hello.txt'}})['file']['_0']['text'] == 'Changed by the remote fixture\n'
print('PASS: agent approval survives disconnected HTTPS clients and executes the approved edit')
rpc({'send': {'sessionID': s, 'text': 'wait'}})
wait(lambda t: t['isBusy'])
rpc({'stop': {'sessionID': s}})
wait(lambda t: not t['isBusy'])
rpc({'send': {'sessionID': s, 'text': 'finish'}})
wait(lambda t: not t['isBusy'])
print('PASS: running agent survives client disconnect, stops, and accepts another turn')
