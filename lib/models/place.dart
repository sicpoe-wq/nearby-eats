import 'dart:math';

enum PlaceType { restaurant, fastFood, cafe, barPub, other }

extension PlaceTypeX on PlaceType {
  String get label => switch (this) {
        PlaceType.restaurant => 'Restaurant',
        PlaceType.fastFood => 'Fast food',
        PlaceType.cafe => 'Café',
        PlaceType.barPub => 'Bar / Pub',
        PlaceType.other => 'Other',
      };
}

PlaceType typeFromAmenity(String? a) => switch (a) {
      'restaurant' => PlaceType.restaurant,
      'fast_food' => PlaceType.fastFood,
      'cafe' => PlaceType.cafe,
      'bar' || 'pub' => PlaceType.barPub,
      _ => PlaceType.other,
    };

/// Great-circle distance in meters.
double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a = pow(sin(dLat / 2), 2) +
      cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLon / 2), 2);
  return 2 * r * asin(min(1.0, sqrt(a)));
}

String? _clean(String? s) {
  if (s == null) return null;
  final t = s.trim();
  return t.isEmpty ? null : t;
}

String? normalizeUrl(String? raw) {
  final s = _clean(raw);
  if (s == null) return null;
  // OSM sometimes has several values separated by ';'
  final first = s.split(';').first.trim();
  if (first.isEmpty) return null;
  if (first.startsWith('http://') || first.startsWith('https://')) return first;
  if (first.contains(' ') || !first.contains('.')) return null;
  return 'https://$first';
}

class Place {
  Place({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.amenity,
    required this.tags,
    this.distanceM = 0,
    Set<String>? sources,
  }) : sources = sources ?? {'osm'};

  final String id; // e.g. node/123
  final String name;
  final double lat;
  final double lon;
  final String amenity;
  final Map<String, String> tags;
  double distanceM;

  /// Where this place's data came from: 'osm' and/or 'overture'.
  final Set<String> sources;

  bool get hasOsm => sources.contains('osm');
  bool get hasOverture => sources.contains('overture');

  /// Full data-source name for the detail page.
  String get sourceLabel => hasOsm && hasOverture
      ? 'OpenStreetMap + Overture Maps'
      : hasOverture
          ? 'Overture Maps'
          : 'OpenStreetMap';

  /// Short badge text for list rows.
  String get sourceBadge => hasOsm && hasOverture
      ? 'OSM + Overture'
      : hasOverture
          ? 'Overture'
          : 'OSM';

  PlaceType get type => typeFromAmenity(amenity);

  List<String> get cuisines {
    final c = _clean(tags['cuisine']);
    if (c == null) return const [];
    return c
        .split(RegExp(r'[;,]'))
        .map((e) => e.trim().replaceAll('_', ' '))
        .where((e) => e.isNotEmpty)
        .toList();
  }

  String? get cuisineLabel {
    final c = cuisines;
    if (c.isEmpty) return null;
    return c.map((e) => e[0].toUpperCase() + e.substring(1)).join(', ');
  }

  String? get openingHours => _clean(tags['opening_hours']);
  String? get phone => _clean(tags['phone'] ?? tags['contact:phone'])
      ?.split(';')
      .first
      .trim();
  String? get website =>
      normalizeUrl(tags['website'] ?? tags['contact:website'] ?? tags['url']);

  /// Direct menu URL tagged in OSM (not a guess).
  String? get menuUrl => normalizeUrl(tags['website:menu'] ??
      tags['menu:url'] ??
      tags['contact:menu'] ??
      tags['url:menu']);

  String? get address {
    final street = [tags['addr:housenumber'], tags['addr:street']]
        .whereType<String>()
        .join(' ')
        .trim();
    final city = tags['addr:city'];
    final parts = [
      if (street.isNotEmpty) street,
      if (_clean(city) != null) city!,
      if (_clean(tags['addr:state']) != null) tags['addr:state']!,
      if (_clean(tags['addr:postcode']) != null) tags['addr:postcode']!,
    ];
    if (parts.isEmpty) return _clean(tags['addr:full']);
    return parts.join(', ');
  }

  String? get city => _clean(tags['addr:city']);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': lat,
        'lon': lon,
        'amenity': amenity,
        'tags': tags,
        'sources': sources.toList(),
      };

  factory Place.fromJson(Map<String, dynamic> j) => Place(
        id: j['id'] as String,
        name: j['name'] as String,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        amenity: j['amenity'] as String? ?? '',
        tags: Map<String, String>.from(j['tags'] as Map),
        sources: (j['sources'] as List?)?.map((e) => '$e').toSet(),
      );

  /// Parses an Overpass `elements` entry. Returns null if unusable
  /// (no name or no coordinates).
  static Place? fromOverpass(
      Map<String, dynamic> e, double originLat, double originLon) {
    final tagsRaw = e['tags'];
    if (tagsRaw is! Map) return null;
    final tags = tagsRaw.map((k, v) => MapEntry('$k', '$v'));
    final name = _clean(tags['name']);
    if (name == null) return null;
    double? lat = (e['lat'] as num?)?.toDouble();
    double? lon = (e['lon'] as num?)?.toDouble();
    final center = e['center'];
    if ((lat == null || lon == null) && center is Map) {
      lat = (center['lat'] as num?)?.toDouble();
      lon = (center['lon'] as num?)?.toDouble();
    }
    if (lat == null || lon == null) return null;
    return Place(
      id: '${e['type']}/${e['id']}',
      name: name,
      lat: lat,
      lon: lon,
      amenity: tags['amenity'] ?? '',
      tags: tags,
      distanceM: haversineMeters(originLat, originLon, lat, lon),
    );
  }
}

List<Place> parseOverpass(
    Map<String, dynamic> json, double originLat, double originLon) {
  final els = json['elements'];
  if (els is! List) return [];
  final out = <Place>[];
  final seen = <String>{};
  for (final e in els) {
    if (e is! Map<String, dynamic>) continue;
    final p = Place.fromOverpass(e, originLat, originLon);
    if (p != null && seen.add(p.id)) out.add(p);
  }
  out.sort((a, b) => a.distanceM.compareTo(b.distanceM));
  return out;
}
