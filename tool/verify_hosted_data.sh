#!/bin/sh
# Checks the hosted manifest and that tile files return HTTP 200 (all of them,
# or a random sample:  SAMPLE=300 sh tool/verify_hosted_data.sh).
set -e
BASE=https://github.com/sicpoe-wq/nearby-eats/releases/download
curl -fsSL "$BASE/data/manifest.json" -o /tmp/ne_manifest.json
python3 - "$BASE" <<'PY'
import json, os, random, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor
base = sys.argv[1]; m = json.load(open('/tmp/ne_manifest.json'))
urls = []; total_bytes = 0; places = 0
for k, e in m['tiles'].items():
    places += e[0]; total_bytes += e[1]
    names = [f't_{k}.json.gz'] if e[3] == 1 else [f't_{k}_{s}.json.gz' for s in e[4]]
    urls += [f'{base}/{e[2]}/{n}' for n in names]
exp = sum(m.get('shards', {}).values())
print(f"manifest: {len(m['tiles'])} tiles, {len(urls)} files, {places} places, {total_bytes/1e6:.1f} MB; "
      f"shards {m.get('shards')}; release {m['overture_release']}")
if exp and exp != len(urls): print('FAIL shard totals do not match', exp, len(urls)); sys.exit(1)
sample = int(os.environ.get('SAMPLE', 0))
check = random.sample(urls, sample) if sample and sample < len(urls) else urls
def head(u):
    for i in range(3):
        try:
            req = urllib.request.Request(u, headers={'Range': 'bytes=0-0'})
            return u, urllib.request.urlopen(req).status
        except urllib.error.HTTPError as e:
            if e.code == 416: return u, 200
            code = e.code
        except Exception as e:
            code = e
    return u, code
bad = 0
with ThreadPoolExecutor(16) as ex:
    for u, code in ex.map(head, check):
        if code not in (200, 206): bad += 1; print('FAIL', u, code)
print(f"{len(check)} files checked, {bad} failed")
sys.exit(1 if bad else 0)
PY
