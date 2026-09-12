import Foundation

extension ServerToolUpdates {
    /// Fixed package names and prefix prevent a web response or editable setting from becoming
    /// a shell command. Unknown launchers are reported, never migrated or overwritten.
    static let script = #"""
import fcntl,json,os,pathlib,pwd,selectors,shutil,signal,stat,subprocess,sys,time
PACKAGES={'claude':'@anthropic-ai/claude-code','codex':'@openai/codex'}
SYSTEM_PATH='/usr/local/bin:/usr/bin:/bin'
class Refusal(Exception): pass
def emit(event,message,**extra):
    print(json.dumps(dict(event=event,message=message,**extra)),flush=True)
def refuse(message): raise Refusal(message)
def interrupted(signum,frame): refuse('The update was interrupted. Check the installed version before trying again.')
def owned(path,home):
    try:
        path=pathlib.Path(path)
        path.relative_to(home)
        for item in [path]+list(path.parents):
            info=item.lstat()
            if stat.S_ISLNK(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode & 0o022: return False
            if item==home: return True
    except (OSError,ValueError): pass
    return False
def system_owned(path):
    try:
        for item in [path]+list(path.parents):
            info=item.lstat()
            if stat.S_ISLNK(info.st_mode) or info.st_uid!=0 or info.st_mode & 0o022: return False
        return True
    except OSError: return False
def external_version(value,path,resolved,home):
    if system_owned(path.parent.resolve()) and system_owned(resolved):
        try:
            status,version=run([str(path),'--version'],home)
            if status==0: value['version']=version[:200]
        except (Refusal,OSError,subprocess.TimeoutExpired): pass
    return value
def environment(home):
    return {'HOME':str(home),'USER':pwd.getpwuid(os.getuid()).pw_name,
            'PATH':str(home/'.local/bin')+':'+SYSTEM_PATH,'LANG':'C.UTF-8',
            'CI':'1','NO_COLOR':'1','DISABLE_AUTOUPDATER':'1',
            'NPM_CONFIG_USERCONFIG':'/dev/null','NPM_CONFIG_GLOBALCONFIG':'/dev/null'}
def run(args,home,timeout=15,stream=False):
    process=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
        env=environment(home),cwd=home,start_new_session=True)
    output=bytearray();pending=bytearray();deadline=time.monotonic()+timeout
    try:
        with selectors.DefaultSelector() as selector:
            os.set_blocking(process.stdout.fileno(),False);selector.register(process.stdout,selectors.EVENT_READ)
            while selector.get_map():
                if time.monotonic()>=deadline: refuse('The tool command timed out. Check the installed version before retrying.')
                for key,_ in selector.select(.2):
                    chunk=os.read(key.fd,4096)
                    if not chunk: selector.unregister(key.fileobj);continue
                    output.extend(chunk);output=output[-65536:]
                    if stream:
                        pending.extend(chunk)
                        while b'\n' in pending or len(pending)>=4096:
                            end=pending.find(b'\n')
                            if end<0: end=4096
                            emit('output',bytes(pending[:end]).decode('utf-8','replace'))
                            del pending[:end+1 if pending[end:end+1]==b'\n' else end]
        if pending: emit('output',pending.decode('utf-8','replace'))
        status=process.wait(timeout=max(.01,deadline-time.monotonic()))
        return status,output.decode('utf-8','replace').strip()
    finally:
        try: os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError: pass
        process.wait();process.stdout.close()
def installation(tool,home):
    binary=shutil.which(tool,path=environment(home)['PATH'])
    value=dict(tool=tool,version=None,path=binary,method=None,detail='Not installed. Open Accounts to install and sign in.')
    if not binary: return value
    path=pathlib.Path(binary)
    try: resolved=path.resolve(strict=True)
    except OSError:
        value['detail']='The launcher is broken. Repair this installation on the server.';return value
    value['detail']='Managed outside Bloom. Update this tool using its original installer on the server.'
    # Only Bloom's established ~/.local npm prefix and the vendor native Claude layout.
    # A launcher itself may be a symlink, but neither parent paths nor targets may escape home.
    if path!=home/'.local/bin'/tool or not owned(path.parent,home) or not owned(resolved,home):
        return external_version(value,path,resolved,home)
    metadata=home/'.local/lib/node_modules'/PACKAGES[tool]/'package.json'
    try:
        package_root=metadata.parent
        if owned(metadata,home) and resolved.is_relative_to(package_root):
            data=json.loads(metadata.read_text())
            if data.get('name')==PACKAGES[tool]:
                value['method']='npm';value['detail']='User installation, updated with npm.'
        elif tool=='claude' and resolved.is_relative_to(home/'.local/share/claude/versions'):
            value['method']='native';value['detail']='Native installation, updated using its configured release channel.'
    except (OSError,ValueError): pass
    if value['method']:
        try:
            status,version=run([str(path),'--version'],home)
            if status==0: value['version']=version[:200]
            else:
                value['method']=None;value['detail']='Version check failed. Repair the installation on the server.'
        except (Refusal,OSError,subprocess.TimeoutExpired) as error:
            value['method']=None;value['detail']=str(error)
    return value
def active_agents(home,proc=pathlib.Path('/proc')):
    if not proc.is_dir(): refuse('Tool updates require Linux process inspection.')
    for entry in proc.iterdir():
        if not entry.name.isdigit() or int(entry.name)==os.getpid(): continue
        try:
            if entry.stat().st_uid!=os.getuid(): continue
            args=(entry/'cmdline').read_bytes().split(b'\0')
            names=[pathlib.Path(arg.decode('utf-8','replace')).name for arg in args[:3]]
            if any(name in ('claude','codex','codex.js','claude.js') for name in names): return True
            if any(b'/node_modules/@anthropic-ai/claude-code/' in arg or b'/node_modules/@openai/codex/' in arg for arg in args[:3]): return True
            executable=(entry/'exe').resolve()
            if executable.is_relative_to(home/'.local/share/claude/versions'): return True
        except (FileNotFoundError,ProcessLookupError): continue
        except PermissionError: refuse('Cannot inspect running agents. Check server process permissions before updating.')
    return False
def update(tool,home):
    lockpath=home/'.local/.bloom-tool-update.lock'
    if not owned(lockpath.parent,home): refuse('The tool installation directory is not owned safely by this account.')
    descriptor=os.open(lockpath,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        info=os.fstat(descriptor)
        if info.st_uid!=os.getuid() or not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
            refuse('The update lock is not private to this account.')
        try: fcntl.flock(descriptor,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: refuse('Another tool update is already running. Wait for it to finish, then refresh.')
        value=installation(tool,home)
        if not value['method']: refuse(value['detail'])
        if active_agents(home): refuse('An AI agent is running on this server. Let its turn finish and close idle agent terminals before updating.')
        if value['method']=='native': args=[value['path'],'update']
        else:
            npm=shutil.which('npm',path=SYSTEM_PATH)
            if npm is None: refuse('npm is unavailable. Ask the server administrator to repair Node.js and npm.')
            args=[npm,'install','--global','--prefix',str(home/'.local'),'--registry=https://registry.npmjs.org',
                  '--no-audit','--no-fund',PACKAGES[tool]+'@latest']
        emit('progress','Updating '+tool+' as '+pwd.getpwuid(os.getuid()).pw_name)
        status,output=run(args,home,timeout=360,stream=True)
        if status!=0:
            emit('error','The update command failed. Refresh to check the installed version.',
                 details=output,exitStatus=status,command=' '.join(args),code='tool_update_failed');return
        latest=installation(tool,home)
        if not latest['version']: refuse('The installer finished, but the updated tool could not be verified. Refresh and review the output.')
        emit('complete','Installed '+latest['version'])
    finally: os.close(descriptor)
def main():
    if sys.platform!='linux' or os.getuid()==0: refuse('Connect using the unprivileged Bloom service account to manage tools.')
    home=pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)
    if not owned(home,home): refuse('The service account home directory is not safely owned.')
    action=sys.argv[1]
    if action=='inspect': print(json.dumps([installation(tool,home) for tool in PACKAGES]),flush=True)
    elif action in PACKAGES: update(action,home)
    else: refuse('Unknown tool update request.')
if __name__=='__main__':
    for sig in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT): signal.signal(sig,interrupted)
    try: main()
    except (Refusal,OSError,ValueError,subprocess.TimeoutExpired) as error:
        emit('error',str(error),code='tool_update_failed',recovery='Refresh the installed versions and review the output before trying again.');sys.exit(1)
"""#
}
