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

## Data
© OpenStreetMap contributors (ODbL). Coverage of websites/hours/phones depends on OSM volunteers.

## Build
```
flutter pub get && flutter test && flutter build apk --debug
```
