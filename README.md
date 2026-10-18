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
`tool/build_overture_tiles.py` reads the public Overture `places` theme from S3 anonymously, keeps food-and-drink places (taxonomy `food_and_drink`) with confidence >= 0.5 that are not closed (and drops BrightQuery-only rows with no phone/website, which are business-registry junk), and writes one gzip-JSON file per 0.5 degree tile (`t_<floor(lon*2)>_<floor(lat*2)>.json.gz`) plus `manifest.json`.
Record keys: `id, n name, la, lo, a address, p phone, w website, c category, t type, q confidence, s sources`.

Hosting: GitHub release **`data`** (rolling, not marked latest): `https://github.com/sicpoe-wq/nearby-eats/releases/download/data/<file>`. The app downloads only the tiles covering the search radius, caches them on the phone, and checks `manifest.json` about every 30 days; a new data version clears the cached tiles. Current coverage: bounding boxes of Pennsylvania and Ohio (~152 tiles, 12 MB total, typically 50-300 KB per tile; the biggest city tile is under 1 MB).

Rebuild / extend coverage:
```
python3 -m venv .venv && .venv/bin/pip install pyarrow
.venv/bin/python tool/build_overture_tiles.py --region PA OH NY --out build/tiles   # add state codes (see STATES in the script) or --bbox W S E N
sh tool/publish_tiles.sh            # uploads to release "data" and prunes stale tiles (needs gh auth)
sh tool/verify_hosted_data.sh       # every tile in the manifest returns HTTP 200
```
Edit `tool/regions.txt` to change the monthly default. The GitHub Action `.github/workflows/refresh-data.yml` rebuilds and publishes monthly (5th) and can be run by hand with a custom region list (Actions -> Refresh Overture data tiles -> Run workflow).
The script defaults to the latest Overture release; pass `--release 2026-09-23.1` to pin one.

Live check: `VERIFY_HOSTED=1 flutter test test/hosted_data_test.dart` loads the real tile for ZIP 16159 and asserts Pizzas By Marchelloni is returned within 1 mile exactly once.

## Data, licenses and attribution
- Restaurants: (c) OpenStreetMap contributors, ODbL, via the Overpass API. Geocoding: Nominatim.
- Places: Overture Maps Foundation (overturemaps.org) places theme, which includes data from Meta, Microsoft, Foursquare, PinMeTo, Krick, RenderSEO, DAC, BrightQuery and AllThePlaces (CDLA Permissive 2.0; Foursquare data (c) Foursquare Labs, Inc., Apache 2.0; AllThePlaces CC0). See https://docs.overturemaps.org/attribution/. The Settings screen shows this credit.
- **ODbL share-alike note:** Overture notes that combining its data with ODbL data (OSM) can carry ODbL share-alike obligations for the combined database. Nearby Eats only merges the two on the user's phone when displaying results; it does not publish or redistribute a combined database. The hosted tiles contain Overture data only (no OSM data).
- Coverage of websites/hours/phones depends on the sources; some Overture records are wrong (e.g. a chain's website pointing at the wrong domain), so always confirm by phone.

## Build
```
flutter pub get && flutter test && flutter build apk --debug
```
