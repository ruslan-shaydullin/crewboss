#!/usr/bin/env python3
"""Real systemd/flock/nsjail acceptance test on a disposable Linux x86_64 host.

Only GitHub and the model provider are fixtures. Install a built release archive
before testing; never execute a separate frozen copy of the runtime.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent


def run(*args, check=True, **kwargs):
    return subprocess.run([str(a) for a in args], check=check, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)


def wait_for(predicate, description, seconds=60):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        try:
            result = predicate()
            if result: return result
        except (OSError, ValueError, KeyError, urllib.error.URLError):
            pass
        time.sleep(.3)
    raise AssertionError('timed out: ' + description)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0 or platform.system() != 'Linux' or platform.machine() != 'x86_64':
        parser.error('requires root on a disposable Linux x86_64 systemd host')
    if not Path('/run/systemd/system').is_dir(): parser.error('systemd is not running')
    if not shutil.which('nsjail'): parser.error('install nsjail with tests/linux/install-nsjail.sh')
    identity = 'cbint' + str(os.getpid())
    home = Path('/var/lib') / identity
    prefix = 'crewboss-integration-' + str(os.getpid())
    unit_names = [prefix + '-' + name for name in ('api.service','launcher.service','loop-keepalive.service','loop-keepalive.timer')]
    assertions = []
    created_user = False
    fixture_dir = Path(tempfile.mkdtemp(prefix='crewboss-linux-'))
    fixture_dir.chmod(0o755)
    runtime = home / 'cbnet'
    args.report.parent.mkdir(parents=True, exist_ok=True)

    def record(description):
        assertions.append(description)
        print('PASS: ' + description, flush=True)

    def as_user(*command):
        return run('runuser','-u',identity,'--',*command)

    try:
        if home.exists() or run('id',identity,check=False).returncode == 0:
            raise RuntimeError('test identity already exists')
        run('useradd','--system','--user-group','--create-home','--home-dir',home,'--shell','/bin/bash',identity)
        created_user = True
        # Archive comes from our package builder; reject traversal/symlinks anyway.
        extracted = fixture_dir / 'extracted'; extracted.mkdir(mode=0o755)
        with tarfile.open(args.bundle) as archive:
            for member in archive.getmembers():
                if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
                    raise RuntimeError('unexpected archive member')
                target = (extracted / member.name).resolve()
                if not target.is_relative_to(extracted): raise RuntimeError('archive path traversal')
            archive.extractall(extracted, filter='data')
        bundles = list(extracted.glob('crewboss-*'))
        if len(bundles) != 1: raise RuntimeError('unexpected archive layout')
        bundle = bundles[0]
        # The bundle is readable by the unprivileged runtime user; install itself
        # runs with that user's permissions and never invokes sudo or the network.
        for directory, _, files in os.walk(extracted):
            Path(directory).chmod(0o755)
            for name in files:
                p = Path(directory) / name; p.chmod(p.stat().st_mode | 0o044)
        as_user('bash',bundle / 'install-runtime.sh','--prefix',runtime)
        record('release archive installs as an unprivileged account')
        localbin = home / '.local/bin'; localbin.mkdir(parents=True)
        (home / '.claude').mkdir()
        (home / '.claude.json').write_text('{}')
        (home / 'host-only-sentinel').write_text('must remain outside jail')
        shutil.copyfile(HERE / 'fixtures/claude.py',localbin / 'claude')
        shutil.copyfile(HERE / 'fixtures/gh.py',localbin / 'gh')
        shutil.copyfile(HERE / 'fixtures/spawn.sh',runtime / 'fixture-spawn.sh')
        for p in (localbin/'claude',localbin/'gh',runtime/'fixture-spawn.sh'): p.chmod(0o755)
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1',0)); port = reservation.getsockname()[1]
        (runtime/'run/fixture-board.json').write_text(json.dumps([
            {'number':1,'title':'Fixture charter','state':'OPEN','body':'A sandbox lifecycle fixture',
             'labels':[{'name':'type:charter'},{'name':'status:approved'}],'comments':[]},
            {'number':10,'title':'Fixture implementation','state':'OPEN',
             'body':'Charter: #1\n## Acceptance (machine)\n- check: true',
             'labels':[{'name':'type:agent'},{'name':'role:executor'}],'comments':[]},
        ]))
        settings = {
            'HOME':str(home),'PATH':f'{localbin}:/usr/local/bin:/usr/bin:/bin',
            'CB_REPO':'fixture/project','CB_HOME':str(runtime),'CB_WEB_DIR':str(runtime/'ui'),
            'CB_API_TOKEN':'fixture-bearer-token','CB_API_PORT':str(port),'CB_API_HOST':'127.0.0.1',
            'GH_TOKEN':'fixture-github-token','CLAUDE_CODE_OAUTH_TOKEN':'fixture-provider-token',
            'CB_GH_BIN':str(localbin/'gh'),'CB_CLAUDE_BIN':str(localbin/'claude'),
            'CB_SPAWN':str(runtime/'fixture-spawn.sh'),'CB_NO_INTEGRATE':'1',
            'CB_POLL':'1','CB_MAX_TICKS':'180','CB_MAX_PARALLEL':'1','CB_TASK_TIMEOUT':'30',
            'CB_PROGRESS_STALL_HOURS':'0','CB_TEST_HOST_SENTINEL':str(home/'host-only-sentinel'),
            'CB_TEST_HOST_NET':os.readlink('/proc/self/ns/net'),
        }
        envfile = home / '.crewboss.env'
        envfile.write_text(''.join(f'{key}="{value}"\n' for key,value in settings.items()))
        envfile.chmod(0o600)
        run('chown','-R',f'{identity}:{identity}',home)
        rendered = fixture_dir / 'units'
        run('python3',runtime/'systemd/render-units.py','--output-dir',rendered,'--user',identity,'--home',home,'--runtime-dir',runtime,'--env-file',envfile)
        for name in unit_names:
            original = name.replace(prefix,'crewboss',1)
            content = (rendered / original).read_text().replace('crewboss-launcher.service',prefix+'-launcher.service').replace('crewboss-loop-keepalive.service',prefix+'-loop-keepalive.service')
            (Path('/etc/systemd/system')/name).write_text(content)
        run('systemctl','daemon-reload')
        api_unit, launcher_unit, keepalive_unit, _ = unit_names

        def request(action=None, token='fixture-bearer-token'):
            data = None if action is None else json.dumps({'action':action}).encode()
            endpoint = '/api/state' if action is None else '/api/command'
            headers = {'Authorization':'Bearer '+token,'Content-Type':'application/json'}
            with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}'+endpoint,data=data,headers=headers),timeout=15) as response:
                return json.load(response)

        def pid(unit):
            return int(run('systemctl','show','--property=MainPID','--value',unit).stdout.strip() or 0)

        run('systemctl','start',api_unit)
        wait_for(lambda: request() is not None,'API boot')
        try: request(token='incorrect')
        except urllib.error.HTTPError as error: assert error.code == 401
        else: raise AssertionError('unauthorized API request accepted')
        record('shipped systemd API starts and rejects invalid credentials')
        # Editing a role needs the validator shipped beside the installed team;
        # a source-checkout fallback must not mask a missing release asset.
        role = {'name':'release-fixture-analyst','kind':'analyst','tools':'Read',
                'domain':'release-validation','prompt':'Inspect local fixture data only.'}
        headers = {'Authorization':'Bearer fixture-bearer-token','Content-Type':'application/json'}
        role_url = f'http://127.0.0.1:{port}/api/role'
        with urllib.request.urlopen(urllib.request.Request(role_url, data=json.dumps(role).encode(),
                                                          headers=headers), timeout=30) as response:
            saved = json.load(response)
        assert saved.get('ok'), saved
        with urllib.request.urlopen(urllib.request.Request(role_url+'/'+role['name'], headers=headers),
                                    timeout=15) as response:
            persisted = json.load(response)
        assert persisted.get('ok'), persisted
        assert persisted['frontmatter']['kind'] == role['kind']
        assert persisted['frontmatter']['tools'] == role['tools']
        assert persisted['prompt'] == role['prompt']
        assert role['prompt'] in (runtime/'team/roles'/f"{role['name']}.md").read_text()
        record('installed API validates, saves and reads back a team role using the bundled validator')
        assert request('pause')['ok']
        assert request('run')['ok']
        pidfile = runtime/'run/launcher.pid'
        first_launcher = wait_for(lambda: int(pidfile.read_text()),'launcher PID')
        time.sleep(2)
        assert not (runtime/'run/fixture-checkout-10/isolation.json').exists()
        assert request('run')['ok']
        assert int(pidfile.read_text()) == first_launcher
        locked = run('runuser','-u',identity,'--','flock','-n',runtime/'run/launcher.lock','true',check=False)
        assert locked.returncode != 0, 'launcher singleton lock was not held'
        record('API Run preserves singleton flock and Pause prevents agent dispatch')
        assert request('resume')['ok']
        isolation = runtime/'run/fixture-checkout-10/isolation.json'
        wait_for(lambda: isolation.exists(),'real jailed fixture agent',seconds=90)
        assert json.loads(isolation.read_text()) == {'filesystem':True,'network':True,'seccomp':True}
        def delivered():
            board=json.loads((runtime/'run/fixture-board.json').read_text())
            return 'status:review' in [l['name'] for l in board[1]['labels']]
        wait_for(delivered,'confirmed review transition')
        record('API → canonical launcher → real nsjail → fixture provider → review transition')
        record('jail hides host files, read-only system mounts, isolates network, kills forbidden syscall')
        assert request('kill')['ok']
        assert not request('run')['ok']
        wait_for(lambda: not Path(f'/proc/{first_launcher}').exists(),'kill-switch stops launcher')
        record('Kill switch stops launcher and rejects a new Run')
        assert request('unkill')['ok']
        old_api = pid(api_unit)
        run('systemctl','kill','--kill-whom=main','--signal=SIGKILL',api_unit)
        wait_for(lambda: pid(api_unit) not in (0,old_api) and request() is not None,'API restart')
        record('systemd restarts the API after an unexpected process failure')
        run('systemctl','start',keepalive_unit)
        service_pid = wait_for(lambda: pid(launcher_unit),'keepalive launcher start')
        time.sleep(2)
        assert pid(launcher_unit) == service_pid
        run('systemctl','start',keepalive_unit)
        assert pid(launcher_unit) == service_pid
        assert Path(f'/proc/{service_pid}').exists()
        record('keepalive oneshot leaves launcher alive in its own cgroup and is idempotent')
        args.report.write_text(json.dumps({'passed':True,'platform':platform.platform(),'assertions':assertions},indent=2)+'\n')
    except Exception:
        for unit in unit_names:
            print(run('journalctl','-u',unit,'--no-pager','-n','100',check=False).stdout,file=sys.stderr)
        for path in (runtime/'run/launcher.out',runtime/'run/work/10/run.log',runtime/'run/infra-failure'):
            if path.is_file(): print(path, path.read_text(),file=sys.stderr)
        args.report.write_text(json.dumps({'passed':False,'assertions':assertions},indent=2)+'\n')
        raise
    finally:
        for unit in unit_names:
            run('systemctl','stop',unit,check=False)
            (Path('/etc/systemd/system')/unit).unlink(missing_ok=True)
        run('systemctl','daemon-reload',check=False)
        if created_user:
            run('pkill','-u',identity,check=False)
            run('userdel','--remove',identity,check=False)
        shutil.rmtree(fixture_dir)


if __name__ == '__main__': main()
