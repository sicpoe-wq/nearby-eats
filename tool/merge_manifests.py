#!/usr/bin/env python3
"""Merge manifest.part-*.json (from parallel group builds) into manifest.json.
  python3 tool/merge_manifests.py build/tiles
"""
import glob, json, os, sys
d = sys.argv[1]
parts = sorted(glob.glob(os.path.join(d, 'manifest.part-*.json')))
if not parts:
    sys.exit('no parts')
out = None
for p in parts:
    m = json.load(open(p))
    if out is None:
        out = m
        continue
    if m['overture_release'] != out['overture_release']:
        sys.exit('parts were built from different Overture releases: ' + p)
    dup = set(out['tiles']) & set(m['tiles'])
    if dup:
        sys.exit(f'overlapping tiles between parts: {sorted(dup)[:5]}')
    out['tiles'].update(m['tiles'])
out['count'] = sum(e[0] for e in out['tiles'].values())
sh = {}
for e in out['tiles'].values():
    sh[e[2]] = sh.get(e[2], 0) + (1 if e[3] == 1 else len(e[4]))
out['shards'] = sh
json.dump(out, open(os.path.join(d, 'manifest.json'), 'w'), separators=(',', ':'))
for p in parts:
    os.remove(p)
print(f"merged {len(parts)} parts: {len(out['tiles'])} tiles, {out['count']} places, shards {sh}")
