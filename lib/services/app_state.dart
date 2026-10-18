import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../models/place.dart';
import 'geocode_service.dart';
import 'menu_scanner.dart';
import 'menu_status_store.dart';
import 'overpass_service.dart';
import 'overture_service.dart';
import 'place_merge.dart';
import 'settings_store.dart';

enum LoadStatus { idle, locating, loading, ready, error }

/// Real loading stages shown in the progress bar.
enum LoadStage { idle, locating, finding, checking }

/// Menu availability for one place.
enum MenuState { pending, found, none }

typedef MenuInfo = ({MenuState state, String? url});

/// Pure helper (unit-tested): menu state from OSM tags + scan result.
MenuInfo menuInfoFor(Place p, MenuCheck? check) {
  final tagged = p.menuUrl;
  if (tagged != null) return (state: MenuState.found, url: tagged);
  if (p.website == null) return (state: MenuState.none, url: null);
  if (check == null) return (state: MenuState.pending, url: null);
  return check.hasMenu
      ? (state: MenuState.found, url: check.menuUrl)
      : (state: MenuState.none, url: null);
}

class AppState extends ChangeNotifier {
  AppState(
      {OverpassService? overpass,
      GeocodeService? geocoder,
      SettingsStore? store,
      OvertureService? overture,
      MenuStatusStore? menuStore,
      MenuScanner? scanner})
      : _menuStore = menuStore ?? MenuStatusStore(),
        _scanner = scanner ?? MenuScanner(),
        overpassService = overpass ?? OverpassService(),
        overtureService = overture ?? OvertureService(),
        geocoder = geocoder ?? GeocodeService(),
        _store = store ?? SettingsStore();

  final OverpassService overpassService;
  final OvertureService overtureService;
  final GeocodeService geocoder;
  final SettingsStore _store;
  final MenuStatusStore _menuStore;
  final MenuScanner _scanner;

  // --- progress ---
  bool _locating = false, _finding = false, _checking = false;
  LoadStage get stage => _locating
      ? LoadStage.locating
      : _finding
          ? LoadStage.finding
          : _checking
              ? LoadStage.checking
              : LoadStage.idle;
  int menuTotal = 0, menuDone = 0;
  bool get busy => stage != LoadStage.idle;
  String get stageLabel => switch (stage) {
        LoadStage.idle => '',
        LoadStage.locating => 'Getting location…',
        LoadStage.finding => 'Finding restaurants…',
        LoadStage.checking => 'Checking menus: $menuDone of $menuTotal',
      };

  /// 0..1 when determinate (menu checks), null for indeterminate stages.
  double? get progress => stage == LoadStage.checking && menuTotal > 0
      ? (menuDone / menuTotal).clamp(0.0, 1.0)
      : null;

  Map<String, MenuCheck> checks = {};
  final Map<String, Future<MenuCheck>> _inflight = {};
  int _loadGen = 0; // bumps on each load
  int _menuGen = 0; // bumps on each menu run; stale runs stop
  int _unsaved = 0;
  bool hasMenuOnly = false, hasWebsiteOnly = false;

  int radiusM = 2000;
  bool overtureEnabled = true;
  List<Place> _osm = []; // latest OpenStreetMap list for the current spot
  List<Place> _ovt = []; // Overture list for the current spot
  DistUnit unit = DistUnit.mi;
  double? lat, lon;
  String locationLabel = '';
  LoadStatus status = LoadStatus.idle;
  String? error;
  bool showingCache = false;
  DateTime? cachedAt;
  bool permissionPermanentlyDenied = false;

  List<Place> all = [];
  List<Place> favorites = [];

  // filters
  Set<PlaceType> types = {};
  String? cuisine;
  String nameQuery = '';

  Future<void> init() async {
    final s = await _store.load();
    radiusM = s.radiusM;
    unit = s.unit;
    overtureEnabled = await _store.loadOverture();
    favorites = await _store.loadFavorites();
    checks = await _menuStore.load();
    notifyListeners();
    await useGps();
  }

  Future<void> setDefaults(int r, DistUnit u) async {
    radiusM = r;
    unit = u;
    await _store.save(r, u);
    notifyListeners();
  }

  Future<void> setOvertureEnabled(bool v) async {
    overtureEnabled = v;
    await _store.saveOverture(v);
    notifyListeners();
    if (lat != null) await refresh();
  }

  Future<void> setRadius(int r) async {
    radiusM = r;
    notifyListeners();
    if (lat != null) await refresh();
  }

  List<String> get cuisineOptions {
    final c = <String, int>{};
    for (final p in all) {
      for (final x in p.cuisines) {
        c[x] = (c[x] ?? 0) + 1;
      }
    }
    final keys = c.keys.toList()..sort((a, b) => c[b]!.compareTo(c[a]!));
    return keys;
  }

  List<Place> get filtered {
    final q = nameQuery.trim().toLowerCase();
    return all.where((p) {
      if (types.isNotEmpty && !types.contains(p.type)) return false;
      if (cuisine != null && !p.cuisines.contains(cuisine)) return false;
      if (q.isNotEmpty && !p.name.toLowerCase().contains(q)) return false;
      if (hasWebsiteOnly && p.website == null) return false;
      if (hasMenuOnly && menuInfo(p).state != MenuState.found) return false;
      return true;
    }).toList();
  }

  MenuInfo menuInfo(Place p) => menuInfoFor(p, checks[p.id]);

  void setHasMenuOnly(bool v) {
    hasMenuOnly = v;
    notifyListeners();
  }

  void setHasWebsiteOnly(bool v) {
    hasWebsiteOnly = v;
    notifyListeners();
  }

  /// Cached or fresh website scan for [p] (deduplicated, persisted).
  Future<MenuCheck> ensureCheck(Place p,
      {Duration timeout = const Duration(seconds: 6)}) {
    final have = checks[p.id];
    if (have != null && have.isFresh()) return Future.value(have);
    final site = p.website ?? p.menuUrl;
    if (site == null) {
      return Future.value(MenuCheck(ok: true, scan: MenuScanResult([], [])));
    }
    return _inflight[p.id] ??= () async {
      MenuCheck c;
      try {
        c = MenuCheck(ok: true, scan: await _scanner.scan(site, timeout: timeout));
      } catch (_) {
        c = MenuCheck(ok: false, scan: MenuScanResult([], []));
      }
      checks[p.id] = c;
      _inflight.remove(p.id);
      if (++_unsaved >= 10) {
        _unsaved = 0;
        _menuStore.save(checks);
      }
      notifyListeners();
      return c;
    }();
  }

  /// Background menu scans: nearest first, limited concurrency, cached
  /// results are instant, progress is reported as done/total.
  Future<void> _runMenuChecks() async {
    final gen = ++_menuGen;
    final seen = <String>{};
    final todo = <Place>[
      for (final p in [...all, ...favorites])
        if (seen.add(p.id) && p.menuUrl == null && p.website != null) p
    ];
    final queue = todo.where((p) => !(checks[p.id]?.isFresh() ?? false)).toList();
    menuTotal = todo.length;
    menuDone = todo.length - queue.length;
    if (queue.isEmpty) {
      if (gen == _menuGen) _checking = false;
      notifyListeners();
      return;
    }
    _checking = true;
    notifyListeners();
    var next = 0;
    Future<void> worker() async {
      while (gen == _menuGen && next < queue.length) {
        final p = queue[next++];
        await ensureCheck(p, timeout: const Duration(seconds: 5));
        if (gen != _menuGen) return;
        menuDone++;
        notifyListeners();
      }
    }

    await Future.wait([for (var i = 0; i < 6; i++) worker()]);
    if (gen == _menuGen) {
      _checking = false;
      _unsaved = 0;
      await _menuStore.save(checks);
      notifyListeners();
    }
  }

  void setFilters({Set<PlaceType>? t, String? cuisine, bool clearCuisine = false, String? name}) {
    if (t != null) types = t;
    if (clearCuisine) this.cuisine = null;
    if (cuisine != null) this.cuisine = cuisine;
    if (name != null) nameQuery = name;
    notifyListeners();
  }

  Future<void> useGps() async {
    status = LoadStatus.locating;
    _locating = true;
    _finding = false;
    _loadGen++;
    _menuGen++;
    _checking = false;
    error = null;
    permissionPermanentlyDenied = false;
    notifyListeners();
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw Exception('Location services are turned off. Turn on GPS or search a city/ZIP.');
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        permissionPermanentlyDenied = true;
        throw Exception('Location permission is blocked. Enable it in Settings, or search a city/ZIP.');
      }
      if (perm == LocationPermission.denied) {
        throw Exception('Location permission denied. Search a city or ZIP instead.');
      }
      // Fast path: the last known fix is available instantly.
      Position? pos = await Geolocator.getLastKnownPosition();
      final usedLast = pos != null;
      if (pos == null) {
        try {
          pos = await Geolocator.getCurrentPosition(
                  locationSettings: const LocationSettings(
                      accuracy: LocationAccuracy.low))
              .timeout(const Duration(seconds: 10));
        } catch (_) {
          throw Exception('Could not get your location. Try again or search a city/ZIP.');
        }
      }
      lat = pos.latitude;
      lon = pos.longitude;
      locationLabel = 'Current location';
      _locating = false;
      if (usedLast) unawaited(_refineGps(pos));
      await refresh();
    } catch (e) {
      status = LoadStatus.error;
      _locating = false;
      error = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  /// After showing results for the last known fix, get a current fix in the
  /// background and reload only if the user actually moved (> 500 m).
  Future<void> _refineGps(Position used) async {
    try {
      final cur = await Geolocator.getCurrentPosition(
              locationSettings:
                  const LocationSettings(accuracy: LocationAccuracy.low))
          .timeout(const Duration(seconds: 12));
      if (locationLabel != 'Current location') return; // user chose a city
      if (haversineMeters(used.latitude, used.longitude, cur.latitude,
              cur.longitude) >
          500) {
        lat = cur.latitude;
        lon = cur.longitude;
        await refresh();
      }
    } catch (_) {}
  }

  Future<void> useCoordinates(double la, double lo, String label) async {
    lat = la;
    lon = lo;
    locationLabel = label;
    await refresh();
  }

  static const _freshMinutes = 10;
  static const _maxResults = 300;

  /// Show OSM results merged with Overture (if on) for the current spot.
  void _showMerged() {
    final merged = overtureEnabled && _ovt.isNotEmpty
        ? mergePlaces(_osm, _ovt)
        : _osm;
    _setPlaces(merged);
  }

  void _setPlaces(List<Place> p) {
    all = p.length > _maxResults ? p.sublist(0, _maxResults) : p;
    if (cuisine != null && !cuisineOptions.contains(cuisine)) cuisine = null;
  }

  Future<void> refresh({bool force = false}) async {
    if (lat == null || lon == null) return;
    final gen = ++_loadGen;
    _menuGen++;
    _checking = false;
    final la = lat!, lo = lon!, r = radiusM;
    status = LoadStatus.loading;
    _finding = true;
    error = null;
    notifyListeners();
    bool stale() => gen != _loadGen;
    _osm = [];
    _ovt = [];
    // Overture runs in parallel with OpenStreetMap; it never throws, and a
    // failure just means OSM-only results.
    Future<void> ovtFuture = Future.value();
    if (overtureEnabled) {
      ovtFuture = () async {
        try {
          final r2 = await overtureService.load(la, lo, r);
          if (stale()) return;
          _ovt = r2;
          if (r2.isNotEmpty) {
            _showMerged();
            status = LoadStatus.ready;
            notifyListeners();
          }
        } catch (_) {}
      }();
    }
    try {
      // 1) Saved results for this spot: show instantly.
      final c = await overpassService.cached(la, lo, r);
      if (stale()) return;
      if (c != null) {
        _osm = c.places;
        _showMerged();
        showingCache = true;
        cachedAt = c.savedAt;
        status = LoadStatus.ready;
        if (!force && c.age.inMinutes < _freshMinutes) {
          await ovtFuture;
          if (stale()) return;
          _finding = false;
          notifyListeners();
          unawaited(_runMenuChecks());
          return;
        }
        notifyListeners();
      } else if (r > 1000) {
        // 2) Nothing saved: query a small radius first so something appears
        //    fast, then expand to the full radius.
        try {
          final quick = await overpassService.fetchLive(la, lo, 1000, limit: 120);
          if (stale()) return;
          if (quick.isNotEmpty) {
            _osm = quick;
            _showMerged();
            showingCache = false;
            cachedAt = null;
            status = LoadStatus.ready;
            notifyListeners();
          }
        } catch (_) {}
      }
      // 3) Full live query (hedged across mirrors); list stays visible.
      try {
        final live = await overpassService.fetchLive(la, lo, r);
        if (stale()) return;
        _osm = live;
        _showMerged();
        showingCache = false;
        cachedAt = null;
        status = LoadStatus.ready;
      } catch (e) {
        if (stale()) return;
        await ovtFuture;
        if (stale()) return;
        if (all.isEmpty) rethrow;
        showingCache = cachedAt != null; // keep what we already show
        status = LoadStatus.ready;
      }
      await ovtFuture;
      if (stale()) return;
      _finding = false;
      notifyListeners();
      unawaited(_runMenuChecks());
    } catch (e) {
      if (stale()) return;
      status = LoadStatus.error;
      _finding = false;
      error = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  bool isFavorite(Place p) => favorites.any((f) => f.id == p.id);

  Future<void> toggleFavorite(Place p) async {
    if (isFavorite(p)) {
      favorites.removeWhere((f) => f.id == p.id);
    } else {
      favorites.add(p);
    }
    await _store.saveFavorites(favorites);
    notifyListeners();
  }
}
