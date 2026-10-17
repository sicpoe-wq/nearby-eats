import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import '../models/place.dart';
import 'geocode_service.dart';
import 'overpass_service.dart';
import 'settings_store.dart';

enum LoadStatus { idle, locating, loading, ready, error }

class AppState extends ChangeNotifier {
  AppState({OverpassService? overpass, GeocodeService? geocoder, SettingsStore? store})
      : overpassService = overpass ?? OverpassService(),
        geocoder = geocoder ?? GeocodeService(),
        _store = store ?? SettingsStore();

  final OverpassService overpassService;
  final GeocodeService geocoder;
  final SettingsStore _store;

  int radiusM = 2000;
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
    favorites = await _store.loadFavorites();
    notifyListeners();
    await useGps();
  }

  Future<void> setDefaults(int r, DistUnit u) async {
    radiusM = r;
    unit = u;
    await _store.save(r, u);
    notifyListeners();
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
      return true;
    }).toList();
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
      Position pos;
      try {
        pos = await Geolocator.getCurrentPosition(
                locationSettings: const LocationSettings(
                    accuracy: LocationAccuracy.medium))
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        final last = await Geolocator.getLastKnownPosition();
        if (last == null) throw Exception('Could not get your location. Try again or search a city/ZIP.');
        pos = last;
      }
      lat = pos.latitude;
      lon = pos.longitude;
      locationLabel = 'Current location';
      await refresh();
    } catch (e) {
      status = LoadStatus.error;
      error = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  Future<void> useCoordinates(double la, double lo, String label) async {
    lat = la;
    lon = lo;
    locationLabel = label;
    await refresh();
  }

  Future<void> refresh({bool force = false}) async {
    if (lat == null || lon == null) return;
    status = LoadStatus.loading;
    error = null;
    notifyListeners();
    try {
      final r = await overpassService.fetch(lat!, lon!, radiusM, forceRefresh: force);
      all = r.places;
      showingCache = r.fromCache;
      cachedAt = r.cachedAt;
      if (cuisine != null && !cuisineOptions.contains(cuisine)) cuisine = null;
      status = LoadStatus.ready;
    } catch (e) {
      status = LoadStatus.error;
      error = e.toString().replaceFirst('Exception: ', '');
    }
    notifyListeners();
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
