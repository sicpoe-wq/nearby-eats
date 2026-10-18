#!/usr/bin/env python3
"""Build Nearby Eats food & drink tiles from Overture Maps places.

Reads the public Overture Maps places theme straight from S3 (anonymous, no
account or key), keeps food-and-drink places with confidence >= 0.5 that are
not permanently closed, and writes one small gzip-JSON file per 0.5 degree
grid tile plus manifest.json.

  python3 -m venv .venv && .venv/bin/pip install pyarrow
  .venv/bin/python tool/build_overture_tiles.py --region PA OH --out build/tiles
  .venv/bin/python tool/build_overture_tiles.py --region NY NJ --out build/tiles   # more states
  .venv/bin/python tool/build_overture_tiles.py --bbox -90 36 -80 42 --out build/tiles

Tile id: x = floor(lon*2), y = floor(lat*2)  ->  file  t_<x>_<y>.json.gz
Record keys: id, n name, la lat, lo lon, a address, p phone, w website,
             c category (Overture taxonomy primary), t app type
             (restaurant|fast_food|cafe|bar|ice_cream), q confidence, s sources.
"""
import argparse, gzip, json, math, os, sys, time
from urllib.parse import urlsplit, urlunsplit
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.dataset as ds
import pyarrow.fs as fs

TILE_DEG = 0.5
BUCKET = 'overturemaps-us-west-2'
# Approximate state bounding boxes: west, south, east, north
STATES = {
    'PA': (-80.52, 39.72, -74.69, 42.27), 'OH': (-84.82, 38.40, -80.52, 42.33),
    'NY': (-79.77, 40.48, -71.85, 45.02), 'NJ': (-75.56, 38.93, -73.89, 41.36),
    'WV': (-82.65, 37.20, -77.72, 40.64), 'MD': (-79.49, 37.91, -75.05, 39.72),
    'DE': (-75.79, 38.45, -75.05, 39.84), 'MI': (-90.42, 41.70, -82.12, 48.31),
    'IN': (-88.10, 37.77, -84.78, 41.76), 'KY': (-89.57, 36.50, -81.96, 39.15),
    'VA': (-83.68, 36.54, -75.24, 39.47), 'CT': (-73.73, 40.98, -71.79, 42.05),
    'MA': (-73.51, 41.24, -69.93, 42.89), 'IL': (-91.51, 36.97, -87.02, 42.51),
}
DRINK_BAR = {'alcoholic_beverage_venue'}
CAFE_WORDS = ('cafe', 'coffee', 'tea', 'bakery', 'dessert', 'juice', 'smoothie',
              'bubble', 'donut', 'bagel', 'non_alcoholic_beverage_venue')
GENERIC_PRIMARY = {'restaurant', 'casual_eatery', 'food_and_drink', 'eatery'}


def classify(hier, primary):
    """Map an Overture taxonomy to the app's amenity types."""
    h = list(hier or [])
    p = primary or (h[-1] if h else '')
    if any(x in DRINK_BAR or x.endswith(('_bar', '_pub')) or x in ('bar', 'pub', 'brewery') for x in h + [p]):
        return 'bar'
    if 'ice_cream' in p or 'frozen_yogurt' in p or 'gelato' in p:
        return 'ice_cream'
    if any(w in x for x in h + [p] for w in ('fast_food', 'food_stand', 'food_truck', 'hot_dog', 'sandwich_shop')):
        return 'fast_food'
    if any(w in x for x in h + [p] for w in CAFE_WORDS):
        return 'cafe'
    return 'restaurant'


def latest_release(s):
    sel = fs.FileSelector(f'{BUCKET}/release/', recursive=False)
    names = sorted(i.base_name for i in s.get_file_info(sel) if i.base_name[:2] == '20')
    return names[-1]


def clean_url(u):
    """Drop tracking query strings (utm_*, y_source) to keep tiles small."""
    if not u:
        return None
    try:
        sp = urlsplit(u.strip())
    except ValueError:
        return None
    if 'utm_' in sp.query or 'y_source' in sp.query:
        sp = sp._replace(query='', fragment='')
    return urlunsplit(sp)


def fmt_addr(addrs):
    if not addrs:
        return None
    a = addrs[0]
    parts = [a.get('freeform'), a.get('locality'), a.get('region'), a.get('postcode')]
    parts = [x.strip() for x in parts if x and x.strip()]
    return ', '.join(parts) or None


def tile_records(d, x, y, min_conf):
    west, south = x * TILE_DEG, y * TILE_DEG
    east, north = west + TILE_DEG, south + TILE_DEG
    f = ((ds.field('bbox', 'xmin') >= west) & (ds.field('bbox', 'xmin') < east) &
         (ds.field('bbox', 'ymin') >= south) & (ds.field('bbox', 'ymin') < north) &
         (ds.field('confidence') >= min_conf))
    tb = d.to_table(filter=f, columns=['id', 'names', 'confidence', 'bbox', 'operating_status',
                                       'taxonomy', 'phones', 'websites', 'addresses', 'sources'])
    out = []
    for r in tb.to_pylist():
        tx = r['taxonomy'] or {}
        hier = tx.get('hierarchy') or []
        if not hier or hier[0] != 'food_and_drink':
            continue
        if r['operating_status'] in ('permanently_closed', 'temporarily_closed'):
            continue
        name = ((r['names'] or {}).get('primary') or '').strip()
        if not name:
            continue
        srcs = sorted({s['dataset'] for s in (r['sources'] or []) if s.get('dataset')
                       and s['dataset'] not in ('Overture', 'Overture-signals')})
        # BrightQuery-only rows with no phone/website are business-registry
        # records (e.g. a fuel company tagged "restaurant"), not eateries.
        if srcs == ['BrightQuery'] and not r['phones'] and not r['websites']:
            continue
        out.append({
            'id': r['id'], 'n': name,
            'la': round(r['bbox']['ymin'], 6), 'lo': round(r['bbox']['xmin'], 6),
            'a': fmt_addr(r['addresses']),
            'p': (r['phones'] or [None])[0], 'w': clean_url((r['websites'] or [None])[0]),
            'c': tx.get('primary'), 't': classify(hier, tx.get('primary')),
            'q': round(r['confidence'], 2), 's': srcs,
        })
    out.sort(key=lambda r: r['id'])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--release', default='latest', help='Overture release, e.g. 2026-09-23.1')
    ap.add_argument('--region', nargs='*', default=[], help='state codes: ' + ' '.join(STATES))
    ap.add_argument('--bbox', nargs=4, type=float, action='append', default=[],
                    metavar=('W', 'S', 'E', 'N'))
    ap.add_argument('--min-confidence', type=float, default=0.5)
    ap.add_argument('--out', default='build/tiles')
    a = ap.parse_args()
    boxes = [STATES[r.upper()] for r in a.region] + [tuple(b) for b in a.bbox]
    if not boxes:
        sys.exit('give --region and/or --bbox')
    s = fs.S3FileSystem(anonymous=True, region='us-west-2')
    rel = latest_release(s) if a.release == 'latest' else a.release
    print('Overture release', rel)
    d = ds.dataset(f'{BUCKET}/release/{rel}/theme=places/type=place/', filesystem=s, format='parquet')
    tiles = set()
    for w, so, e, n in boxes:
        for x in range(math.floor(w / TILE_DEG), math.floor(e / TILE_DEG) + 1):
            for y in range(math.floor(so / TILE_DEG), math.floor(n / TILE_DEG) + 1):
                tiles.add((x, y))
    os.makedirs(a.out, exist_ok=True)
    manifest_tiles, total = {}, 0
    t0 = time.time()
    for i, (x, y) in enumerate(sorted(tiles), 1):
        recs = None
        for attempt in range(4):
            try:
                recs = tile_records(d, x, y, a.min_confidence)
                break
            except Exception as ex:  # transient S3 errors
                print('  retry', x, y, ex)
                time.sleep(2 * (attempt + 1))
        if recs is None:
            sys.exit(f'tile {x},{y} failed')
        if recs:
            data = gzip.compress(json.dumps(recs, separators=(',', ':'), ensure_ascii=False).encode(), 9, mtime=0)
            with open(os.path.join(a.out, f't_{x}_{y}.json.gz'), 'wb') as fh:
                fh.write(data)
            manifest_tiles[f'{x}_{y}'] = [len(recs), len(data)]
            total += len(recs)
        print(f'[{i}/{len(tiles)}] tile {x},{y}: {len(recs)} places ({time.time() - t0:.0f}s)', flush=True)
    manifest = {
        'schema': 1, 'overture_release': rel, 'built': time.strftime('%Y-%m-%d', time.gmtime()),
        'tile_deg': TILE_DEG, 'min_confidence': a.min_confidence, 'count': total,
        'tiles': manifest_tiles,
        'attribution': 'Overture Maps Foundation (data from Meta, Microsoft, Foursquare and others), CDLA-Permissive-2.0',
    }
    with open(os.path.join(a.out, 'manifest.json'), 'w') as fh:
        json.dump(manifest, fh, separators=(',', ':'))
    print(f'done: {len(manifest_tiles)} tiles, {total} places')


if __name__ == '__main__':
    main()
