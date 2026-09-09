#!/usr/bin/env python3
"""Assert the shipped spawn sandbox, then emit a provider-compatible result."""
import ctypes
import errno
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys

assert '--agent' in sys.argv and '-p' in sys.argv
assert not Path(os.environ['CB_TEST_HOST_SENTINEL']).exists(), 'host home leaked into jail'
assert os.readlink('/proc/self/ns/net') != os.environ['CB_TEST_HOST_NET'], 'host network namespace leaked'
status = Path('/proc/self/status').read_text()
assert 'Seccomp:\t2' in status, 'seccomp filter missing'
try:
    Path('/etc/crewboss-write-probe').write_text('must not write')
except OSError as error:
    assert error.errno in (errno.EROFS, errno.EACCES, errno.EPERM)
else:
    raise AssertionError('/etc was writable')
with socket.socket() as connection:
    connection.settimeout(2)
    try: connection.connect(('1.1.1.1',443))
    except OSError: pass
    else: raise AssertionError('direct external network connection succeeded')
# x86_64 mount(2) must be killed by the shipped DEFAULT KILL_PROCESS policy.
probe = subprocess.run([sys.executable, '-c', 'import ctypes; ctypes.CDLL(None).syscall(165,0,0,0,0,0)'])
assert probe.returncode == -signal.SIGSYS, f'forbidden syscall was not killed: {probe.returncode}'
Path('/work/isolation.json').write_text(json.dumps({'filesystem':True,'network':True,'seccomp':True}))
print(json.dumps({'is_error':False,'total_cost_usd':0,'result':'Fixture complete: https://github.com/fixture/project/pull/100'},separators=(',',':')))
