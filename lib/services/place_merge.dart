import 'dart:math';
import '../models/place.dart';

/// Lower-case, drop accents/punctuation, possessives, location suffixes
/// ("Name - W Middlesex") and generic words, so "Marchelloni's Pizza" and
/// "Pizzas By Marchelloni - W Middlesex" compare as close.
List<String> nameTokens(String raw) {
  var s = raw.toLowerCase();
  // Overture/Meta often append " - <town>" or " | <town>".
  s = s.split(RegExp(r'\s[-–|]\s')).first;
  s = s
      .replaceAll(RegExp('[àáâãäå]'), 'a')
      .replaceAll(RegExp('[èéêë]'), 'e')
      .replaceAll(RegExp('[ìíîï]'), 'i')
      .replaceAll(RegExp('[òóôõö]'), 'o')
      .replaceAll(RegExp('[ùúûü]'), 'u')
      .replaceAll('ñ', 'n')
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r"['’`]s\b"), '')
      .replaceAll(RegExp(r"['’`]"), '')
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
  const stop = {
    'the', 'a', 'an', 'and', 'of', 'by', 'at', 'in', 'on', 'restaurant',
    'restaurants', 'inc', 'llc', 'ltd', 'co', 'company', 'corp', 'cafe',
    'grill', 'bar', 'pub', 'kitchen', 'eatery', 'shop', 'store', 'house',
  };
  final out = <String>[];
  for (var t in s.split(RegExp(r'\s+'))) {
    if (t.isEmpty) continue;
    if (t.length > 3 && t.endsWith('s')) t = t.substring(0, t.length - 1);
    if (!stop.contains(t)) out.add(t);
  }
  return out;
}

int _lev(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      cur[j] = min(min(cur[j - 1] + 1, prev[j] + 1),
          prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[b.length];
}

/// True when two business names plausibly refer to the same place.
bool namesMatch(String a, String b) {
  final ta = nameTokens(a), tb = nameTokens(b);
  if (ta.isEmpty || tb.isEmpty) {
    // Names made only of generic words ("Pizza Bar"): compare plainly.
    String plain(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return plain(a) == plain(b);
  }
  final sa = ta.join(), sb = tb.join();
  if (sa == sb) return true;
  final setA = ta.toSet(), setB = tb.toSet();
  final inter = setA.intersection(setB).length;
  // Every word of the shorter name appears in the longer one.
  if (inter == min(setA.length, setB.length) && inter >= 1) {
    if (min(sa.length, sb.length) >= 4) return true;
  }
  final jac = inter / setA.union(setB).length;
  if (jac >= 0.6) return true;
  final ratio = 1 - _lev(sa, sb) / max(sa.length, sb.length);
  if (ratio >= 0.8) return true;
  // Sorted tokens (word order swapped: "Pizza Marchelloni").
  final ssa = (List.of(ta)..sort()).join(), ssb = (List.of(tb)..sort()).join();
  return 1 - _lev(ssa, ssb) / max(ssa.length, ssb.length) >= 0.85;
}

String? phoneKey(String? p) {
  if (p == null) return null;
  final d = p.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.length < 10) return null;
  return d.substring(d.length - 10);
}

/// Same business? Needs a matching name within [maxMeters] (default
/// 100 m), or the same phone number within [phoneMeters] (default 300 m,
/// since pins for one phone number are often placed on different spots).
bool samePlace(Place a, Place b,
    {double maxMeters = 100, double phoneMeters = 300}) {
  if ((a.lat - b.lat).abs() > 0.004 || (a.lon - b.lon).abs() > 0.006) {
    return false;
  }
  final d = haversineMeters(a.lat, a.lon, b.lat, b.lon);
  if (d > max(maxMeters, phoneMeters)) return false;
  final pa = phoneKey(a.phone), pb = phoneKey(b.phone);
  if (pa != null && pa == pb && d <= phoneMeters) return true;
  return d <= maxMeters && namesMatch(a.name, b.name);
}

/// Copy missing details from [extra] into [base] tags (never overwrites).
Place _fill(Place base, Place extra) {
  final t = Map<String, String>.from(base.tags);
  void gap(String key, String? v) {
    if (v != null && v.isNotEmpty && (t[key] == null || t[key]!.trim().isEmpty)) {
      t[key] = v;
    }
  }

  if (base.website == null) gap('website', extra.website);
  if (base.phone == null) gap('phone', extra.phone);
  if (base.address == null) gap('addr:full', extra.address);
  gap('cuisine', extra.tags['cuisine']);
  gap('overture:category', extra.tags['overture:category']);
  gap('overture:confidence', extra.tags['overture:confidence']);
  return Place(
    id: base.id,
    name: base.name,
    lat: base.lat,
    lon: base.lon,
    amenity: base.amenity.isEmpty ? extra.amenity : base.amenity,
    tags: t,
    distanceM: base.distanceM,
    sources: {...base.sources, ...extra.sources},
  );
}

/// Combine OpenStreetMap places with Overture places (display-time only).
/// OSM tags win; Overture fills gaps; duplicates are dropped. Result is
/// sorted by distance.
List<Place> mergePlaces(List<Place> osm, List<Place> overture,
    {double maxMeters = 100}) {
  final out = <Place>[...osm];
  final matched = List<bool>.filled(osm.length, false);
  final extras = <Place>[];
  for (final o in overture) {
    var idx = -1;
    double best = double.infinity;
    for (var i = 0; i < osm.length; i++) {
      final b = osm[i];
      if (!samePlace(b, o, maxMeters: maxMeters)) continue;
      final d = haversineMeters(b.lat, b.lon, o.lat, o.lon);
      if (d < best) {
        best = d;
        idx = i;
      }
    }
    if (idx >= 0) {
      out[idx] = _fill(out[idx], o);
      matched[idx] = true;
      continue;
    }
    // De-duplicate within Overture itself.
    var dup = false;
    for (var k = 0; k < extras.length; k++) {
      if (samePlace(extras[k], o, maxMeters: maxMeters)) {
        extras[k] = _fill(extras[k], o);
        dup = true;
        break;
      }
    }
    if (!dup) extras.add(o);
  }
  out.addAll(extras);
  out.sort((a, b) => a.distanceM.compareTo(b.distanceM));
  return out;
}
