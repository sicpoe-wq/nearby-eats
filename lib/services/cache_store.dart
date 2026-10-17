import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class CachedEntry {
  CachedEntry(this.data, this.savedAt);
  final dynamic data;
  final DateTime savedAt;
  Duration get age => DateTime.now().difference(savedAt);
}

class CacheStore {
  Future<CachedEntry?> read(String key) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('cache:$key');
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return CachedEntry(
          j['data'], DateTime.fromMillisecondsSinceEpoch(j['t'] as int));
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, dynamic data) async {
    final p = await SharedPreferences.getInstance();
    // Keep cache bounded: drop oldest overpass entries beyond 8.
    final keys = p.getKeys().where((k) => k.startsWith('cache:overpass_')).toList();
    if (keys.length >= 8 && !keys.contains('cache:$key')) {
      final entries = <MapEntry<String, int>>[];
      for (final k in keys) {
        try {
          entries.add(MapEntry(
              k, (jsonDecode(p.getString(k)!) as Map)['t'] as int));
        } catch (_) {
          entries.add(MapEntry(k, 0));
        }
      }
      entries.sort((a, b) => a.value.compareTo(b.value));
      await p.remove(entries.first.key);
    }
    await p.setString('cache:$key',
        jsonEncode({'t': DateTime.now().millisecondsSinceEpoch, 'data': data}));
  }
}
