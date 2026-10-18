#!/usr/bin/env python3
"""Pack tile files into one archive per 5 degree longitude band (manifest schema 3).

GitHub throttles asset uploads (a few hundred per hour) and caps a release at
1000 assets, so ~3,300 separate tile files cannot be refreshed monthly. The
tiles are concatenated into ~20 `pack-b<n>.bin` files instead; the app reads
one tile with an HTTP Range request (GitHub's asset CDN supports Range).
Tiles of the v0.3.0 area (PA + OH) stay as individual files in release "data"
so the old app keeps working.

  python3 tool/pack_tiles.py build/tiles

Manifest entry (schema 3): [count, bytes, shard, sub, subs, offs]
  shard "data"      -> individual file(s) in release data (legacy; offs absent)
  shard "pack-b<n>" -> file pack-b<n>.bin in release data; offs = [offset, length]
                       (sub == 1) or a list of [offset, length] parallel to subs.
"""
import json, os, sys

d = sys.argv[1]
mp = os.path.join(d, 'manifest.json')
m = json.load(open(mp))
if m.get('schema', 1) >= 3:
    sys.exit('already packed')
packs = {}  # name -> bytearray


def add(shard, path):
    buf = packs.setdefault(shard, bytearray())
    b = open(path, 'rb').read()
    off = len(buf)
    buf += b
    os.remove(path)
    return [off, len(b)]


for key in sorted(m['tiles']):
    e = m['tiles'][key]
    shard = 'pack-' + e[2].split('data-', 1)[1] if e[2] != 'data' else 'data'
    if shard == 'data':
        continue  # legacy tile: stays an individual file
    e[2] = shard
    if e[3] == 1:
        e[:] = [e[0], e[1], shard, 1, [], add(shard, os.path.join(d, f't_{key}.json.gz'))]
    else:
        subs = sorted(e[4])
        offs = [add(shard, os.path.join(d, f't_{key}_{s}.json.gz')) for s in subs]
        e[:] = [e[0], e[1], shard, e[3], subs, offs]
for shard, buf in packs.items():
    with open(os.path.join(d, shard + '.bin'), 'wb') as fh:
        fh.write(buf)
m['schema'] = 3
m['shards'] = {s: len(b) for s, b in packs.items()}
m['shards']['data'] = sum(1 if e[3] == 1 else len(e[4]) for e in m['tiles'].values() if e[2] == 'data')
json.dump(m, open(mp, 'w'), separators=(',', ':'))
print(f"packed into {len(packs)} files, {sum(len(b) for b in packs.values())/1e6:.1f} MB; manifest {os.path.getsize(mp)/1e3:.0f} KB")
