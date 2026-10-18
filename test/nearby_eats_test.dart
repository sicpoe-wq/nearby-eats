import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nearby_eats/services/app_state.dart';
import 'package:nearby_eats/services/menu_status_store.dart';
import 'package:nearby_eats/models/place.dart';
import 'package:nearby_eats/services/geocode_service.dart';
import 'package:nearby_eats/services/menu_scanner.dart';
import 'package:nearby_eats/services/overpass_service.dart';
import 'package:nearby_eats/services/settings_store.dart';

void main() {
  group('distance', () {
    test('haversine NYC -> Philadelphia ~130 km', () {
      final d = haversineMeters(40.7128, -74.0060, 39.9526, -75.1652);
      expect(d / 1000, closeTo(130, 3));
    });
    test('zero distance', () => expect(haversineMeters(1, 1, 1, 1), 0));
    test('formatting', () {
      expect(formatDistance(1609.344, DistUnit.mi), '1.0 mi');
      expect(formatDistance(500, DistUnit.km), '500 m');
      expect(formatDistance(2500, DistUnit.km), '2.5 km');
    });
  });

  group('overpass parsing', () {
    final json = {
      'elements': [
        {'type': 'node', 'id': 1, 'lat': 40.001, 'lon': -74.0, 'tags': {
          'name': 'Far Pizza', 'amenity': 'restaurant', 'cuisine': 'pizza;italian',
          'opening_hours': 'Mo-Su 11:00-22:00', 'contact:phone': '+1 555 0100',
          'website': 'example.com', 'menu:url': 'https://example.com/menu',
          'addr:housenumber': '5', 'addr:street': 'Main St', 'addr:city': 'Town'}},
        {'type': 'way', 'id': 2, 'center': {'lat': 40.0001, 'lon': -74.0}, 'tags': {'name': 'Near Cafe', 'amenity': 'cafe'}},
        {'type': 'node', 'id': 3, 'lat': 40.0, 'lon': -74.0, 'tags': {'amenity': 'restaurant'}},
        {'type': 'node', 'id': 4, 'tags': {'name': 'No coords'}},
      ]
    };
    final places = parseOverpass(json, 40.0, -74.0);
    test('skips unnamed / no-coordinate and sorts by distance', () {
      expect(places.map((p) => p.name), ['Near Cafe', 'Far Pizza']);
    });
    test('uses way center and types', () {
      expect(places.first.id, 'way/2');
      expect(places.first.type, PlaceType.cafe);
    });
    test('tags', () {
      final p = places.last;
      expect(p.cuisines, ['pizza', 'italian']);
      expect(p.cuisineLabel, 'Pizza, Italian');
      expect(p.phone, '+1 555 0100');
      expect(p.website, 'https://example.com');
      expect(p.menuUrl, 'https://example.com/menu');
      expect(p.address, '5 Main St, Town');
      expect(p.openingHours, 'Mo-Su 11:00-22:00');
    });
    test('json roundtrip', () {
      final p = Place.fromJson(places.last.toJson());
      expect(p.name, 'Far Pizza');
      expect(p.lat, 40.001);
    });
    test('query contains radius and center', () {
      final q = OverpassService.buildQuery(40.0, -74.0, 2000);
      expect(q, contains('around:2000,40.0,-74.0'));
      expect(q, contains('restaurant'));
    });
    test('empty/bad json', () => expect(parseOverpass({}, 0, 0), isEmpty));
  });

  test('nominatim parse', () {
    final r = GeocodeService.parse('[{"lat":"40.7","lon":"-74.0","display_name":"New York, USA"}]');
    expect(r.single.name, 'New York, USA');
    expect(r.single.lat, 40.7);
  });

  group('menu detection', () {
    final base = Uri.parse('https://resto.example/');
    test('finds anchors with menu text or path, resolves relative', () {
      const html = '''
        <a href="/about">About</a>
        <a href="/our-menu/"><span>Menu</span></a>
        <a href='files/dinner-menu.pdf'>Dinner PDF</a>
        <a href="https://order.example/x">Order online</a>
        <a href="#menu">Menu</a>
        <a href="/img/menu.png">Menu</a>''';
      final r = MenuScanner.parseHtml(html, base);
      final urls = r.links.map((l) => l.url).toList();
      expect(urls, contains('https://resto.example/our-menu/'));
      expect(urls, contains('https://resto.example/files/dinner-menu.pdf'));
      expect(urls, isNot(contains('https://order.example/x')));
      expect(urls.any((u) => u.endsWith('.png')), isFalse);
      expect(r.links.first.url, 'https://resto.example/our-menu/');
    });
    test('schema.org Menu JSON-LD', () {
      const html = '''<script type="application/ld+json">
      {"@type":"Restaurant","hasMenu":{"@type":"Menu","name":"Dinner","url":"/dinner",
       "hasMenuSection":[{"@type":"MenuSection","name":"Starters",
         "hasMenuItem":[{"@type":"MenuItem","name":"Soup"}]}]}}</script>''';
      final r = MenuScanner.parseHtml(html, base);
      expect(r.links.first.url, 'https://resto.example/dinner');
      expect(r.links.first.fromSchema, isTrue);
      expect(r.schemaItems, containsAll(['Dinner', 'Starters', 'Soup']));
    });
    test('nothing found', () {
      expect(MenuScanner.parseHtml('<a href="/x">Contact</a>', base).isEmpty, isTrue);
    });
  });

  group('menu/website status', () {
    Place mk(Map<String, String> tags) => Place(
        id: 'node/1', name: 'X', lat: 0, lon: 0, amenity: 'restaurant', tags: tags);
    MenuCheck chk(List<MenuLink> l, {bool ok = true, DateTime? at}) =>
        MenuCheck(ok: ok, scan: MenuScanResult(l, []), at: at);

    test('OSM menu tag => found immediately', () {
      final m = menuInfoFor(mk({'menu:url': 'https://a.com/m'}), null);
      expect(m.state, MenuState.found);
      expect(m.url, 'https://a.com/m');
    });
    test('no website, no tag => none (no pending forever)', () {
      expect(menuInfoFor(mk({}), null).state, MenuState.none);
    });
    test('website unchecked => pending', () {
      expect(menuInfoFor(mk({'website': 'a.com'}), null).state, MenuState.pending);
    });
    test('scan result decides found / none', () {
      final p = mk({'website': 'a.com'});
      final f = menuInfoFor(p, chk([MenuLink('https://a.com/menu', 'Menu')]));
      expect(f.state, MenuState.found);
      expect(f.url, 'https://a.com/menu');
      expect(menuInfoFor(p, chk([])).state, MenuState.none);
    });
    test('check json roundtrip and freshness', () {
      final c = chk([MenuLink('https://a.com/menu', 'Menu', fromSchema: true)]);
      final r = MenuCheck.fromJson(jsonDecode(jsonEncode(c.toJson())));
      expect(r.menuUrl, 'https://a.com/menu');
      expect(r.scan.links.first.fromSchema, isTrue);
      expect(c.isFresh(), isTrue);
      expect(chk([], at: DateTime.now().subtract(const Duration(days: 15))).isFresh(), isFalse);
      expect(chk([], ok: false, at: DateTime.now().subtract(const Duration(days: 2))).isFresh(), isFalse);
      expect(chk([], ok: false, at: DateTime.now().subtract(const Duration(hours: 2))).isFresh(), isTrue);
    });
  });

  group('overpass hedging', () {
    const okBody = '{"elements":[{"type":"node","id":1,"lat":1,"lon":1,"tags":{"name":"A","amenity":"cafe"}}]}';
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('failing first mirror falls through immediately', () async {
      final calls = <String>[];
      final svc = OverpassService(
        client: MockClient((req) async {
          calls.add(req.url.host);
          return req.url.host == OverpassService.endpoints[0].split('/')[2]
              ? http.Response('err', 502)
              : http.Response(okBody, 200);
        }),
        hedgeDelay: const Duration(seconds: 30),
      );
      final sw = Stopwatch()..start();
      final p = await svc.fetchLive(1, 1, 1000);
      expect(p.single.name, 'A');
      expect(sw.elapsedMilliseconds, lessThan(2000));
      expect(calls.length, 2);
    });

    test('slow first mirror is beaten by hedged second', () async {
      final svc = OverpassService(
        client: MockClient((req) async {
          if (req.url.host == OverpassService.endpoints[0].split('/')[2]) {
            await Future.delayed(const Duration(seconds: 3));
          }
          return http.Response(okBody, 200);
        }),
        hedgeDelay: const Duration(milliseconds: 100),
      );
      final sw = Stopwatch()..start();
      await svc.fetchLive(1, 1, 1000);
      expect(sw.elapsedMilliseconds, lessThan(1500));
    });

    test('all failing throws; stale cache used by fetch()', () async {
      final svc = OverpassService(
        client: MockClient((req) async => http.Response('x', 500)),
        hedgeDelay: const Duration(milliseconds: 10),
      );
      expect(svc.fetchLive(1, 1, 1000), throwsException);
      expect(svc.fetch(1, 1, 1000), throwsException);
    });

    test('compact query', () {
      final q = OverpassService.buildQuery(1, 2, 1000, limit: 120);
      expect(q, contains('out center tags qt 120;'));
      expect(q, contains('[timeout:15]'));
    });
  });

  group('app state progress', () {
    test('progress is determinate only while checking menus', () {
      final s = AppState();
      expect(s.busy, isFalse);
      expect(s.progress, isNull);
      expect(s.stageLabel, '');
    });
  });
}
