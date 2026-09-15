import Foundation

extension ServerCredentialImport {
    struct RemoteReply: Decodable { let status: String }

    static func remote(_ candidate: Candidate, connection: ServerSetupConnection, phase: String, input: Data) async throws -> RemoteReply {
        let provider: String, host: String, user: String
        switch candidate {
        case .github(let hostname, let login): provider = "github"; host = hostname; user = login
        case .codex: provider = "codex"; host = ""; user = ""
        }
        let command = (["python3", "-c", remoteScript, phase, provider, host, user]).map(ServerSetupSSH.shellQuote).joined(separator: " ")
        var environment = transportEnvironment()
        if let agent = Shell.environment()["SSH_AUTH_SOCK"] { environment["SSH_AUTH_SOCK"] = agent }
        let result = try await ServerCredentialImportProcess.run("/usr/bin/ssh", connection.arguments(command: command), environment: environment, input: input, limit: 4096, timeout: phase == "check" ? 240 : 100)
        guard result.status == 0, let reply = try? JSONDecoder().decode(RemoteReply.self, from: result.output) else {
            throw Failure(message: "The verified SSH credential transfer did not complete.", recovery: "The server may have received the credential. Check its accounts before retrying. Reconnect with the existing trusted host and service-user key.")
        }
        return reply
    }

    static func checkRemote(_ reply: RemoteReply, phase: String) throws {
        if phase == "check", reply.status == "ready" { return }
        if phase == "import", ["verified", "importedUnverified", "cacheAccepted"].contains(reply.status) { return }
        switch reply.status {
        case "existingAuth": throw Failure(message: "This server already has credentials for that provider.", recovery: "Sign out of that account on the server first if you intend to replace it. Bloom will not overwrite existing credentials.")
        case "missingCLI": throw failure("GitHub CLI is not installed on the server.")
        case "installFailed": throw Failure(message: "Codex could not be installed on the server.", recovery: "Check Node.js/npm and the server network, or install Codex as the Bloom service user before importing.")
        case "unsupportedStorage": throw failure("The server uses a different or non-file credential store.")
        case "unsafePath", "rootUser": throw failure("The server account or credential directory is not safe for import.")
        case "wrongAccount": throw failure("The GitHub token does not belong to the selected account.")
        default: throw failure("The server could not accept or verify this credential.")
        }
    }

    /// No credential enters this script's arguments. It reads bounded stdin only after preflight.
    static let remoteScript = #"""
import json,os,pathlib,pwd,selectors,shutil,signal,stat,subprocess,sys,tempfile,time,tomllib
class Refusal(Exception): pass
def refuse(code): raise Refusal(code)
def interrupted(signum,frame): raise Refusal('cancelled')
for sig in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT): signal.signal(sig,interrupted)
def run(args,env,input=None,capture=False,timeout=30):
    process=subprocess.Popen(args,stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,stderr=subprocess.DEVNULL,
        env=env,cwd=env['HOME'],start_new_session=True)
    try:
        if not capture:
            process.communicate(input,timeout=timeout)
            return process.returncode,b''
        if input is not None: refuse('invalidRequest')
        output=bytearray();deadline=time.monotonic()+timeout
        with selectors.DefaultSelector() as selector:
            os.set_blocking(process.stdout.fileno(),False);selector.register(process.stdout,selectors.EVENT_READ)
            while selector.get_map():
                remaining=deadline-time.monotonic()
                if remaining<=0: refuse('timedOut')
                for key,_ in selector.select(min(remaining,.2)):
                    chunk=os.read(key.fd,4096)
                    if not chunk: selector.unregister(key.fileobj);continue
                    if len(output)+len(chunk)>16384: refuse('invalidReply')
                    output.extend(chunk)
        return process.wait(timeout=max(.01,deadline-time.monotonic())),bytes(output)
    finally:
        try: os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError: pass
        process.wait()
def folder(parent,name,private=False):
    try: os.mkdir(name,0o700,dir_fd=parent)
    except FileExistsError: pass
    fd=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
    info=os.fstat(fd)
    if info.st_uid!=os.getuid() or info.st_mode & (0o077 if private else 0o022): os.close(fd);refuse('unsafePath')
    return fd
def absent(fd,name):
    try: os.stat(name,dir_fd=fd,follow_symlinks=False)
    except FileNotFoundError: return
    refuse('existingAuth')
def read(fd,name,limit):
    descriptor=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=fd)
    with os.fdopen(descriptor,'rb') as source:
        info=os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_size>limit: refuse('unsafePath')
        result=source.read(limit+1)
        if len(result)>limit: refuse('unsafePath')
        return result
def publish(fd,name,data):
    temporary='.bloom-import-'+os.urandom(16).hex()
    descriptor=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=fd)
    try:
        with os.fdopen(descriptor,'wb') as output:
            os.fchmod(output.fileno(),0o600);output.write(data);output.flush();os.fsync(output.fileno())
        try: os.link(temporary,name,src_dir_fd=fd,dst_dir_fd=fd,follow_symlinks=False)
        except FileExistsError: refuse('existingAuth')
    finally: os.unlink(temporary,dir_fd=fd)
def codex_cache(data):
    value=json.loads(data)
    if not isinstance(value,dict) or set(value)-{'auth_mode','OPENAI_API_KEY','tokens','last_refresh'}: return False
    if value.get('auth_mode') not in (None,'apikey','chatgpt'): return False
    key=value.get('OPENAI_API_KEY')
    if isinstance(key,str) and 0<len(key.encode())<=8192: return True
    tokens=value.get('tokens')
    return isinstance(tokens,dict) and all(isinstance(tokens.get(k),str) and 0<len(tokens[k].encode())<=32768 for k in ('access_token','refresh_token','id_token'))
def git_configuration(home,homefd,config,env):
    expected=str(home/'.gitconfig')
    if os.environ.get('GIT_CONFIG_GLOBAL',expected)!=expected or os.environ.get('GIT_CONFIG_SYSTEM'): refuse('unsupportedStorage')
    try: info=os.stat('.gitconfig',dir_fd=homefd,follow_symlinks=False)
    except FileNotFoundError: info=None
    if info is not None and (not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode & 0o022): refuse('unsafePath')
    try: xdg=os.open('git',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=config)
    except FileNotFoundError: xdg=None
    if xdg is not None:
        try:
            try: os.stat('config',dir_fd=xdg,follow_symlinks=False)
            except FileNotFoundError: pass
            else: refuse('unsupportedStorage')
        finally: os.close(xdg)
    env['GIT_CONFIG_GLOBAL']=expected;env['GIT_CONFIG_NOSYSTEM']='1'
def perform():
    phase,provider,host,user=sys.argv[1:]
    if os.getuid()==0: refuse('rootUser')
    home=pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)
    if not home.is_absolute() or home.is_symlink(): refuse('unsafePath')
    homefd=os.open(home,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    info=os.fstat(homefd)
    if info.st_uid!=os.getuid() or info.st_mode & 0o022: os.close(homefd);refuse('unsafePath')
    handles=[homefd]
    env={'HOME':str(home),'PATH':str(home/'.local/bin')+':/usr/local/bin:/usr/bin:/bin','LANG':'C.UTF-8','GH_PROMPT_DISABLED':'1','GIT_TERMINAL_PROMPT':'0'}
    try:
        if provider=='github':
            if any(os.environ.get(key) for key in ('GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN')): refuse('unsupportedStorage')
            if os.environ.get('GH_CONFIG_DIR',str(home/'.config/gh'))!=str(home/'.config/gh') or os.environ.get('XDG_CONFIG_HOME',str(home/'.config'))!=str(home/'.config'): refuse('unsupportedStorage')
            config=folder(homefd,'.config');handles.append(config)
            git_configuration(home,homefd,config,env)
            target=folder(config,'gh',private=True);handles.append(target)
            name='hosts.yml'
        elif provider=='codex':
            if os.environ.get('OPENAI_API_KEY'): refuse('unsupportedStorage')
            if os.environ.get('CODEX_HOME',str(home/'.codex'))!=str(home/'.codex'): refuse('unsupportedStorage')
            target=folder(homefd,'.codex',private=True);handles.append(target)
            name='auth.json'
            try: config=tomllib.loads(read(target,'config.toml',65536).decode())
            except FileNotFoundError: config={}
            if config.get('cli_auth_credentials_store','file')!='file': refuse('unsupportedStorage')
            env['CODEX_HOME']=str(home/'.codex')
        else: refuse('invalidRequest')
        absent(target,name)
        binary=shutil.which('gh' if provider=='github' else 'codex',path=env['PATH'])
        if binary is None:
            if provider=='github': refuse('missingCLI')
            local=folder(homefd,'.local');os.close(local)
            npm=shutil.which('npm',path='/usr/local/bin:/usr/bin:/bin')
            if npm is None or run([npm,'install','--global','--prefix',str(home/'.local'),'@openai/codex'],env,timeout=180)[0]!=0: refuse('installFailed')
            binary=shutil.which('codex',path=env['PATH'])
            if binary is None: refuse('installFailed')
        if phase=='check': return 'ready'
        if phase!='import': refuse('invalidRequest')
        data=sys.stdin.buffer.read(131073)
        if not data or len(data)>131072: refuse('invalidCredential')
        absent(target,name)
        if provider=='codex':
            if not codex_cache(data): refuse('invalidCredential')
            publish(target,name,data)
            return 'cacheAccepted' if run([binary,'login','status'],env)[0]==0 else 'importedUnverified'
        if len(data)>8193 or not data.strip() or any(c<33 or c>=127 for c in data.strip()): refuse('invalidCredential')
        with tempfile.TemporaryDirectory(prefix='.bloom-gh-import-',dir=home) as stage:
            os.chmod(stage,0o700);env['GH_CONFIG_DIR']=stage
            status,_=run([binary,'auth','login','--hostname',host,'--git-protocol','https','--with-token','--insecure-storage'],env,input=data,timeout=40)
            if status!=0: refuse('importFailed')
            status,identity=run([binary,'api','user','--hostname',host,'--jq','.login | select(type=="string") | .[0:100]'],env,capture=True)
            if status!=0: refuse('importFailed')
            if identity.decode().strip().lower()!=user.lower(): refuse('wrongAccount')
            source=os.open(stage,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
            try: generated=read(source,'hosts.yml',65536)
            finally: os.close(source)
            publish(target,name,generated)
        env['GH_CONFIG_DIR']=str(home/'.config/gh')
        return 'verified' if run([binary,'auth','setup-git','--hostname',host],env)[0]==0 else 'importedUnverified'
    finally:
        for fd in reversed(handles): os.close(fd)
def main():
    try: status=perform()
    except Refusal as error: status=str(error)
    except BaseException: status='importFailed'
    print(json.dumps({'status':status}),flush=True)
if __name__=='__main__': main()
"""#
}
