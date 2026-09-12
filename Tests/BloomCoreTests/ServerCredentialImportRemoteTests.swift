import Foundation
import Testing
@testable import BloomCore

@Suite struct ServerCredentialImportRemoteTests {
    @Test(arguments: ["publish", "github", "wrong-account", "git-setup-failed", "existing", "environment", "codex-install", "codex-cache", "git-symlink", "git-xdg"])
    func isolatedRemoteHelper(_ scenario: String) async throws {
        let fixture = try ImportDirectory()
        let script = fixture.url.appendingPathComponent("import.py")
        try Data(ServerCredentialImport.remoteScript.utf8).write(to: script)
        let python = try #require(Shell.which("python3"))
        let result = try await ServerCredentialImportProcess.run(python, ["-c", Self.harness, script.path, fixture.url.path, scenario], environment: ["PATH": "/usr/bin:/bin"], timeout: 10, captureStderr: true)
        #expect(result.status == 0, "Isolated remote fixture failed")
        let passed = result.output == Data("passed\n".utf8)
        #expect(passed)
    }

    // Every credential and executable is fake. Nothing invokes gh, Codex, SSH or the real home.
    private static let harness = #"""
import io,os,pathlib,sys,types
source,root,scenario=sys.argv[1:]
ns={'__name__':'fixture'}
exec(compile(pathlib.Path(source).read_text(),'<import-fixture>','exec'),ns)
home=pathlib.Path(root)/'home';home.mkdir(mode=0o700)
real_fstat=os.fstat
os.getuid=lambda:12345
def fake_fstat(fd):
    values=list(real_fstat(fd));values[4]=12345
    return os.stat_result(values)
os.fstat=fake_fstat
ns['pwd'].getpwuid=lambda uid:types.SimpleNamespace(pw_dir=str(home))
Refusal=ns['Refusal']
def refused(code,operation):
    try: operation()
    except Refusal as error: assert str(error)==code
    else: raise AssertionError('expected refusal')
if scenario=='publish':
    fd=os.open(home,os.O_RDONLY|os.O_DIRECTORY)
    try:
        ns['publish'](fd,'auth.json',b'first-fake')
        refused('existingAuth',lambda:ns['publish'](fd,'auth.json',b'second-fake'))
        assert (home/'auth.json').read_bytes()==b'first-fake'
        assert (home/'auth.json').stat().st_mode & 0o777==0o600
        (home/'linked').symlink_to(home/'missing')
        refused('existingAuth',lambda:ns['absent'](fd,'linked'))
        (home/'directory-link').symlink_to(home,target_is_directory=True)
        try: ns['folder'](fd,'directory-link')
        except OSError: pass
        else: raise AssertionError('followed directory link')
        os.mkfifo(home/'pipe')
        refused('unsafePath',lambda:ns['read'](fd,'pipe',100))
        assert not list(home.glob('.bloom-import-*'))
    finally: os.close(fd)
else:
    calls=[];installed=False
    provider='codex' if scenario.startswith('codex') else 'github'
    def which(binary,path=None):
        if binary=='codex' and scenario=='codex-install' and not installed: return None
        return '/fake/'+binary
    ns['shutil'].which=which
    def run(args,env,input=None,capture=False,timeout=30):
        global installed
        calls.append(list(args))
        if args[0]=='/fake/npm':
            assert input is None and args[-1]=='@openai/codex'
            assert env['HOME']==str(home)
            installed=True;return 0,b''
        if args[1:3]==['auth','login']:
            assert input==b'fake-token\n'
            assert '--with-token' in args and 'fake-token' not in ' '.join(args)
            (pathlib.Path(env['GH_CONFIG_DIR'])/'hosts.yml').write_bytes(b'fake-generated-config')
        elif args[1:3]==['api','user']:
            return 0,b'other-user\n' if scenario=='wrong-account' else b'fixture-user\n'
        elif args[1:3]==['auth','setup-git']:
            assert env['GH_CONFIG_DIR']==str(home/'.config/gh')
            assert env['GIT_CONFIG_GLOBAL']==str(home/'.gitconfig') and env['GIT_CONFIG_NOSYSTEM']=='1'
            assert (home/'.config/gh/hosts.yml').read_bytes()==b'fake-generated-config'
            if scenario=='git-setup-failed': return 1,b''
        elif args[1:3]==['login','status']:
            assert env['CODEX_HOME']==str(home/'.codex')
            assert (home/'.codex/auth.json').exists()
        else: raise AssertionError('unexpected fake command')
        return 0,b''
    ns['run']=run
    class NeverRead:
        def read(self,count): raise AssertionError('read secret during preflight')
    payload=b'{"OPENAI_API_KEY":"fake-key"}' if provider=='codex' else b'fake-token\n'
    sys.stdin=types.SimpleNamespace(buffer=NeverRead() if scenario in ('codex-install','existing','environment','git-symlink','git-xdg') else io.BytesIO(payload))
    sys.argv=['fixture','check' if scenario=='codex-install' else 'import',provider,'github.example','fixture-user']
    if scenario=='existing':
        target=home/'.config/gh';target.mkdir(parents=True,mode=0o700)
        (target/'hosts.yml').write_bytes(b'preserve-existing')
        refused('existingAuth',ns['perform'])
        assert (target/'hosts.yml').read_bytes()==b'preserve-existing' and not calls
    elif scenario=='git-symlink':
        outside=home/'unrelated';outside.write_bytes(b'preserve')
        (home/'.gitconfig').symlink_to(outside)
        refused('unsafePath',ns['perform'])
        assert outside.read_bytes()==b'preserve' and not calls
    elif scenario=='git-xdg':
        target=home/'.config/git';target.mkdir(parents=True,mode=0o700)
        (target/'config').write_bytes(b'preserve-config')
        refused('unsupportedStorage',ns['perform'])
        assert (target/'config').read_bytes()==b'preserve-config' and not calls
    elif scenario=='environment':
        os.environ['GH_TOKEN']='fake-override'
        refused('unsupportedStorage',ns['perform'])
        assert not calls and not (home/'.config/gh/hosts.yml').exists()
    elif scenario=='wrong-account':
        refused('wrongAccount',ns['perform'])
        assert not (home/'.config/gh/hosts.yml').exists()
        assert not list(home.glob('.bloom-gh-import-*'))
    elif scenario=='codex-install':
        (home/'.local').mkdir(mode=0o755)
        assert ns['perform']()=='ready' and installed
        assert not (home/'.codex/auth.json').exists()
    elif scenario=='codex-cache':
        assert ns['perform']()=='cacheAccepted'
        assert (home/'.codex/auth.json').stat().st_mode & 0o777==0o600
    else:
        assert ns['perform']()==('importedUnverified' if scenario=='git-setup-failed' else 'verified')
        assert calls[-1][1:3]==['auth','setup-git']
        assert not list(home.glob('.bloom-gh-import-*'))
print('passed')
"""#
}
