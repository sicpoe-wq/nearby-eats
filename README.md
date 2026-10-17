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

## Menus
Only real info is shown: OSM menu tags (`website:menu`, `menu:url`, …), menu links found on the restaurant's own website (anchor scan + schema.org Menu JSON-LD). If none exist, a clearly labeled web-search fallback is offered. Menu items are never invented.

## Data
© OpenStreetMap contributors (ODbL). Coverage of websites/hours/phones depends on OSM volunteers.

## Build
```
flutter pub get && flutter test && flutter build apk --debug
```
