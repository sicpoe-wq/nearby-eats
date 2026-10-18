import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/place.dart';

enum DistUnit { mi, km }

String formatDistance(double meters, DistUnit u) {
  if (u == DistUnit.mi) {
    final mi = meters / 1609.344;
    return mi < 0.1 ? '${(meters * 3.28084).round()} ft' : '${mi.toStringAsFixed(mi < 10 ? 1 : 0)} mi';
  }
  return meters < 1000
      ? '${meters.round()} m'
      : '${(meters / 1000).toStringAsFixed(meters < 10000 ? 1 : 0)} km';
}

class SettingsStore {
  Future<({int radiusM, DistUnit unit})> load() async {
    final p = await SharedPreferences.getInstance();
    return (
      radiusM: p.getInt('radiusM') ?? 2000,
      unit: p.getString('unit') == 'km' ? DistUnit.km : DistUnit.mi,
    );
  }

  Future<void> save(int radiusM, DistUnit unit) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('radiusM', radiusM);
    await p.setString('unit', unit.name);
  }

  Future<bool> loadOverture() async =>
      (await SharedPreferences.getInstance()).getBool('overture') ?? true;

  Future<void> saveOverture(bool v) async =>
      (await SharedPreferences.getInstance()).setBool('overture', v);

  Future<List<Place>> loadFavorites() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('favorites');
    if (raw == null) return [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          Place.fromJson(e as Map<String, dynamic>)
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveFavorites(List<Place> favs) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('favorites', jsonEncode(favs.map((f) => f.toJson()).toList()));
  }
}
