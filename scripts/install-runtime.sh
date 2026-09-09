#!/usr/bin/env bash
# Install a verified release into an explicit empty prefix; no service/network actions.
set -euo pipefail
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  echo 'usage: install-runtime.sh --prefix ABSOLUTE_DIR [--bundle EXTRACTED_DIR]'
  echo 'The prefix must be empty or absent. Existing runtime files are never overwritten.'
  exit 0
fi
prefix=''; bundle="$(cd "$(dirname "$0")" && pwd -P)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix|--bundle)
      [ "$#" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }
      if [ "$1" = --prefix ]; then prefix="$2"; else bundle="$2"; fi
      shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
command -v python3 >/dev/null || { echo 'python3 is required' >&2; exit 2; }
python3 - "$bundle" "$prefix" <<'PY'
import hashlib
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

bundle = Path(sys.argv[1]).resolve()
prefix = Path(sys.argv[2])
staging = None
try:
    if not sys.argv[2] or not prefix.is_absolute():
        raise ValueError('--prefix must be an explicit absolute directory')
    if '..' in prefix.parts or prefix.is_symlink():
        raise ValueError('--prefix must not contain parent traversal or be a symlink')
    prefix = prefix.resolve()
    if prefix == Path('/') or prefix == bundle or prefix.is_relative_to(bundle) or bundle.is_relative_to(prefix):
        raise ValueError('--prefix must be separate from the bundle and filesystem root')
    if prefix.exists() and (not prefix.is_dir() or any(prefix.iterdir())):
        raise ValueError('refusing an existing non-empty --prefix')
    for required in ('VERSION','SHA256SUMS','runtime/runtime-manifest.tsv','runtime/gh-shim.sh','ui/index.html','team/org.json','gov/.claude/settings.json'):
        if not (bundle/required).is_file(): raise ValueError('bundle is missing '+required)
    for required in ('systemd','team','gov','ui'):
        if not (bundle/required).is_dir(): raise ValueError('bundle is missing '+required)
    actual = set()
    for path in bundle.rglob('*'):
        if path.is_symlink(): raise ValueError('bundle symlink is not allowed: '+str(path.relative_to(bundle)))
        if path.is_file(): actual.add(path.relative_to(bundle).as_posix())
        elif not path.is_dir(): raise ValueError('unexpected bundle object: '+str(path))
    checked = set()
    for line in (bundle/'SHA256SUMS').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  (.+)',line)
        if not match: raise ValueError('malformed SHA256SUMS')
        digest, name = match.groups()
        parts = name.split('/')
        if name.startswith('/') or any(p in ('','.','..') for p in parts) or '\\' in name or name in checked:
            raise ValueError('unsafe or duplicate checksum entry: '+name)
        path = bundle/name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('bundle checksum mismatch or missing file: '+name)
        checked.add(name)
    if checked != actual - {'SHA256SUMS'}:
        raise ValueError('bundle checksum inventory does not match files: '+', '.join(sorted(checked ^ (actual-{'SHA256SUMS'}))))
    names = set()
    for line in (bundle/'runtime/runtime-manifest.tsv').read_text().splitlines():
        if not line or line.startswith('#'): continue
        fields = line.split('\t')
        if len(fields) != 4 or fields[2] != 'canonical': raise ValueError('invalid runtime manifest row')
        name = Path(fields[0]).name
        if name in names: raise ValueError('duplicate runtime basename: '+name)
        names.add(name)
        path = bundle/'runtime'/name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != fields[1]:
            raise ValueError('runtime manifest mismatch: '+name)
    runtime_files = {p.name for p in (bundle/'runtime').iterdir() if p.is_file()}
    if runtime_files != names | {'runtime-manifest.tsv'}:
        raise ValueError('runtime manifest inventory does not match installed files')
    version = (bundle/'VERSION').read_text().strip()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?', version):
        raise ValueError('invalid release VERSION')
    # All validation precedes mutation. Stage the entire installation next to its
    # destination so a failed copy cannot leave a partially installed runtime.
    prefix.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.crewboss-install-',dir=prefix.parent))
    for source in (bundle/'runtime').iterdir(): shutil.copy2(source, staging/source.name)
    for name in ('team','gov','systemd','ui'): shutil.copytree(bundle/name,staging/name)
    (staging/'run').mkdir(mode=0o700)
    (staging/'gh').symlink_to('gh-shim.sh')
    staging.chmod(0o700)
    # os.rename replaces an empty directory only, and rejects one populated by
    # another process since the initial check.
    staging.rename(prefix)
    staging = None
    print(f'crewboss {version} installed: {prefix}')
    print(f'Configure CB_HOME={prefix} and credentials in the runtime account\'s .crewboss.env (mode 0600).')
    print(f'Configuration example: {bundle}/crewboss.env.example')
    print(f'Preflight: bash {prefix}/crewboss-doctor.sh --preflight')
    print(f'Start API: bash {prefix}/start-api.sh --foreground')
    print(f'Systemd templates: {prefix}/systemd/ (nothing started)')
except (ValueError,OSError) as error:
    print('install-runtime: '+str(error),file=sys.stderr)
    sys.exit(2)
finally:
    if staging is not None: shutil.rmtree(staging)
PY
