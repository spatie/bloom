#!/usr/bin/env python3
"""Render workspace_start states after building Bloom. Uses local agents and a background panel."""
import json, pathlib, plistlib, shlex, subprocess, sys, tempfile

ROOT = pathlib.Path(tempfile.mkdtemp(prefix='bloom-terminal-capture-'))
(ROOT/'root.txt').write_text(str(ROOT))
print(ROOT, flush=True)
BIN = ROOT/'bin'
BIN.mkdir()
ZDOT = ROOT/'shell'
ZDOT.mkdir()
for name in ('.zshenv','.zprofile','.zshrc','.zlogin'):
    (ZDOT/name).write_text(f"export PATH='{BIN}:/usr/bin:/bin:/usr/sbin:/sbin'\nexport PS1='capture % '\n")
fixture = '''#!PYTHON
import json, os, pathlib, sys, time
args = sys.argv[1:]
agent = pathlib.Path(sys.argv[0]).name
with open('ROOT/cli-argv.jsonl','a') as out:
    out.write(json.dumps({'agent':agent,'argv':args,'cwd':os.getcwd()})+'\\n')
if '--version' in args:
    print('capture fixture 1.0'); sys.exit(0)
if 'app-server' in args:
    for line in sys.stdin:
        request=json.loads(line)
        if 'id' not in request: continue
        method=request.get('method')
        if method == 'initialize': result={'userAgent':'capture fixture'}
        elif method == 'model/list':
            result={'data':[{'id':'capture-codex','displayName':'Capture fixture','isDefault':True,
                            'supportedReasoningEfforts':[{'reasoningEffort':'medium'}],
                            'defaultReasoningEffort':'medium'}],'nextCursor':None}
        elif method == 'account/read': result={'account':None,'requiresOpenaiAuth':False}
        else: result={}
        print(json.dumps({'id':request['id'],'result':result}),flush=True)
    sys.exit(0)
if 'status' in args or 'auth' in args:
    sys.exit(0)
if '--output-format' in args:
    print(json.dumps({'type':'system','subtype':'init','session_id':'capture-session','tools':[]}),flush=True)
    if '--input-format' in args:
        for line in sys.stdin:
            value=json.loads(line)
            if value.get('type') == 'user': break
    text='Local capture fixture received the opening task. No real agent task was launched.'
    print(json.dumps({'type':'assistant','message':{'id':'capture-message','role':'assistant','content':[{'type':'text','text':text}]}}),flush=True)
    print(json.dumps({'type':'result','subtype':'success','result':text,'session_id':'capture-session','is_error':False,'total_cost_usd':0}),flush=True)
    sys.exit(0)
print('Local CLI capture fixture: '+agent,flush=True)
print('No real agent task was launched. Opening task received as one argv item:',flush=True)
print('',flush=True)
if '--' in args:
    print(args[args.index('--')+1],flush=True)
else:
    print('No opening prompt argument.',flush=True)
print('\\nFixture idle. No network or agent tools are available.',flush=True)
'''.replace('PYTHON',sys.executable).replace('ROOT',str(ROOT))
for agent in ('claude','codex','grok','cursor-agent','opencode'):
    file=BIN/agent
    file.write_text(fixture)
    file.chmod(0o755)
(BIN/'tmux').write_text('#!/bin/sh\nexit 1\n')
(BIN/'tmux').chmod(0o755)
# All subprocess paths resolve harmless fixtures. The app's login-shell PATH probe is disabled.
env = {'BLOOM_DB_PATH':str(ROOT/'data/bloom.sqlite'),'BLOOM_LOGIN_SHELL_PATH':'0',
       'BLOOM_CAPTURE_FIXTURES':str(ROOT),
       'ZDOTDIR':str(ZDOT),'PATH':f'{BIN}:/usr/bin:/bin:/usr/sbin:/sbin',
       'CLAUDE_CONFIG_DIR':str(ROOT/'claude-home'),'CODEX_HOME':str(ROOT/'codex-home')}
(ROOT/'environment.json').write_text(json.dumps(env,indent=2))
app = ROOT/'Bloom Terminal Capture.app'
subprocess.run(['zsh', '-c', 'source Tools/probe-app.sh\n'
                + 'bloom_prepare_probe_app ' + shlex.quote(str(app))
                + ' be.spatie.bloom.terminal-start-capture "Bloom Terminal Capture"'], check=True)
plist = app/'Contents/Info.plist'
for scenario in ('claude-cli', 'codex-cli', 'override-chat', 'default-cli', 'codex-reuse-default-cli'):
    case = ROOT/scenario
    repo = case/'terminal-start-fixture'
    repo.mkdir(parents=True)
    subprocess.run(['git', 'init', '-q', '-b', 'main', str(repo)], check=True)
    subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Capture Fixture', '-c',
                    'user.email=capture@example.test', '-c', 'commit.gpgsign=false',
                    'commit', '--allow-empty', '-qm', 'Capture fixture'], check=True)
    launch_env = {**env, 'BLOOM_DB_PATH':str(case/'bloom.sqlite')}
    info = plistlib.loads(plist.read_bytes())
    info['LSEnvironment'] = launch_env
    plist.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    command = ['open', '-g', '-n', '-W', '-a', str(app), '--stdout', str(case/'stdout.log'),
               '--stderr', str(case/'stderr.log')]
    for key, value in launch_env.items():
        command.extend(['--env', key+'='+value])
    command.extend(['--args', '--workspace-start-snapshots', str(case)])
    subprocess.run(command, timeout=45, check=False)
    screenshot = case/'workspace.png'
    if not screenshot.exists():
        raise RuntimeError((case/'stderr.log').read_text())
    print(screenshot, flush=True)
