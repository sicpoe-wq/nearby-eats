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
- **Size (Overture 2026-09-23.1):** 3,289 tiles, 1,446,972 places, 114 MB total (3,314 hosted files incl. 25 sub-tile files). Typical tile 10-100 KB; biggest 1.46 MB (a dense tile in Los Angeles). The app downloads only the tile(s) around the search, so a normal first search in a new area is roughly 0.05-1.5 MB.
- **Country filter:** records whose address says a country other than US/PR (Canada/Mexico slivers in border tiles) are dropped.
- **Dense tiles:** tiles are 0.5 degree. If a tile is over 1.5 MB gzipped it is split into 2x2 (or 4x4) sub-tiles `t_<x>_<y>_<i>_<j>.json.gz`; the manifest lists which exist and the app fetches only the sub-tiles that touch the search circle.
- **Manifest schema 2:** `tiles["x_y"] = [count, bytes, release, sub, subs?]`. `release` is the GitHub release hosting that tile. The app maps tile -> URL `https://github.com/sicpoe-wq/nearby-eats/releases/download/<release>/<file>`. Schema-1 entries (`[count, bytes]`) still parse (they mean release `data`, no split). The app refetches the manifest right away if its cached copy is older than schema 2, and clears cached tiles whenever the Overture release/build date changes.
- **Hosting (GitHub limit: 1000 assets per release):** tiles are sharded by 5-degree longitude band into releases `data-b<n>` (n = floor(lon/5), e.g. `data-b-17` = -85..-80). Tiles that v0.3.0 already used (the PA + OH boxes) stay in release `data` next to `manifest.json`, so v0.3.0 keeps working for PA/OH. The biggest shard has ~440 files. The publisher refuses to continue if a release would exceed 950 files.
- Parsing of tiles happens off the UI thread.

Rebuild / extend coverage:
```
python3 -m venv .venv && .venv/bin/pip install pyarrow
.venv/bin/python tool/build_overture_tiles.py --region US --out build/tiles        # ~15 min, ~2 GB RAM, ~115 MB output
python3 tool/publish_tiles.py            # uploads to releases data / data-b*, skips unchanged files, prunes stale ones (needs gh auth)
sh tool/verify_hosted_data.sh            # manifest totals + every file returns HTTP 200 (SAMPLE=300 to sample)
```
`--region` accepts `US`, a group (`US-WEST`, `US-CENTRAL`, `US-EAST`, `US-OTHER`), state codes (see `STATES` in the script) or `--bbox W S E N` (repeatable).
**Beyond the US:** add a box to `AREAS` (e.g. `'CA': (-141, 41.6, -52, 70)`), add its country code to `US_COUNTRIES` (rename to taste), run the builder and publish. Everything else (tile ids, shards by longitude, app loader) is worldwide already. Publishing replaces the whole tile set listed in the manifest, so always build the *full* intended coverage, not just the new part.
The script defaults to the latest Overture release; pass `--release 2026-09-23.1` to pin one.

**Monthly refresh:** `.github/workflows/refresh-data.yml` runs on the 5th (and by hand under Actions -> Run workflow). It resolves the latest Overture release, builds four parallel jobs (US-WEST, US-CENTRAL, US-EAST, US-OTHER), merges their manifests and publishes. Each build job takes about 5-15 minutes (limit set to 5 h); nothing in it is paid.

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
