#!/usr/bin/env python3
"""Build Nearby Eats food & drink tiles from Overture Maps places.

Reads the public Overture Maps places theme straight from S3 (anonymous, no
account or key), keeps food-and-drink places with confidence >= 0.5 that are
not permanently closed, and writes one small gzip-JSON file per 0.5 degree
grid tile plus manifest.json.

  python3 -m venv .venv && .venv/bin/pip install pyarrow
  .venv/bin/python tool/build_overture_tiles.py --region PA OH --out build/tiles
  .venv/bin/python tool/build_overture_tiles.py --region US --out build/tiles      # whole United States
  .venv/bin/python tool/build_overture_tiles.py --bbox -90 36 -80 42 --out build/tiles

Tile id: x = floor(lon*2), y = floor(lat*2)  ->  file  t_<x>_<y>.json.gz
Record keys: id, n name, la lat, lo lon, a address, p phone, w website,
             c category (Overture taxonomy primary), t app type
             (restaurant|fast_food|cafe|bar|ice_cream), q confidence.

Manifest schema 2: tiles["x_y"] = [count, gzBytes, shard, sub, subs]
  shard  hosting release ("data" or "data-<n>"), see shard_of()
  sub    1 = one file t_x_y.json.gz; 2 or 4 = dense tile split into sub x sub
         files t_x_y_<i>_<j>.json.gz (i = lon index, j = lat index)
  subs   (only when sub > 1) list of "i_j" that exist
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
# Coverage areas for --region US (west, south, east, north). Tiles with no
# food places (ocean, empty land) are never written. Aleutians west of the
# antimeridian, Guam, USVI and other territories are not included.
AREAS = {
    'CONUS': (-125.0, 24.0, -66.5, 49.5),
    'AK': (-180.0, 51.0, -129.0, 71.5),
    'HI': (-160.5, 18.5, -154.5, 22.5),
    'PR': (-67.5, 17.5, -65.0, 18.75),
}
# Longitude groups used to split a full build into parallel jobs (tile-aligned).
GROUPS = {
    'US-WEST': [(-125.0, 24.0, -104.0, 49.5)],
    'US-CENTRAL': [(-104.0, 24.0, -87.0, 49.5)],
    'US-EAST': [(-87.0, 24.0, -66.5, 49.5)],
    'US-OTHER': [AREAS['AK'], AREAS['HI'], AREAS['PR']],
}
US_COUNTRIES = {'US', 'PR'}
MAX_TILE_BYTES = 1_500_000
BAND_DEG = 5  # hosting shard = 5 degree longitude band
# Tiles already hosted in release "data" by app v0.3.0 (PA + OH boxes).
LEGACY_BOXES = [(-80.52, 39.72, -74.69, 42.27), (-84.82, 38.40, -80.52, 42.33)]
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


def tile_ids(box):
    w, so, e, n = box
    return {(x, y) for x in range(math.floor(w / TILE_DEG), math.ceil(e / TILE_DEG))
            for y in range(math.floor(so / TILE_DEG), math.ceil(n / TILE_DEG))}


LEGACY_TILES = set().union(*(tile_ids(b) for b in LEGACY_BOXES))


def shard_of(x, y):
    """Release that hosts tile (x, y). Legacy PA/OH tiles stay in "data" so
    v0.3.0 keeps working; everything else is split by 5 degree longitude
    band so no release goes near the 1000-asset limit."""
    if (x, y) in LEGACY_TILES:
        return 'data'
    return 'data-b%d' % math.floor(x * TILE_DEG / BAND_DEG)


COLUMNS = ['id', 'names', 'confidence', 'bbox', 'operating_status',
           'taxonomy', 'phones', 'websites', 'addresses', 'sources']


def row_table(d, west, east, south, north, min_conf):
    """All kept food/drink rows with xmin in [west,east) and ymin in [south,north)."""
    f = ((ds.field('bbox', 'xmin') >= west) & (ds.field('bbox', 'xmin') < east) &
         (ds.field('bbox', 'ymin') >= south) & (ds.field('bbox', 'ymin') < north) &
         (ds.field('confidence') >= min_conf))
    tb = d.to_table(filter=f, columns=COLUMNS)
    if tb.num_rows == 0:
        return tb
    first = pc.list_element(pc.struct_field(tb['taxonomy'], ['hierarchy']), 0)
    keep = pc.equal(first, 'food_and_drink')
    keep = pc.and_(pc.fill_null(keep, False),
                   pc.invert(pc.fill_null(pc.is_in(tb['operating_status'],
                             value_set=pa.array(['permanently_closed', 'temporarily_closed'])), False)))
    return tb.filter(keep)


def to_records(tb):
    out = []
    for r in tb.to_pylist():
        tx = r['taxonomy'] or {}
        hier = tx.get('hierarchy') or []
        addrs = r['addresses'] or []
        country = (addrs[0].get('country') or '').upper() if addrs else ''
        if country and country not in US_COUNTRIES:
            continue  # Canada/Mexico slivers inside border tiles
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
            'a': fmt_addr(addrs),
            'p': (r['phones'] or [None])[0], 'w': clean_url((r['websites'] or [None])[0]),
            'c': tx.get('primary'), 't': classify(hier, tx.get('primary')),
            'q': round(r['confidence'], 2),
        })
    return out


def dump(recs):
    # Drop null fields (the app treats missing keys as null) to save space.
    recs = [{k: v for k, v in r.items() if v is not None} for r in sorted(recs, key=lambda r: r['id'])]
    return gzip.compress(json.dumps(recs, separators=(',', ':'), ensure_ascii=False).encode(), 9, mtime=0)


def write_tile(out_dir, x, y, recs, max_bytes):
    """Writes t_x_y.json.gz, or sub x sub files when too big. Returns manifest entry."""
    shard = shard_of(x, y)
    data = dump(recs)
    if len(data) <= max_bytes:
        with open(os.path.join(out_dir, f't_{x}_{y}.json.gz'), 'wb') as fh:
            fh.write(data)
        return [len(recs), len(data), shard, 1]
    for sub in (2, 4):
        w, so = x * TILE_DEG, y * TILE_DEG
        step = TILE_DEG / sub
        buckets = {}
        for r in recs:
            i = min(sub - 1, int((r['lo'] - w) / step)); j = min(sub - 1, int((r['la'] - so) / step))
            buckets.setdefault((i, j), []).append(r)
        blobs = {k: dump(v) for k, v in buckets.items()}
        if sub == 4 or max(len(b) for b in blobs.values()) <= max_bytes:
            break
    for (i, j), b in blobs.items():
        with open(os.path.join(out_dir, f't_{x}_{y}_{i}_{j}.json.gz'), 'wb') as fh:
            fh.write(b)
    return [len(recs), sum(len(b) for b in blobs.values()), shard, sub,
            sorted(f'{i}_{j}' for i, j in blobs)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--release', default='latest', help='Overture release, e.g. 2026-09-23.1')
    ap.add_argument('--region', nargs='*', default=[],
                    help='US, a group (%s) or state codes: %s' % (' '.join(GROUPS), ' '.join(STATES)))
    ap.add_argument('--bbox', nargs=4, type=float, action='append', default=[],
                    metavar=('W', 'S', 'E', 'N'))
    ap.add_argument('--min-confidence', type=float, default=0.5)
    ap.add_argument('--max-tile-bytes', type=int, default=MAX_TILE_BYTES)
    ap.add_argument('--out', default='build/tiles')
    ap.add_argument('--manifest-name', default='manifest.json',
                    help='use e.g. manifest.part-west.json for a partial build that is merged later')
    ap.add_argument('--print-release', action='store_true', help='print the latest Overture release and exit')
    a = ap.parse_args()
    if a.print_release:
        print(latest_release(fs.S3FileSystem(anonymous=True, region='us-west-2')))
        return
    boxes = [tuple(b) for b in a.bbox]
    for r in a.region:
        r = r.upper()
        if r == 'US':
            boxes += list(AREAS.values())
        elif r in GROUPS:
            boxes += GROUPS[r]
        elif r in STATES:
            boxes.append(STATES[r])
        else:
            sys.exit('unknown region ' + r)
    if not boxes:
        sys.exit('give --region and/or --bbox')
    s = fs.S3FileSystem(anonymous=True, region='us-west-2')
    rel = latest_release(s) if a.release == 'latest' else a.release
    print('Overture release', rel, flush=True)
    d = ds.dataset(f'{BUCKET}/release/{rel}/theme=places/type=place/', filesystem=s, format='parquet')
    # Work list of (row y, west, east) so each S3 read is one tile row, never the whole area.
    rows = {}
    for w, so, e, n in boxes:
        for y in range(math.floor(so / TILE_DEG), math.ceil(n / TILE_DEG)):
            rows.setdefault(y, []).append((math.floor(w / TILE_DEG) * TILE_DEG,
                                           math.ceil(e / TILE_DEG) * TILE_DEG))
    os.makedirs(a.out, exist_ok=True)
    manifest_tiles, total, done = {}, 0, set()
    t0 = time.time()
    for n_row, y in enumerate(sorted(rows), 1):
        south = y * TILE_DEG
        for west, east in rows[y]:
            tb = None
            for attempt in range(5):
                try:
                    tb = row_table(d, west, east, south, south + TILE_DEG, a.min_confidence)
                    break
                except Exception as ex:  # transient S3 errors
                    print('  retry row', y, ex, flush=True)
                    time.sleep(3 * (attempt + 1))
            if tb is None:
                sys.exit(f'row {y} failed')
            by_x = {}
            for r in to_records(tb):
                by_x.setdefault(math.floor(r['lo'] / TILE_DEG), []).append(r)
            del tb
            for x, recs in by_x.items():
                if (x, y) in done:
                    continue  # overlapping boxes
                done.add((x, y))
                manifest_tiles[f'{x}_{y}'] = write_tile(a.out, x, y, recs, a.max_tile_bytes)
                total += len(recs)
        print(f'[row {n_row}/{len(rows)}] y={y} lat {south}: tiles so far {len(manifest_tiles)}, '
              f'places {total} ({time.time() - t0:.0f}s)', flush=True)
    per_shard = {}
    for k, v in manifest_tiles.items():
        per_shard[v[2]] = per_shard.get(v[2], 0) + (1 if v[3] == 1 else len(v[4]))
    manifest = {
        'schema': 2, 'overture_release': rel, 'built': time.strftime('%Y-%m-%d', time.gmtime()),
        'tile_deg': TILE_DEG, 'min_confidence': a.min_confidence, 'count': total,
        'shards': per_shard, 'tiles': manifest_tiles,
        'attribution': 'Overture Maps Foundation (data from Meta, Microsoft, Foursquare and others), CDLA-Permissive-2.0',
    }
    with open(os.path.join(a.out, a.manifest_name), 'w') as fh:
        json.dump(manifest, fh, separators=(',', ':'))
    print(f'done: {len(manifest_tiles)} tiles, {total} places, files per shard {per_shard}')


if __name__ == '__main__':
    main()
