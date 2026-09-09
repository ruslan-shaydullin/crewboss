#!/usr/bin/env python3
"""Local GitHub protocol fixture: no network or real credentials."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time

args = sys.argv[1:]
root = Path(os.environ['CB_HOME']) / 'run'
root.mkdir(exist_ok=True)
lock = (root / 'fixture-board.lock').open('a')
fcntl.flock(lock, fcntl.LOCK_EX)
path = root / 'fixture-board.json'
board = json.loads(path.read_text())

def option(*names, default=None):
    for name in names:
        if name in args:
            return args[args.index(name) + 1]
    return default

def api_fields():
    return dict(args[index + 1].split('=', 1)
                for index, arg in enumerate(args[:-1])
                if arg in ('-f', '-F', '--field', '--raw-field') and '=' in args[index + 1])

def persist_labels(labels):
    target = root / 'fixture-labels.json'
    temporary = target.with_suffix('.tmp')
    temporary.write_text(json.dumps(labels))
    temporary.replace(target)

def emit(data):
    query = option('--jq', '-q')
    raw = json.dumps(data)
    if query:
        result = subprocess.run(['jq', '-r', query], input=raw, text=True, capture_output=True)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        sys.exit(result.returncode)
    print(raw)

def persist():
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(board))
    temp.replace(path)

with (root / 'fixture-gh.calls').open('a') as log:
    log.write(json.dumps(args) + '\n')
if args[:2] == ['api', '/rate_limit'] or args[:2] == ['api', 'rate_limit']:
    emit({'resources': {p: {'remaining':5000, 'reset':int(time.time())+3600} for p in ['core','graphql']}})
elif args and args[0] == 'api':
    endpoint = next((a for a in args[1:] if a.startswith('/repos/') or a.startswith('repos/')), '')
    if endpoint.endswith('/issues'):
        fields = api_fields()
        state = fields.get('state', 'open').upper()
        data = [{**item, 'state':item['state'].lower()} for item in board
                if state == 'ALL' or item['state'] == state]
        if fields.get('labels'):
            wanted = fields['labels'].split(',')
            data = [item for item in data if all(name in [label['name'] for label in item['labels']]
                                                for name in wanted)]
        page = int(fields.get('page', 1)); size = int(fields.get('per_page', 30))
        data = data[(page - 1) * size:] if '--paginate' in args else data[(page - 1) * size:page * size]
        if '--include' in args:
            print('HTTP/2.0 200 OK\r\netag: "fixture"\r\n\r')
        emit(data)
    elif endpoint.endswith('/pulls'):
        emit([])
    elif '/issues/' in endpoint and endpoint.endswith('/comments'):
        number = int(endpoint.split('/issues/')[1].split('/')[0])
        emit(next(item for item in board if item['number'] == number).get('comments', []))
    else:
        print('unsupported fixture API call', args, file=sys.stderr); sys.exit(2)
elif args[:2] == ['issue', 'list']:
    state = option('--state', '-s', default='open').upper()
    labels = option('--label', '-l')
    items = [i for i in board if state == 'ALL' or i['state'] == state]
    if labels:
        items = [i for i in items if all(l in [x['name'] for x in i['labels']] for l in labels.split(','))]
    emit(items)
elif args[:2] == ['issue', 'view']:
    emit(next(item for item in board if item['number'] == int(args[2])))
elif args[:2] == ['issue', 'create']:
    body = option('--body', '-b', default='')
    if option('--body-file'): body = Path(option('--body-file')).read_text()
    number = max((item['number'] for item in board), default=0) + 1
    board.append({'number':number, 'title':option('--title', '-t', default=''),
                  'state':'OPEN', 'body':body, 'comments':[],
                  'labels':[{'name':name} for name in option('--label', '-l', default='').split(',') if name]})
    persist()
    print(f'https://github.com/{os.environ["CB_REPO"]}/issues/{number}')
elif args[:2] in (['issue','edit'], ['issue','close'], ['issue','comment']):
    item = next(item for item in board if item['number'] == int(args[2]))
    if args[1] == 'edit':
        for index, argument in enumerate(args):
            if argument == '--remove-label':
                item['labels'] = [l for l in item['labels'] if l['name'] not in args[index+1].split(',')]
            if argument == '--add-label':
                for name in args[index+1].split(','):
                    if name not in [l['name'] for l in item['labels']]: item['labels'].append({'name':name})
    elif args[1] == 'close': item['state'] = 'CLOSED'
    else:
        body = option('--body','-b',default='')
        if option('--body-file'): body = Path(option('--body-file')).read_text()
        item.setdefault('comments',[]).append({'body':body})
    persist(); emit({'ok':True})
elif args[:2] in (['label','list'], ['label','create'], ['label','edit']):
    label_path = root / 'fixture-labels.json'
    labels = json.loads(label_path.read_text()) if label_path.exists() else {}
    for item in board:
        for label in item['labels']:
            labels.setdefault(label['name'], {'name':label['name'], 'color':'ededed', 'description':''})
    if args[1] == 'list':
        rows = [labels[name] for name in sorted(labels)]
        if '--json' in args: emit(rows)
        else:
            for label in rows: print(f'{label["name"]}\t{label["description"]}\t#{label["color"]}')
    else:
        name = args[2]
        if args[1] == 'create' and name in labels:
            print('label already exists', file=sys.stderr); sys.exit(1)
        if args[1] == 'edit' and name not in labels:
            print('label does not exist', file=sys.stderr); sys.exit(1)
        labels[name] = {'name':name, 'color':option('--color', default='ededed'),
                        'description':option('--description', default='')}
        persist_labels(labels)
elif args[:2] == ['pr','list']:
    status_file = root / 'work/10/status.json'
    status = json.loads(status_file.read_text()) if status_file.exists() else {}
    # A starting/failed provider has not delivered a PR. This scenario never
    # merges one: --state merged/closed must remain empty after delivery too.
    rows = ([{'number':100,'state':'OPEN','headRefName':'leaf/10-fixture',
              'baseRefName':'charter/1','url':'https://github.com/fixture/project/pull/100'}]
            if status.get('phase') == 'done' else [])
    state = option('--state', '-s', default='open').upper()
    head = option('--head', '-H'); base = option('--base', '-B')
    emit([item for item in rows if (state == 'ALL' or item['state'] == state)
          and (head is None or item['headRefName'] == head)
          and (base is None or item['baseRefName'] == base)])
elif args[:2] == ['repo','view']:
    emit({'defaultBranchRef':{'name':'main'}, 'nameWithOwner':'fixture/project'})
else:
    print('unsupported fixture gh call', args, file=sys.stderr); sys.exit(2)
