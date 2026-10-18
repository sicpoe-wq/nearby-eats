import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nearby_eats/models/place.dart';
import 'package:nearby_eats/services/overture_service.dart';
import 'package:nearby_eats/services/place_merge.dart';

// Marchelloni's home spot (9 Short St, West Middlesex PA 16159).
const homeLat = 41.17278, homeLon = -80.45684;

Map<String, dynamic> rec(String id, String n, double la, double lo,
        {String? p, String? w, String? a, String c = 'restaurant', String t = 'restaurant'}) =>
    {'id': id, 'n': n, 'la': la, 'lo': lo, 'a': a, 'p': p, 'w': w, 'c': c, 't': t, 'q': 0.9, 's': ['meta']};

List<int> gz(List<Map<String, dynamic>> r) => gzip.encode(utf8.encode(jsonEncode(r)));

Place osm(String name, double la, double lo, {Map<String, String> tags = const {}, String amenity = 'restaurant'}) =>
    Place(id: 'node/${name.hashCode}', name: name, lat: la, lon: lo, amenity: amenity,
        tags: {'name': name, ...tags}, distanceM: haversineMeters(homeLat, homeLon, la, lo));

Place? ovt(Map<String, dynamic> r) => placeFromOverture(r, homeLat, homeLon);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tile selection', () {
    test('Marchelloni home tile is -161_82', () {
      final t = tilesFor(homeLat, homeLon, 100);
      expect(t.map(tileKey), ['-161_82']);
      expect(tileFile(t.first), 't_-161_82.json.gz');
    });
    test('radius near a tile edge pulls neighbours', () {
      // lat 41.0 is exactly a tile edge (y=82 vs 81)
      final t = tilesFor(41.0, -80.4, 2000).map(tileKey).toSet();
      expect(t, containsAll(['-161_81', '-161_82']));
      final wide = tilesFor(41.25, -80.5, 30000).map(tileKey).toSet();
      expect(wide.length, greaterThan(4));
    });
    test('tiles for far-apart US regions', () {
      String k(double la, double lo) => tilesFor(la, lo, 50).map(tileKey).single;
      expect(k(34.0522, -118.2437), '-237_68'); // Los Angeles
      expect(k(40.7128, -74.0060), '-149_81'); // NYC
      expect(k(25.7617, -80.1918), '-161_51'); // Miami
      expect(k(61.2181, -149.9003), '-300_122'); // Anchorage
      expect(k(21.3069, -157.8583), '-316_42'); // Honolulu
      expect(k(41.8781, -87.6298), '-176_83'); // Chicago
      expect(k(18.4655, -66.1057), '-133_36'); // San Juan PR
    });
    test('manifest entries: schema 1, schema 2, split', () {
      final a = TileRef.parse([5, 100])!;
      expect((a.shard, a.sub), ('data', 1));
      final b = TileRef.parse([5, 100, 'data-b-9', 1])!;
      expect((b.shard, b.sub), ('data-b-9', 1));
      final c = TileRef.parse([9, 9, 'data-b-9', 2, ['0_0', '1_1']])!;
      expect(c.sub, 2);
      expect(c.subs, {'0_0', '1_1'});
      expect(TileRef.parse('junk'), isNull);
      expect(TileRef.parse([1]), isNull);
    });
    test('split tile: only sub-files touching the circle are requested', () {
      final ref = TileRef.parse([9, 9, 'data-b-9', 2, ['0_0', '0_1', '1_0', '1_1']])!;
      // Chicago loop, tile -176_83 (lon -88..-87.5, lat 41.5..42): sub 1_0 = east/south half.
      final one = filesFor((x: -176, y: 83), ref, 41.60, -87.60, 500);
      expect(one.map((f) => f.name), ['t_-176_83_1_0.json.gz']);
      final all = filesFor((x: -176, y: 83), ref, 41.75, -87.75, 20000);
      expect(all.length, 4);
      // Missing sub-file in the manifest is never requested.
      final sparse = TileRef.parse([1, 1, 'data-b-9', 2, ['1_0']])!;
      expect(filesFor((x: -176, y: 83), sparse, 41.75, -87.75, 20000).map((f) => f.name),
          ['t_-176_83_1_0.json.gz']);
    });
    test('schema 3 packed entries: ranges for whole and split tiles', () {
      final a = TileRef.parse([3, 90, 'pack-b-17', 1, [], [1000, 90]])!;
      expect(a.packed, isTrue);
      final f = filesFor((x: -176, y: 83), a, 41.6, -87.6, 500).single;
      expect((f.name, f.pack, f.release, f.range), ('t_-176_83.json.gz', 'pack-b-17.bin', 'data', (1000, 90)));
      final b = TileRef.parse([9, 9, 'pack-b-17', 2, ['0_0', '1_0'], [[0, 10], [10, 20]]])!;
      final g = filesFor((x: -176, y: 83), b, 41.6, -87.6, 20000);
      expect(g.map((f) => f.range), [(0, 10), (10, 20)]);
      // packed entry without a usable range is never requested
      expect(filesFor((x: -176, y: 83), TileRef.parse([3, 90, 'pack-b-17', 1])!, 41.6, -87.6, 500), isEmpty);
    });
    test('negative coords floor correctly', () {
      final t = tilesFor(40.0, -80.0, 10, tileDeg: 0.5).map(tileKey).toList();
      expect(t, contains('-160_80'));
    });
  });

  group('parsing & filtering', () {
    final m = rec('a', 'Pizzas By Marchelloni - W Middlesex', 41.172451, -80.456947,
        p: '+17245283425', w: 'http://www.pizzasbymarchelloni.com/',
        a: '9 Short St, West Middlesex, PA, 16159', c: 'pizza_restaurant');
    test('record -> Place', () {
      final p = ovt(m)!;
      expect(p.id, 'overture/a');
      expect(p.sources, {'overture'});
      expect(p.phone, '+17245283425');
      expect(p.website, 'http://www.pizzasbymarchelloni.com/');
      expect(p.address, '9 Short St, West Middlesex, PA, 16159');
      expect(p.cuisines, ['pizza']);
      expect(p.type, PlaceType.restaurant);
      expect(p.sourceLabel, 'Overture Maps');
    });
    test('bad records dropped', () {
      expect(ovt({'id': 'x', 'n': '', 'la': 1.0, 'lo': 1.0}), isNull);
      expect(ovt({'id': 'x', 'n': 'N'}), isNull);
    });
    test('radius filter on tile parse', () {
      final far = rec('far', 'Far Diner', 41.30, -80.45);
      final all = parseOvertureTile(gz([m, far]), homeLat, homeLon, 1609);
      expect(all.map((p) => p.name), ['Pizzas By Marchelloni - W Middlesex']);
      expect(parseOvertureTile(gz([m, far]), homeLat, homeLon, 20000).length, 2);
    });
    test('cuisine from category', () {
      expect(cuisineFromCategory('pizza_restaurant'), 'pizza');
      expect(cuisineFromCategory('restaurant'), isNull);
      expect(cuisineFromCategory('fast_food_restaurant'), isNull);
      expect(cuisineFromCategory('mexican_restaurant'), 'mexican');
    });
  });

  group('names', () {
    test('matching', () {
      expect(namesMatch('Dairy Queen', 'Dairy Queen Grill & Chill'), isTrue);
      expect(namesMatch("McDonald's", 'McDonalds'), isTrue);
      expect(namesMatch('Pizzas By Marchelloni - W Middlesex', "Marchelloni's Pizza"), isTrue);
      expect(namesMatch('Subway', 'SUBWAY®'), isTrue);
      expect(namesMatch("O'Neill Coffee Co", 'ONeill Coffee Company'), isTrue);
      expect(namesMatch('Pizza Hut', 'Pizza Palace'), isFalse);
      expect(namesMatch('Subway', 'Dairy Queen'), isFalse);
    });
  });

  group('merge', () {
    test('Marchelloni is added when OSM lacks it', () {
      final dq = osm('Dairy Queen', 41.1740, -80.4570, tags: {'amenity': 'fast_food'});
      final merged = mergePlaces([dq], [ovt(rec('m', 'Pizzas By Marchelloni - W Middlesex', 41.172451, -80.456947, p: '+17245283425', w: 'http://www.pizzasbymarchelloni.com/'))!]);
      expect(merged.where((p) => p.name.contains('Marchelloni')).length, 1);
      expect(merged.length, 2);
      expect(merged.first.name, contains('Marchelloni')); // nearest
    });
    test('Dairy Queen in both sources is one place, OSM wins, gaps filled', () {
      final o = osm('Dairy Queen', 41.2330, -80.4524,
          tags: {'phone': '(724) 347-7175', 'addr:street': 'E State St'}, amenity: 'fast_food');
      final x = ovt(rec('dq', 'Dairy Queen', 41.23305, -80.45245,
          p: '+17243477175', w: 'http://www.dairyqueen.com/', a: '3102 E State St, Hermitage, PA, 16148', c: 'ice_cream_shop', t: 'ice_cream'))!;
      final m = mergePlaces([o], [x]);
      expect(m.length, 1);
      final p = m.single;
      expect(p.id, o.id);
      expect(p.amenity, 'fast_food');
      expect(p.phone, '(724) 347-7175'); // OSM kept
      expect(p.website, 'http://www.dairyqueen.com/'); // gap filled
      expect(p.sources, {'osm', 'overture'});
      expect(p.sourceLabel, 'OpenStreetMap + Overture Maps');
    });
    test('Subway same phone different spelling, 60 m apart -> one', () {
      final o = osm('Subway', 41.1855, -80.4555, tags: {'phone': '+1 724 528 2925'});
      final x = ovt(rec('s', 'Subway Restaurant #1234', 41.18590, -80.4555, p: '17245282925'))!;
      expect(mergePlaces([o], [x]).length, 1);
    });
    test('same name but far apart (different branch) stays separate', () {
      final o = osm('Subway', 41.1855, -80.4555);
      final x = ovt(rec('s2', 'Subway', 41.2342, -80.4639))!;
      expect(mergePlaces([o], [x]).length, 2);
    });
    test('nearby but different restaurants stay separate', () {
      final o = osm('Joe Diner', 41.1855, -80.4555);
      final x = ovt(rec('t', 'Sakura Sushi', 41.18552, -80.45552))!;
      expect(mergePlaces([o], [x]).length, 2);
    });
    test('duplicate Overture entries collapse (same phone)', () {
      final a = ovt(rec('1', 'Subway', 41.0045, -80.3667, p: '17246549917'))!;
      final b = ovt(rec('2', 'Subway', 41.0055, -80.3680, p: '+17246549917', w: 'https://s.example'))!;
      final m = mergePlaces([], [a, b]);
      expect(m.length, 1);
      expect(m.single.website, 'https://s.example');
    });
    test('Overture-only list when OSM empty', () {
      expect(mergePlaces([], [ovt(rec('a', 'X Cafe', 41.1728, -80.4569))!]).length, 1);
    });
    test('favorites JSON keeps sources; old JSON defaults to osm', () {
      final p = ovt(rec('a', 'X', 41.1, -80.4))!;
      expect(Place.fromJson(p.toJson()).sources, {'overture'});
      final old = p.toJson()..remove('sources');
      expect(Place.fromJson(old).sources, {'osm'});
    });
  });

  group('service (cache, manifest, failures)', () {
    late Directory dir;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('ovt');
    });
    tearDown(() => dir.delete(recursive: true));

    Map<String, dynamic> manifest(String rel, List<String> tiles) =>
        {'schema': 3, 'overture_release': rel, 'built': '2026-10-18',
          'tiles': {for (final t in tiles) t: [1, 1, 'data', 1]}};

    test('downloads, caches tile; second load needs no network', () async {
      var tileHits = 0;
      final tile = gz([rec('m', 'Pizzas By Marchelloni - W Middlesex', 41.172451, -80.456947, p: '+17245283425')]);
      http.Client c(void Function() hit) => MockClient((req) async {
            if (req.url.path.endsWith('manifest.json')) {
              return http.Response(jsonEncode(manifest('r1', ['-161_82'])), 200);
            }
            hit();
            return http.Response.bytes(tile, 200);
          });
      final s = OvertureService(client: c(() => tileHits++), cacheDir: dir);
      expect((await s.load(homeLat, homeLon, 1609)).length, 1);
      expect(tileHits, 1);
      final s2 = OvertureService(client: MockClient((_) async => http.Response('x', 500)), cacheDir: dir);
      expect((await s2.load(homeLat, homeLon, 1609)).length, 1); // from disk
    });
    test('tile in another release and split tile are fetched from the manifest URLs', () async {
      final urls = <String>[];
      final tile = gz([rec('c', 'Deep Dish', 41.60, -87.60)]);
      final m = {'schema': 2, 'overture_release': 'r1', 'built': 'b', 'tiles': {
        '-176_83': [1, 1, 'data-b-9', 2, ['1_0']]}};
      final s = OvertureService(
          client: MockClient((req) async {
            urls.add(req.url.toString());
            if (req.url.path.endsWith('manifest.json')) return http.Response(jsonEncode(m), 200);
            return http.Response.bytes(tile, 200);
          }),
          cacheDir: dir);
      final r = await s.load(41.60, -87.60, 500);
      expect(r.single.name, 'Deep Dish');
      expect(urls, [
        '$overtureDataBase/data/manifest.json',
        '$overtureDataBase/data-b-9/t_-176_83_1_0.json.gz',
      ]);
    });
    test('packed tile is read with an HTTP Range request from the pack in release data', () async {
      final tile = gz([rec('p', 'Packed Pizza', 41.60, -87.60)]);
      final pad = List<int>.filled(7, 0);
      final pack = [...pad, ...tile, ...pad];
      final m = {'schema': 3, 'overture_release': 'r1', 'built': 'b', 'tiles': {
        '-176_83': [1, tile.length, 'pack-b-18', 1, [], [7, tile.length]]}};
      final seen = <String>[];
      final s = OvertureService(
          client: MockClient((req) async {
            if (req.url.path.endsWith('manifest.json')) return http.Response(jsonEncode(m), 200);
            seen.add('${req.url} ${req.headers['Range']}');
            return http.Response.bytes(pack.sublist(7, 7 + tile.length), 206);
          }),
          cacheDir: dir);
      expect((await s.load(41.60, -87.60, 500)).single.name, 'Packed Pizza');
      expect(seen, ['$overtureDataBase/data/pack-b-18.bin bytes=7-${6 + tile.length}']);
      // cached afterwards; a server that ignores Range (200 + whole pack) also works
      final d2 = await Directory.systemTemp.createTemp('ovt3');
      final s2 = OvertureService(
          client: MockClient((req) async => req.url.path.endsWith('manifest.json')
              ? http.Response(jsonEncode(m), 200)
              : http.Response.bytes(pack, 200)),
          cacheDir: d2);
      expect((await s2.load(41.60, -87.60, 500)).single.name, 'Packed Pizza');
      d2.deleteSync(recursive: true);
    });
    test('cached schema-1 manifest is refetched even when not due', () async {
      SharedPreferences.setMockInitialValues({'overture_checked': DateTime.now().millisecondsSinceEpoch});
      File('${dir.path}/manifest.json').writeAsStringSync(jsonEncode({'overture_release': 'r0', 'built': 'old', 'tiles': {}}));
      File('${dir.path}/t_-161_82.json.gz').writeAsBytesSync(gz([rec('old', 'Stale', 41.17, -80.45)]));
      final tile = gz([rec('m', 'Fresh', 41.1728, -80.4569)]);
      final s = OvertureService(
          client: MockClient((req) async => req.url.path.endsWith('manifest.json')
              ? http.Response(jsonEncode(manifest('r1', ['-161_82'])), 200)
              : http.Response.bytes(tile, 200)),
          cacheDir: dir);
      expect((await s.load(homeLat, homeLon, 500)).single.name, 'Fresh');
    });
    test('tile not in manifest is skipped without a request', () async {
      var tileHits = 0;
      final s = OvertureService(
          client: MockClient((req) async {
            if (req.url.path.endsWith('manifest.json')) {
              return http.Response(jsonEncode(manifest('r1', ['-100_50'])), 200);
            }
            tileHits++;
            return http.Response('', 404);
          }),
          cacheDir: dir);
      expect(await s.load(homeLat, homeLon, 1609), isEmpty);
      expect(tileHits, 0);
    });
    test('network failure / 404 / garbage never throws', () async {
      for (final r in [http.Response('', 500), http.Response('', 404), http.Response('not gzip', 200)]) {
        final d2 = await Directory.systemTemp.createTemp('ovt2');
        final s = OvertureService(client: MockClient((_) async => r), cacheDir: d2);
        expect(await s.load(homeLat, homeLon, 1609), isEmpty);
        d2.deleteSync(recursive: true);
      }
      final s = OvertureService(client: MockClient((_) async => throw const SocketException('offline')), cacheDir: dir);
      expect(await s.load(homeLat, homeLon, 1609), isEmpty);
    });
    test('new data version clears cached tiles after the check interval', () async {
      final tile = gz([rec('m', 'Old Place', 41.1728, -80.4569)]);
      var rel = 'r1';
      var tileCalls = 0;
      http.Client c() => MockClient((req) async {
            if (req.url.path.endsWith('manifest.json')) {
              return http.Response(jsonEncode(manifest(rel, ['-161_82'])), 200);
            }
            tileCalls++;
            return http.Response.bytes(tile, 200);
          });
      await OvertureService(client: c(), cacheDir: dir).load(homeLat, homeLon, 500);
      expect(tileCalls, 1);
      // Not due yet -> still cached, no manifest refetch.
      rel = 'r2';
      await OvertureService(client: c(), cacheDir: dir).load(homeLat, homeLon, 500);
      expect(tileCalls, 1);
      // Pretend 31 days passed.
      SharedPreferences.setMockInitialValues({'overture_checked': DateTime.now().subtract(const Duration(days: 31)).millisecondsSinceEpoch});
      await OvertureService(client: c(), cacheDir: dir).load(homeLat, homeLon, 500);
      expect(tileCalls, 2); // re-downloaded after version change
    });
  });
}
