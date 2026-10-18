import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/place.dart';

/// Root of the GitHub release downloads. The manifest lives in release "data";
/// each tile's release ("data", "data-b-9", ...) comes from the manifest.
const overtureDataBase =
    'https://github.com/sicpoe-wq/nearby-eats/releases/download';
const overtureManifestRelease = 'data';
/// Cached manifests older than this schema are refetched immediately.
const overtureMinSchema = 3;
const overtureTileDeg = 0.5;
const _ua = 'NearbyEats/0.4 (Android app; github.com/sicpoe-wq/nearby-eats)';

/// Grid tile id: x = floor(lon*2), y = floor(lat*2).
typedef TileId = ({int x, int y});

String tileKey(TileId t) => '${t.x}_${t.y}';
String tileFile(TileId t) => 't_${t.x}_${t.y}.json.gz';

/// One manifest entry: where a tile is hosted and whether it is split.
/// Schema 1: [count, bytes]. Schema 2: [count, bytes, release, sub, subs?].
/// Schema 3 adds a 6th item for packed tiles (shard "pack-bN"): the byte
/// range inside `SHARD.bin` ([offset, length], or one per sub-tile).
class TileRef {
  TileRef(this.count, this.bytes, this.shard, this.sub, this.subs, this.ranges);
  final int count, bytes, sub;
  final String shard;
  final Set<String> subs; // "i_j" files that exist when sub > 1
  /// Byte ranges in the pack, keyed by sub-tile "i_j" ('' for an unsplit tile).
  final Map<String, (int, int)> ranges;

  bool get packed => shard.startsWith('pack-');

  static TileRef? parse(Object? v) {
    if (v is! List || v.length < 2) return null;
    final sub = v.length > 3 && v[3] is int ? v[3] as int : 1;
    final subList = v.length > 4 && v[4] is List ? [for (final e in v[4] as List) '$e'] : <String>[];
    final shard = v.length > 2 && v[2] is String ? v[2] as String : overtureManifestRelease;
    final ranges = <String, (int, int)>{};
    final offs = v.length > 5 ? v[5] : null;
    if (offs is List && offs.isNotEmpty) {
      (int, int)? pair(Object? o) => o is List && o.length == 2 && o[0] is num && o[1] is num
          ? ((o[0] as num).toInt(), (o[1] as num).toInt())
          : null;
      if (sub <= 1) {
        final r = pair(offs);
        if (r != null) ranges[''] = r;
      } else {
        for (var k = 0; k < subList.length && k < offs.length; k++) {
          final r = pair(offs[k]);
          if (r != null) ranges[subList[k]] = r;
        }
      }
    }
    return TileRef((v[0] as num?)?.toInt() ?? 0, (v[1] as num?)?.toInt() ?? 0, shard,
        sub < 1 ? 1 : sub, subList.toSet(), ranges);
  }
}

/// One file to fetch: [name] is the local cache name; it lives in release
/// [release] (individual file) or at [range] of `RELEASE/PACK.bin`.
class TileFile {
  TileFile(this.name, this.release, {this.pack, this.range});
  final String name, release;
  final String? pack;
  final (int, int)? range;
}

/// Files to fetch for [t] given its manifest entry, restricted to
/// sub-tiles that touch the circle around the point when the tile is split.
List<TileFile> filesFor(TileId t, TileRef ref, double lat, double lon, int radiusM,
    {double tileDeg = overtureTileDeg}) {
  TileFile mk(String name, String sub) => ref.packed
      ? TileFile(name, overtureManifestRelease, pack: '${ref.shard}.bin', range: ref.ranges[sub])
      : TileFile(name, ref.shard);
  if (ref.sub <= 1) {
    final f = mk(tileFile(t), '');
    return ref.packed && f.range == null ? [] : [f];
  }
  final dLat = radiusM / 111320.0;
  final dLon = radiusM / (111320.0 * max(0.05, cos(lat * pi / 180)));
  final step = tileDeg / ref.sub;
  final out = <TileFile>[];
  for (var i = 0; i < ref.sub; i++) {
    for (var j = 0; j < ref.sub; j++) {
      if (!ref.subs.contains('${i}_$j')) continue;
      final w = t.x * tileDeg + i * step, s0 = t.y * tileDeg + j * step;
      if (w > lon + dLon || w + step < lon - dLon) continue;
      if (s0 > lat + dLat || s0 + step < lat - dLat) continue;
      final f = mk('t_${t.x}_${t.y}_${i}_$j.json.gz', '${i}_$j');
      if (ref.packed && f.range == null) continue;
      out.add(f);
    }
  }
  return out;
}

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

List<Place> _parseJob(List<Object> a) => parseOvertureTile(
    a[0] as List<int>, a[1] as double, a[2] as double, a[3] as int);

/// Parses off the UI isolate; dense city tiles hold up to ~20k records.
Future<List<Place>> parseOvertureTileAsync(
        List<int> gz, double lat, double lon, int radiusM) =>
    compute(_parseJob, <Object>[gz, lat, lon, radiusM]);

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

  Future<List<int>?> _get(String file,
      {String release = overtureManifestRelease, (int, int)? range}) async {
    final res = await _client.get(Uri.parse('$baseUrl/$release/$file'), headers: {
      'User-Agent': _ua,
      if (range != null) 'Range': 'bytes=${range.$1}-${range.$1 + range.$2 - 1}',
    }).timeout(timeout);
    if (range != null && (res.statusCode == 200 || res.statusCode == 206)) {
      var b = res.bodyBytes;
      // A server that ignores Range sends the whole pack: slice it ourselves.
      if (res.statusCode == 200 && b.length >= range.$1 + range.$2) {
        b = b.sublist(range.$1, range.$1 + range.$2);
      }
      if (b.length != range.$2) throw HttpException('short range read for $file');
      return b;
    }
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
    final oldSchema = local != null &&
        ((local['schema'] as num?)?.toInt() ?? 1) < overtureMinSchema;
    final due = local == null || oldSchema ||
        DateTime.now().millisecondsSinceEpoch - last > checkEvery.inMilliseconds;
    if (due) {
      try {
        final b = await _get('manifest.json');
        if (b != null) {
          final fresh = jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
          final changed = local != null &&
              (local['overture_release'] != fresh['overture_release'] ||
                  local['built'] != fresh['built'] ||
                  local['schema'] != fresh['schema']);
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

  /// Bytes of one tile file: disk cache first, then the release named in
  /// the manifest. Null if it does not exist or cannot be fetched.
  Future<List<int>?> fileBytes(TileFile t) async {
    final dir = await _dir();
    final f = File('${dir.path}/${t.name}');
    if (await f.exists()) return f.readAsBytes();
    final b = t.pack != null
        ? await _get(t.pack!, release: t.release, range: t.range)
        : await _get(t.name, release: t.release);
    if (b != null) await f.writeAsBytes(b, flush: true);
    return b;
  }

  /// Tile files (name, release) needed for a search; empty if the manifest
  /// says there is nothing there.
  Future<List<TileFile>> filesForSearch(double lat, double lon, int radiusM) async {
    final m = await manifest(); // also drops stale tiles after a data update
    final tiles = m?['tiles'];
    if (tiles is! Map) return [];
    final out = <TileFile>[];
    for (final t in tilesFor(lat, lon, radiusM)) {
      final ref = TileRef.parse(tiles[tileKey(t)]);
      if (ref == null) continue;
      out.addAll(filesFor(t, ref, lat, lon, radiusM));
    }
    return out;
  }

  /// Overture places within [radiusM] of the point.
  Future<List<Place>> load(double lat, double lon, int radiusM) async {
    lastProblem = null;
    final out = <Place>[];
    List<TileFile> files;
    try {
      files = await filesForSearch(lat, lon, radiusM);
    } catch (e) {
      lastProblem = 'manifest: $e';
      return out;
    }
    final results = await Future.wait([
      for (final fr in files)
        () async {
          try {
            final b = await fileBytes(fr);
            if (b == null) return <Place>[];
            return await parseOvertureTileAsync(b, lat, lon, radiusM);
          } catch (e) {
            lastProblem = 'tile ${fr.name}: $e';
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
