// Live check against the hosted tiles. Skipped unless VERIFY_HOSTED=1:
//   VERIFY_HOSTED=1 flutter test test/hosted_data_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nearby_eats/services/overture_service.dart';
import 'package:nearby_eats/services/place_merge.dart';
import 'package:nearby_eats/models/place.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final on = Platform.environment['VERIFY_HOSTED'] == '1';
  test('hosted tile for ZIP 16159 returns Pizzas By Marchelloni within 1 mile, once', () async {
    HttpOverrides.global = null; // allow real network inside flutter test
    final dir = await Directory.systemTemp.createTemp('ovt_live');
    final s = OvertureService(cacheDir: dir);
    const lat = 41.1728, lon = -80.4568; // ZIP 16159 area (West Middlesex)
    final places = await s.load(lat, lon, 1609);
    // ignore: avoid_print
    print('problem=${s.lastProblem} count=${places.length}');
    for (final p in places.take(40)) {
      // ignore: avoid_print
      print('${(p.distanceM / 1609.344).toStringAsFixed(2)} mi  ${p.name}  ${p.phone}  ${p.website}');
    }
    final hits = places.where((p) => p.name.toLowerCase().contains('marchelloni')).toList();
    expect(hits.length, 1);
    expect(hits.single.distanceM, lessThan(1609));
    expect(hits.single.phone, '+17245283425');
    expect(hits.single.website, contains('pizzasbymarchelloni.com'));
    // Merge with an OSM-style list (only the 4 OSM places found earlier) -> still exactly one.
    final osm = [
      Place(id: 'node/1', name: 'Dairy Queen', lat: 41.1752, lon: -80.4570, amenity: 'fast_food', tags: {'name': 'Dairy Queen'}),
      Place(id: 'node/2', name: 'Subway', lat: 41.1855, lon: -80.4555, amenity: 'fast_food', tags: {'name': 'Subway'}),
    ];
    for (final p in osm) {
      p.distanceM = haversineMeters(lat, lon, p.lat, p.lon);
    }
    final merged = mergePlaces(osm, places);
    expect(merged.where((p) => p.name.toLowerCase().contains('marchelloni')).length, 1);
    // ignore: avoid_print
    print('merged=${merged.length}; subway sources=${merged.firstWhere((p) => p.name == 'Subway').sources}');
    await dir.delete(recursive: true);
  }, skip: on ? false : 'set VERIFY_HOSTED=1');

  test('hosted tiles return restaurants across the whole US', () async {
    HttpOverrides.global = null;
    final dir = await Directory.systemTemp.createTemp('ovt_live_us');
    final s = OvertureService(cacheDir: dir);
    const spots = {
      'downtown Chicago': (41.8837, -87.6325, 1609, 100),
      'Fredericksburg TX': (30.2752, -98.8720, 3000, 20),
      'Honolulu': (21.3069, -157.8583, 1609, 100),
      'Anchorage': (61.2181, -149.9003, 1609, 30),
      'Miami': (25.7617, -80.1918, 1609, 100),
      'Los Angeles': (34.0522, -118.2437, 1609, 100),
      'NYC Times Square': (40.7580, -73.9855, 1000, 100),
      'Boise ID': (43.6150, -116.2023, 1609, 30),
    };
    for (final e in spots.entries) {
      final (la, lo, r, min) = e.value;
      final sw = Stopwatch()..start();
      final places = await s.load(la, lo, r);
      // ignore: avoid_print
      print('${e.key}: ${places.length} places in ${r}m, ${sw.elapsedMilliseconds} ms, problem=${s.lastProblem}');
      expect(places.length, greaterThanOrEqualTo(min), reason: e.key);
    }
    await dir.delete(recursive: true);
  }, skip: on ? false : 'set VERIFY_HOSTED=1', timeout: const Timeout(Duration(minutes: 5)));
}
