# Nearby Eats

Android (Flutter) app that lists restaurants, fast food and cafés around you and helps you reach their menus. No API keys; no fabricated data.

**Download latest debug APK:** https://github.com/sicpoe-wq/nearby-eats/releases/latest/download/NearbyEats-debug.apk
(sideload; allow installs from unknown sources)

## Features
- GPS or typed city/ZIP location (Nominatim geocoding, debounced + throttled, identifying User-Agent)
- Restaurants from OpenStreetMap via Overpass (fallback endpoints), sorted by distance
- List + map (flutter_map, OSM tiles with attribution); filters for type, cuisine, radius, name
- Detail page: address, hours, phone, website, Call / Directions / Website / View menu
- Favorites, settings (default radius, mi/km), cached results

## v0.2.0 – faster loading, progress bar, menu/website icons
- Progress bar at the top of list/map with real stages: Getting location → Finding restaurants → Checking menus: X of N (determinate).
- Speed: saved results show instantly and refresh in the background; last-known GPS fix used first; a small 1-mile query shows results first, then the full radius; compact Overpass query (`out center tags qt`, 15 s server timeout, max 300 shown); Overpass mirrors are raced (hedged) instead of tried one by one; menu scans run in the background, nearest first, 6 at a time, 5 s timeout, and are cached on the phone (14 days; failures 1 day).
- Icons on every row and the detail header: green menu = menu link found; spinner = checking; dim crossed menu = none found; blue globe = website on record; dim globe = none. Tap to open directly. Legend: ? on the list and Settings. Filters: Has menu, Has website. Map pins get a green ring when a menu is found.

## Menus
Only real info is shown: OSM menu tags (`website:menu`, `menu:url`, …), menu links found on the restaurant's own website (anchor scan + schema.org Menu JSON-LD). If none exist, a clearly labeled web-search fallback is offered. Menu items are never invented.

## v0.3.0 – Overture Maps as a second source
OpenStreetMap misses many small-town places (e.g. Pizzas By Marchelloni, West Middlesex PA). v0.3.0 adds [Overture Maps](https://overturemaps.org) places next to OSM.
- **Merge:** at display time only. Same place = matching normalized name (case, punctuation, possessives, "Name - Town" suffixes, fuzzy match) within 100 m, or the same phone within 300 m. OSM tags win; Overture fills missing website/phone/address/cuisine; duplicates (including Overture-vs-Overture) are dropped. Each row shows an OSM / Overture / OSM + Overture badge; the detail page names the source(s).
- Overture websites feed the existing menu detection and the menu/website icons.
- **Settings → Include Overture Maps places** turns it on/off. If tiles are missing or the download fails, OSM results still show.
- Overture has no menu URL field; menus still come from each place's website.

### Overture data pipeline (free, no accounts)
`tool/build_overture_tiles.py` reads the public Overture `places` theme from S3 anonymously, keeps food-and-drink places (taxonomy `food_and_drink`) with confidence >= 0.5 that are not closed (and drops BrightQuery-only rows with no phone/website, which are business-registry junk), and writes gzip-JSON tiles plus `manifest.json`.
Record keys: `id, n name, la, lo, a address, p phone, w website, c category, t type, q confidence` (null fields are omitted).

## v0.4.0 – whole United States
- **Coverage:** all 50 states, DC and Puerto Rico (areas `CONUS`, `AK`, `HI`, `PR` in the builder). Not included: Aleutian islands west of the 180th meridian, Guam, USVI and other territories. Outside the US the app shows OpenStreetMap results only.
- **Size (Overture 2026-09-23.1):** 3,289 tiles, 1,446,972 places, 114 MB total (~100 MB in 21 pack files plus 150 loose PA/OH files). Typical tile 10-100 KB; biggest 1.46 MB (a dense tile in Los Angeles). The app downloads only the tile(s) around the search, so a normal first search in a new area is roughly 0.05-1.5 MB.
- **Country filter:** records whose address says a country other than US/PR (Canada/Mexico slivers in border tiles) are dropped.
- **Dense tiles:** tiles are 0.5 degree. If a tile is over 1.5 MB gzipped it is split into 2x2 (or 4x4) sub-tiles `t_<x>_<y>_<i>_<j>.json.gz`; the manifest lists which exist and the app fetches only the sub-tiles that touch the search circle.
- **Manifest schema 3:** `tiles["x_y"] = [count, bytes, shard, sub, subs, offs]`. Tiles of the v0.3.0 area (PA + OH, shard `data`) stay individual files in release `data`. Every other tile lives inside one of ~20 archives `pack-b<n>.bin` (n = floor(lon/5), one per 5-degree longitude band, 3-16 MB each, all in release `data`); `offs` is the `[offset, length]` of the tile (or of each sub-tile) inside the archive. The app reads one tile with an HTTP `Range` request (GitHub's asset CDN supports it; if a server ignores Range the app slices the full response) and caches it as its own file. Schema-1/2 entries still parse. The app refetches the manifest right away if its cached copy is older than schema 3, and clears cached tiles whenever the Overture release/build date changes.
- **Why packs (hosting design):** a release holds at most 1000 assets, and GitHub throttles asset uploads (we were blocked after ~2,400 uploads in a few minutes, for over an hour). ~3,300 loose files could not be refreshed reliably every month; ~170 files can. v0.3.0 keeps working because `manifest.json` still lists PA/OH tiles as individual files in `data`.
- Parsing of tiles happens off the UI thread.

Rebuild / extend coverage:
```
python3 -m venv .venv && .venv/bin/pip install pyarrow
.venv/bin/python tool/build_overture_tiles.py --region US --out build/tiles        # ~6 min, ~2 GB RAM, ~115 MB output
python3 tool/pack_tiles.py build/tiles   # bundle tiles into pack-b*.bin archives (manifest schema 3)
python3 tool/publish_tiles.py            # uploads to release data, skips unchanged files, prunes stale ones (needs gh auth)
sh tool/verify_hosted_data.sh            # manifest totals + every file returns HTTP 200 (SAMPLE=300 to sample)
```
`--region` accepts `US`, a group (`US-WEST`, `US-CENTRAL`, `US-EAST`, `US-OTHER`), state codes (see `STATES` in the script) or `--bbox W S E N` (repeatable).
**Beyond the US:** add a box to `AREAS` (e.g. `'CA': (-141, 41.6, -52, 70)`), add its country code to `US_COUNTRIES` (rename to taste), run the builder and publish. Everything else (tile ids, shards by longitude, app loader) is worldwide already. Publishing replaces the whole tile set listed in the manifest, so always build the *full* intended coverage, not just the new part.
The script defaults to the latest Overture release; pass `--release 2026-09-23.1` to pin one.

**Monthly refresh:** `.github/workflows/refresh-data.yml` runs on the 5th (and by hand under Actions -> Run workflow). It resolves the latest Overture release, builds four parallel jobs (US-WEST, US-CENTRAL, US-EAST, US-OTHER), merges their manifests, packs and publishes. A whole-US build takes about 6 minutes on one machine, so each of the four jobs is only a few minutes; the publish job uploads ~170 files (loose PA/OH tiles that did not change are skipped by sha256). Nothing in it is paid.

Live check: `VERIFY_HOSTED=1 flutter test test/hosted_data_test.dart` loads real hosted tiles for ZIP 16159 (Pizzas By Marchelloni exactly once within 1 mile) and for Chicago, a small Texas town, Honolulu, Anchorage, Miami, Los Angeles, NYC and Boise.

## Data, licenses and attribution
- Restaurants: (c) OpenStreetMap contributors, ODbL, via the Overpass API. Geocoding: Nominatim.
- Places: Overture Maps Foundation (overturemaps.org) places theme, which includes data from Meta, Microsoft, Foursquare, PinMeTo, Krick, RenderSEO, DAC, BrightQuery and AllThePlaces (CDLA Permissive 2.0; Foursquare data (c) Foursquare Labs, Inc., Apache 2.0; AllThePlaces CC0). See https://docs.overturemaps.org/attribution/. The Settings screen shows this credit.
- **ODbL share-alike note:** Overture notes that combining its data with ODbL data (OSM) can carry ODbL share-alike obligations for the combined database. Nearby Eats only merges the two on the user's phone when displaying results; it does not publish or redistribute a combined database. The hosted tiles contain Overture data only (no OSM data).
- Coverage of websites/hours/phones depends on the sources; some Overture records are wrong (e.g. a chain's website pointing at the wrong domain), so always confirm by phone.

## Build
```
flutter pub get && flutter test && flutter build apk --debug
```
