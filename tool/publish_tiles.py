#!/usr/bin/env python3
"""Upload build/tiles to the rolling GitHub releases named in manifest.json.

Everything is uploaded to release "data": individual legacy tiles (PA/OH, for
app v0.3.0), the pack-b*.bin archives and manifest.json. Unchanged
files (same sha256 digest) are skipped, the manifest is uploaded last (so the
app never sees tiles that are not there yet), and assets that are no longer in
the manifest are removed.   Needs: gh (authenticated).
  python3 tool/publish_tiles.py [owner/repo] [--dir build/tiles]
"""
import hashlib, json, os, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

repo = 'sicpoe-wq/nearby-eats'
dirn = 'build/tiles'
args = sys.argv[1:]
while args:
    a = args.pop(0)
    if a == '--dir':
        dirn = args.pop(0)
    else:
        repo = a
BATCH, MAX_ASSETS = 10, 950


def gh(*a, check=True):
    return subprocess.run(['gh', *a, '-R', repo], capture_output=True, text=True, check=check)


def files_of(key, e):
    if e[3] == 1:
        return [f't_{key}.json.gz']
    return [f't_{key}_{s}.json.gz' for s in e[4]]


m = json.load(open(os.path.join(dirn, 'manifest.json')))
if m.get('schema', 1) < 3:
    sys.exit('manifest is not packed: run tool/pack_tiles.py first')
want = {'data': {}}  # everything lives in release "data": legacy tiles + packs
for key, e in m['tiles'].items():
    if e[2] == 'data':
        for f in files_of(key, e):
            want['data'][f] = os.path.join(dirn, f)
    else:
        want['data'][e[2] + '.bin'] = os.path.join(dirn, e[2] + '.bin')
for rel, files in want.items():
    if len(files) + 1 > MAX_ASSETS:
        sys.exit(f'release {rel} would have {len(files)} assets (limit 1000)')
    for f, p in files.items():
        if not os.path.exists(p):
            sys.exit('missing ' + p)


def sha(p):
    return 'sha256:' + hashlib.sha256(open(p, 'rb').read()).hexdigest()


def sync(rel, files, last=None):
    r = gh('release', 'view', rel, '--json', 'assets', check=False)
    if r.returncode:
        gh('release', 'create', rel, '--latest=false', '--title', f'Overture data tiles ({rel})',
           '--notes', 'Food & drink places from Overture Maps (rolling, rebuilt monthly). See README.')
        have = {}
    else:
        have = {a['name']: a.get('digest') for a in json.loads(r.stdout)['assets']}
    todo = [f for f, p in files.items() if have.get(f) != sha(p)]
    batches = [todo[i:i + BATCH] for i in range(0, len(todo), BATCH)]

    def up(b):
        for attempt in range(8):
            r = gh('release', 'upload', rel, *[files[f] for f in b], '--clobber', check=False)
            if r.returncode == 0:
                return
            time.sleep(90 if 'rate limit' in r.stderr.lower() else 3 * (attempt + 1))
        sys.exit(f'upload failed in {rel}: {r.stderr[:300]}')
    with ThreadPoolExecutor(2) as ex:
        list(ex.map(up, batches))
    print(f'{rel}: uploaded {len(todo)} of {len(files)} files', flush=True)
    return have


have_by_rel = {}
for rel, files in sorted(want.items()):
    have_by_rel[rel] = sync(rel, files)
# retire the per-band releases of the unpacked layout, if present
for rel in json.loads(gh('release', 'list', '--json', 'tagName', '--limit', '100').stdout):
    if rel['tagName'].startswith('data-b'):
        print('deleting obsolete release', rel['tagName'])
        r = gh('release', 'delete', rel['tagName'], '--cleanup-tag', '-y', check=False)
        if r.returncode:
            print('  could not delete (harmless, retry later):', r.stderr.strip()[:100])
# manifest last
mp = os.path.join(dirn, 'manifest.json')
have = sync('data', {'manifest.json': mp})
# prune stale assets (never the manifest)
for rel, files in want.items():
    r = gh('release', 'view', rel, '--json', 'assets')
    for a in json.loads(r.stdout)['assets']:
        n = a['name']
        if n == 'manifest.json' and rel == 'data':
            continue
        if n not in files:
            print('removing stale', rel, n)
            gh('release', 'delete-asset', rel, n, '-y')
print('published', sum(len(f) for f in want.values()), 'tile files in', len(want), 'releases')
