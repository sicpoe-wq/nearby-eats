#!/bin/sh
# Checks the hosted manifest (schema 3): loose legacy files return 200, every pack
# exists with the expected size, and tiles can be read with Range requests
# (all of them, or a random sample:  SAMPLE=300 sh tool/verify_hosted_data.sh).
set -e
BASE=https://github.com/sicpoe-wq/nearby-eats/releases/download/data
curl -fsSL "$BASE/manifest.json" -o /tmp/ne_manifest.json
python3 - "$BASE" <<'PY'
import gzip, json, os, random, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor
base = sys.argv[1]; m = json.load(open('/tmp/ne_manifest.json'))
items = []  # (url, range or None, expected records)
packsize = {}; places = 0; total = 0
for k, e in m['tiles'].items():
    places += e[0]; total += e[1]
    if e[2] == 'data':
        names = [f't_{k}.json.gz'] if e[3] == 1 else [f't_{k}_{s}.json.gz' for s in e[4]]
        items += [(f'{base}/{n}', None) for n in names]
    else:
        offs = [e[5]] if e[3] == 1 else e[5]
        for o in offs:
            items.append((f'{base}/{e[2]}.bin', tuple(o)))
            packsize[e[2]] = max(packsize.get(e[2], 0), o[0] + o[1])
print(f"manifest schema {m['schema']}: {len(m['tiles'])} tiles, {places} places, {total/1e6:.1f} MB, "
      f"{len(packsize)} packs, {len(items)} tile reads; release {m['overture_release']}")
bad = 0
for p, need in packsize.items():   # pack sizes must cover every range
    req = urllib.request.Request(f'{base}/{p}.bin', headers={'Range': 'bytes=0-0'})
    r = urllib.request.urlopen(req); cr = r.headers.get('Content-Range', '')
    size = int(cr.split('/')[-1]) if '/' in cr else 0
    if r.status != 206 or size < need: bad += 1; print('FAIL pack', p, r.status, cr, 'need', need)
sample = int(os.environ.get('SAMPLE', 0))
check = random.sample(items, sample) if sample and sample < len(items) else items
def get(it):
    u, rg = it
    for i in range(3):
        try:
            h = {'Range': f'bytes={rg[0]}-{rg[0]+rg[1]-1}'} if rg else {}
            b = urllib.request.urlopen(urllib.request.Request(u, headers=h)).read()
            if rg and len(b) != rg[1]: return it, 'short read'
            json.loads(gzip.decompress(b)); return it, 200
        except Exception as ex:
            code = ex
    return it, code
with ThreadPoolExecutor(16) as ex:
    for it, code in ex.map(get, check):
        if code != 200: bad += 1; print('FAIL', it, code)
print(f"{len(packsize)} packs and {len(check)} tile reads checked (gunzip+JSON), {bad} failed")
sys.exit(1 if bad else 0)
PY
