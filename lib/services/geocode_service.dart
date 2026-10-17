import 'dart:convert';
import 'package:http/http.dart' as http;
import 'overpass_service.dart' show userAgent;

class GeoResult {
  GeoResult(this.name, this.lat, this.lon);
  final String name;
  final double lat;
  final double lon;
}

/// Nominatim geocoding. Usage policy: max 1 req/s, identifying User-Agent,
/// no autocomplete-style hammering -> callers debounce and we throttle here.
class GeocodeService {
  GeocodeService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  static List<GeoResult> parse(String body) {
    final j = jsonDecode(body);
    if (j is! List) return [];
    return [
      for (final e in j)
        if (e is Map && e['lat'] != null && e['lon'] != null)
          GeoResult('${e['display_name']}', double.parse('${e['lat']}'),
              double.parse('${e['lon']}'))
    ];
  }

  Future<List<GeoResult>> search(String query, {int limit = 5}) async {
    final wait = const Duration(milliseconds: 1100) -
        DateTime.now().difference(_last);
    if (wait > Duration.zero) await Future.delayed(wait);
    _last = DateTime.now();
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': query,
      'format': 'jsonv2',
      'limit': '$limit',
      'addressdetails': '0',
    });
    final res = await _client.get(uri, headers: {
      'User-Agent': userAgent,
      'Accept-Language': 'en',
    }).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('Geocoder error ${res.statusCode}');
    }
    return parse(utf8.decode(res.bodyBytes));
  }
}
