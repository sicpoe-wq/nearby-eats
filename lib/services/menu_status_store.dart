import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'menu_scanner.dart';

/// Persisted result of scanning one place's website for a menu.
class MenuCheck {
  MenuCheck({required this.ok, required this.scan, DateTime? at})
      : at = at ?? DateTime.now();

  /// false when the site could not be read (timeout, HTTP error...).
  final bool ok;
  final MenuScanResult scan;
  final DateTime at;

  String? get menuUrl => scan.links.isEmpty ? null : scan.links.first.url;
  bool get hasMenu => menuUrl != null;

  /// Successful scans stay valid 14 days, failures only 1 day.
  bool isFresh([DateTime? now]) =>
      (now ?? DateTime.now()).difference(at) <
      (ok ? const Duration(days: 14) : const Duration(days: 1));

  Map<String, dynamic> toJson() =>
      {'ok': ok, 't': at.millisecondsSinceEpoch, 'scan': scan.toJson()};

  factory MenuCheck.fromJson(Map<String, dynamic> j) => MenuCheck(
        ok: j['ok'] as bool? ?? true,
        at: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
        scan: MenuScanResult.fromJson(
            Map<String, dynamic>.from(j['scan'] as Map)),
      );
}

class MenuStatusStore {
  static const _key = 'menu_checks_v1';

  Future<Map<String, MenuCheck>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, MenuCheck>{};
      m.forEach((k, v) {
        try {
          final c = MenuCheck.fromJson(Map<String, dynamic>.from(v as Map));
          if (c.isFresh()) out[k] = c;
        } catch (_) {}
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> save(Map<String, MenuCheck> checks) async {
    final p = await SharedPreferences.getInstance();
    var entries = checks.entries.toList();
    if (entries.length > 2500) {
      entries.sort((a, b) => b.value.at.compareTo(a.value.at));
      entries = entries.take(2500).toList();
    }
    await p.setString(
        _key, jsonEncode({for (final e in entries) e.key: e.value.toJson()}));
  }
}
