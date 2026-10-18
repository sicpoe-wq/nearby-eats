import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/place.dart';
import 'cache_store.dart';

const userAgent = 'NearbyEats/0.3 (Android app; github.com/sicpoe-wq/nearby-eats)';

class OverpassService {
  OverpassService(
      {http.Client? client,
      CacheStore? cache,
      this.hedgeDelay = const Duration(seconds: 2),
      this.requestTimeout = const Duration(seconds: 20)})
      : _client = client ?? http.Client(),
        _cache = cache ?? CacheStore();

  final http.Client _client;
  final CacheStore _cache;
  final Duration hedgeDelay;
  final Duration requestTimeout;

  static const endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.openstreetmap.fr/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
  ];

  static String buildQuery(double lat, double lon, int radiusM,
      {int limit = 400, int serverTimeout = 15}) {
    const sel = 'restaurant|fast_food|cafe|bar|pub|food_court|ice_cream';
    // qt = unsorted-by-id quadtile order: cheapest output order for Overpass.
    return '[out:json][timeout:$serverTimeout];'
        'nwr["amenity"~"^($sel)\$"]["name"](around:$radiusM,$lat,$lon);'
        'out center tags qt $limit;';
  }

  static String cacheKey(double lat, double lon, int radiusM) =>
      'overpass_${lat.toStringAsFixed(3)}_${lon.toStringAsFixed(3)}_$radiusM';

  /// Saved results for this spot (any age), or null.
  Future<({List<Place> places, DateTime savedAt, Duration age})?> cached(
      double lat, double lon, int radiusM) async {
    final c = await _cache.read(cacheKey(lat, lon, radiusM));
    if (c == null) return null;
    try {
      return (
        places: parseOverpass(c.data as Map<String, dynamic>, lat, lon),
        savedAt: c.savedAt,
        age: c.age
      );
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _post(String ep, String body) async {
    final res = await _client
        .post(Uri.parse(ep),
            headers: {
              'User-Agent': userAgent,
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: {'data': body})
        .timeout(requestTimeout);
    if (res.statusCode != 200) throw 'HTTP ${res.statusCode} from $ep';
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    if (json is! Map<String, dynamic> || json['elements'] is! List) {
      throw 'Bad response from $ep';
    }
    return json;
  }

  /// Hedged request: start with the first mirror; start the next one after
  /// [hedgeDelay] OR immediately if the previous one failed. First valid
  /// answer wins, so one slow/dead mirror no longer blocks the others.
  Future<Map<String, dynamic>> _hedged(String body) {
    final done = Completer<Map<String, dynamic>>();
    final launched = <int>{};
    var failed = 0;
    Object? lastError;
    void launch(int i) {
      if (i >= endpoints.length || done.isCompleted || !launched.add(i)) return;
      Timer(hedgeDelay, () => launch(i + 1));
      _post(endpoints[i], body).then((j) {
        if (!done.isCompleted) done.complete(j);
      }).catchError((Object e) {
        lastError = e;
        failed++;
        if (failed >= endpoints.length) {
          if (!done.isCompleted) {
            done.completeError(
                Exception('Could not reach OpenStreetMap servers ($lastError)'));
          }
        } else {
          launch(i + 1);
        }
      });
    }

    launch(0);
    return done.future;
  }

  /// Live query (hedged across mirrors). Writes the cache. Throws if all fail.
  Future<List<Place>> fetchLive(double lat, double lon, int radiusM,
      {int limit = 400}) async {
    final json = await _hedged(buildQuery(lat, lon, radiusM, limit: limit));
    await _cache.write(cacheKey(lat, lon, radiusM), json);
    return parseOverpass(json, lat, lon);
  }

  /// Convenience: fresh cache -> live -> stale cache fallback.
  Future<({List<Place> places, bool fromCache, DateTime? cachedAt})> fetch(
      double lat, double lon, int radiusM,
      {bool forceRefresh = false}) async {
    final c = await cached(lat, lon, radiusM);
    if (!forceRefresh && c != null && c.age.inMinutes < 30) {
      return (places: c.places, fromCache: true, cachedAt: c.savedAt);
    }
    try {
      final p = await fetchLive(lat, lon, radiusM);
      return (places: p, fromCache: false, cachedAt: null);
    } catch (e) {
      if (c != null) return (places: c.places, fromCache: true, cachedAt: c.savedAt);
      rethrow;
    }
  }
}
