import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/place.dart';
import 'cache_store.dart';

const userAgent = 'NearbyEats/0.1 (Android app; github.com/sicpoe-wq/nearby-eats)';

class OverpassService {
  OverpassService({http.Client? client, CacheStore? cache})
      : _client = client ?? http.Client(),
        _cache = cache ?? CacheStore();

  final http.Client _client;
  final CacheStore _cache;

  static const endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  static String buildQuery(double lat, double lon, int radiusM) {
    const sel = 'restaurant|fast_food|cafe|bar|pub|food_court|ice_cream';
    return '[out:json][timeout:25];'
        '(nwr["amenity"~"^($sel)\$"]["name"](around:$radiusM,$lat,$lon););'
        'out center tags 800;';
  }

  static String cacheKey(double lat, double lon, int radiusM) =>
      'overpass_${lat.toStringAsFixed(3)}_${lon.toStringAsFixed(3)}_$radiusM';

  /// Returns places sorted by distance. [fromCache] set when stale data used
  /// because every endpoint failed.
  Future<({List<Place> places, bool fromCache, DateTime? cachedAt})> fetch(
      double lat, double lon, int radiusM,
      {bool forceRefresh = false}) async {
    final key = cacheKey(lat, lon, radiusM);
    final cached = await _cache.read(key);
    if (!forceRefresh && cached != null && cached.age.inMinutes < 30) {
      return (
        places: parseOverpass(cached.data as Map<String, dynamic>, lat, lon),
        fromCache: true,
        cachedAt: cached.savedAt
      );
    }
    final body = buildQuery(lat, lon, radiusM);
    Object? lastError;
    for (final ep in endpoints) {
      try {
        final res = await _client
            .post(Uri.parse(ep),
                headers: {
                  'User-Agent': userAgent,
                  'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: {'data': body})
            .timeout(const Duration(seconds: 35));
        if (res.statusCode != 200) {
          lastError = 'HTTP ${res.statusCode} from $ep';
          continue;
        }
        final json = jsonDecode(utf8.decode(res.bodyBytes));
        if (json is! Map<String, dynamic> || json['elements'] is! List) {
          lastError = 'Bad response from $ep';
          continue;
        }
        await _cache.write(key, json);
        return (
          places: parseOverpass(json, lat, lon),
          fromCache: false,
          cachedAt: null
        );
      } catch (e) {
        lastError = e;
      }
    }
    if (cached != null) {
      return (
        places: parseOverpass(cached.data as Map<String, dynamic>, lat, lon),
        fromCache: true,
        cachedAt: cached.savedAt
      );
    }
    throw Exception('Could not reach OpenStreetMap servers ($lastError)');
  }
}
