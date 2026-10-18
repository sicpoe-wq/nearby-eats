#!/bin/sh
# Checks that the hosted manifest and every tile in it return HTTP 200.
set -e
BASE=https://github.com/sicpoe-wq/nearby-eats/releases/download/data
curl -fsSL "$BASE/manifest.json" -o /tmp/ne_manifest.json
python3 - "$BASE" <<'PY'
import json, sys, urllib.request
base = sys.argv[1]; m = json.load(open('/tmp/ne_manifest.json'))
bad = 0
for k in m['tiles']:
    try:
        code = urllib.request.urlopen(f"{base}/t_{k}.json.gz").status
    except Exception as e:
        code = e
    if code != 200: bad += 1; print('FAIL', k, code)
print(f"{len(m['tiles'])} tiles checked, {bad} failed; release {m['overture_release']}")
sys.exit(1 if bad else 0)
PY
