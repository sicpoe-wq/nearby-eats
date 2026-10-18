import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/place.dart';

const overtureDataBase =
    'https://github.com/sicpoe-wq/nearby-eats/releases/download/data';
const overtureTileDeg = 0.5;
const _ua = 'NearbyEats/0.3 (Android app; github.com/sicpoe-wq/nearby-eats)';

/// Grid tile id: x = floor(lon*2), y = floor(lat*2).
typedef TileId = ({int x, int y});

String tileKey(TileId t) => '${t.x}_${t.y}';
String tileFile(TileId t) => 't_${t.x}_${t.y}.json.gz';

/// Tiles that cover a circle of [radiusM] around the point.
List<TileId> tilesFor(double lat, double lon, int radiusM,
    {double tileDeg = overtureTileDeg}) {
  final dLat = radiusM / 111320.0;
  final dLon = radiusM / (111320.0 * max(0.05, cos(lat * pi / 180)));
  final x0 = ((lon - dLon) / tileDeg).floor(), x1 = ((lon + dLon) / tileDeg).floor();
  final y0 = ((lat - dLat) / tileDeg).floor(), y1 = ((lat + dLat) / tileDeg).floor();
  return [
    for (var x = x0; x <= x1; x++)
      for (var y = y0; y <= y1; y++) (x: x, y: y)
  ];
}

/// Overture category -> readable cuisine ("pizza_restaurant" -> "pizza").
String? cuisineFromCategory(String? c) {
  if (c == null || c.isEmpty) return null;
  const generic = {
    'restaurant', 'casual_eatery', 'eatery', 'food_and_drink',
    'fast_food_restaurant', 'bar', 'cafe', 'coffee_shop', 'pub',
    'alcoholic_beverage_venue', 'non_alcoholic_beverage_venue',
  };
  if (generic.contains(c)) return null;
  var s = c;
  for (final suf in ['_restaurant', '_eatery', '_shop', '_place']) {
    if (s.endsWith(suf) && s.length > suf.length + 2) {
      s = s.substring(0, s.length - suf.length);
      break;
    }
  }
  return s;
}

/// One decoded Overture record -> app model. Null if unusable.
Place? placeFromOverture(Map<String, dynamic> r, double originLat, double originLon) {
  final name = (r['n'] as String?)?.trim();
  final la = (r['la'] as num?)?.toDouble();
  final lo = (r['lo'] as num?)?.toDouble();
  final id = r['id'] as String?;
  if (name == null || name.isEmpty || la == null || lo == null || id == null) {
    return null;
  }
  final tags = <String, String>{'name': name};
  void put(String k, Object? v) {
    if (v is String && v.trim().isNotEmpty) tags[k] = v.trim();
  }

  final type = (r['t'] as String?) ?? 'restaurant';
  put('phone', r['p']);
  put('website', r['w']);
  put('addr:full', r['a']);
  put('cuisine', cuisineFromCategory(r['c'] as String?));
  put('overture:category', r['c']);
  if (r['q'] != null) tags['overture:confidence'] = '${r['q']}';
  return Place(
    id: 'overture/$id',
    name: name,
    lat: la,
    lon: lo,
    amenity: type,
    tags: tags,
    distanceM: haversineMeters(originLat, originLon, la, lo),
    sources: {'overture'},
  );
}

List<Place> parseOvertureTile(
    List<int> gzBytes, double originLat, double originLon, int radiusM) {
  final raw = utf8.decode(gzip.decode(gzBytes));
  final list = jsonDecode(raw) as List;
  final out = <Place>[];
  for (final e in list) {
    if (e is! Map<String, dynamic>) continue;
    final p = placeFromOverture(e, originLat, originLon);
    if (p != null && p.distanceM <= radiusM) out.add(p);
  }
  return out;
}

/// Downloads, caches and reads Overture tiles. Never throws from [load]:
/// a missing tile or network failure just yields fewer (or no) places.
class OvertureService {
  OvertureService({http.Client? client, Directory? cacheDir, this.baseUrl = overtureDataBase,
      this.checkEvery = const Duration(days: 30),
      this.timeout = const Duration(seconds: 15)})
      : _client = client ?? http.Client(),
        _dirOverride = cacheDir;

  final http.Client _client;
  final Directory? _dirOverride;
  final String baseUrl;
  final Duration checkEvery;
  final Duration timeout;
  Map<String, dynamic>? _manifest;
  bool manifestChecked = false;

  /// Set when the last [load] hit a problem (for diagnostics/UI hints).
  String? lastProblem;

  Future<Directory> _dir() async {
    final d = _dirOverride ??
        Directory('${(await getApplicationSupportDirectory()).path}/overture');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<List<int>?> _get(String file) async {
    final res = await _client
        .get(Uri.parse('$baseUrl/$file'), headers: {'User-Agent': _ua}).timeout(timeout);
    if (res.statusCode == 200) return res.bodyBytes;
    if (res.statusCode == 404) return null;
    throw HttpException('HTTP ${res.statusCode} for $file');
  }

  /// Loads the manifest (cached on disk) and drops cached tiles when the
  /// hosted data version changed. Checks the network at most every
  /// [checkEvery] (or when there is no manifest yet).
  Future<Map<String, dynamic>?> manifest() async {
    if (manifestChecked) return _manifest;
    final dir = await _dir();
    final f = File('${dir.path}/manifest.json');
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt('overture_checked') ?? 0;
    Map<String, dynamic>? local;
    if (await f.exists()) {
      try {
        local = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      } catch (_) {}
    }
    final due = local == null ||
        DateTime.now().millisecondsSinceEpoch - last > checkEvery.inMilliseconds;
    if (due) {
      try {
        final b = await _get('manifest.json');
        if (b != null) {
          final fresh = jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
          final changed = local != null &&
              (local['overture_release'] != fresh['overture_release'] ||
                  local['built'] != fresh['built']);
          if (changed) {
            for (final e in dir.listSync()) {
              if (e is File && e.path.endsWith('.json.gz')) e.deleteSync();
            }
          }
          await f.writeAsString(jsonEncode(fresh));
          await prefs.setInt('overture_checked', DateTime.now().millisecondsSinceEpoch);
          local = fresh;
        }
      } catch (e) {
        lastProblem = 'manifest: $e';
      }
    }
    manifestChecked = true;
    return _manifest = local;
  }

  /// Bytes of one tile: disk cache first, then network. Null if the tile
  /// does not exist (no food places there) or cannot be fetched.
  Future<List<int>?> tileBytes(TileId t) async {
    final dir = await _dir();
    final m = await manifest(); // also drops stale tiles after a data update
    final f = File('${dir.path}/${tileFile(t)}');
    if (await f.exists()) return f.readAsBytes();
    final tiles = m?['tiles'];
    if (tiles is Map && !tiles.containsKey(tileKey(t))) return null;
    final b = await _get(tileFile(t));
    if (b != null) await f.writeAsBytes(b, flush: true);
    return b;
  }

  /// Overture places within [radiusM] of the point.
  Future<List<Place>> load(double lat, double lon, int radiusM) async {
    lastProblem = null;
    final out = <Place>[];
    final results = await Future.wait([
      for (final t in tilesFor(lat, lon, radiusM))
        () async {
          try {
            final b = await tileBytes(t);
            if (b == null) return <Place>[];
            return parseOvertureTile(b, lat, lon, radiusM);
          } catch (e) {
            lastProblem = 'tile ${tileKey(t)}: $e';
            return <Place>[];
          }
        }()
    ]);
    for (final r in results) {
      out.addAll(r);
    }
    out.sort((a, b) => a.distanceM.compareTo(b.distanceM));
    return out;
  }
}
