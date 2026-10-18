import 'dart:convert';
import 'package:http/http.dart' as http;
import 'overpass_service.dart' show userAgent;

class MenuLink {
  MenuLink(this.url, this.label, {this.fromSchema = false});
  final String url;
  final String label;
  final bool fromSchema;
}

class MenuScanResult {
  MenuScanResult(this.links, this.schemaItems);
  final List<MenuLink> links;

  Map<String, dynamic> toJson() => {
        'links': [
          for (final l in links)
            {'u': l.url, 'l': l.label, 's': l.fromSchema}
        ],
        'items': schemaItems,
      };

  factory MenuScanResult.fromJson(Map<String, dynamic> j) => MenuScanResult([
        for (final l in (j['links'] as List? ?? []))
          MenuLink('${l['u']}', '${l['l']}', fromSchema: l['s'] == true)
      ], [
        for (final i in (j['items'] as List? ?? [])) '$i'
      ]);

  /// Section/item names published by the restaurant itself in schema.org JSON-LD.
  final List<String> schemaItems;
  bool get isEmpty => links.isEmpty && schemaItems.isEmpty;
}

class MenuScanner {
  MenuScanner({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  /// Fetches the page (first ~600 KB only) and looks for menu links.
  /// Short default timeout: this runs in bulk in the background.
  Future<MenuScanResult> scan(String websiteUrl,
      {Duration timeout = const Duration(seconds: 6)}) async {
    final uri = Uri.parse(websiteUrl);
    return _fetch(uri, websiteUrl).timeout(timeout);
  }

  Future<MenuScanResult> _fetch(Uri uri, String websiteUrl) async {
    final req = http.Request('GET', uri)
      ..headers.addAll({
        'User-Agent': userAgent,
        'Accept': 'text/html,application/xhtml+xml',
      });
    final res = await _client.send(req);
    if (res.statusCode != 200) {
      throw Exception('Website returned ${res.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in res.stream) {
      bytes.addAll(chunk);
      if (bytes.length > 600000) break;
    }
    final body = utf8.decode(bytes, allowMalformed: true);
    return parseHtml(body, res.request?.url ?? Uri.parse(websiteUrl));
  }

  static final _anchor = RegExp(
      r'''<a\b[^>]*?href\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>(.*?)</a>''',
      caseSensitive: false,
      dotAll: true);
  static final _tag = RegExp(r'<[^>]+>');
  static final _ld = RegExp(
      r'''<script[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>''',
      caseSensitive: false,
      dotAll: true);
  static const _skipExt = ['.jpg', '.jpeg', '.png', '.gif', '.svg', '.webp'];

  static MenuScanResult parseHtml(String html, Uri base) {
    final links = <MenuLink>[];
    final seen = <String>{};
    void add(MenuLink l) {
      if (seen.add(l.url)) links.add(l);
    }

    // schema.org JSON-LD
    final items = <String>[];
    for (final m in _ld.allMatches(html)) {
      try {
        _walkLd(jsonDecode(m.group(1)!.trim()), base, add, items);
      } catch (_) {}
    }

    for (final m in _anchor.allMatches(html)) {
      final href = (m.group(1) ?? m.group(2) ?? '').trim();
      if (href.isEmpty ||
          href.startsWith('#') ||
          href.startsWith('javascript:') ||
          href.startsWith('mailto:') ||
          href.startsWith('tel:')) {
        continue;
      }
      final text = m
          .group(3)!
          .replaceAll(_tag, ' ')
          .replaceAll(RegExp(r'&nbsp;|&amp;'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      Uri? u;
      try {
        u = base.resolve(href);
      } catch (_) {
        continue;
      }
      if (!u.hasScheme || !(u.scheme == 'http' || u.scheme == 'https')) continue;
      final lower = u.toString().toLowerCase();
      if (_skipExt.any((e) => u!.path.toLowerCase().endsWith(e))) continue;
      final textHit = RegExp(r'\bmenus?\b', caseSensitive: false).hasMatch(text) &&
          text.length <= 40;
      final pathHit = RegExp(r'menu', caseSensitive: false).hasMatch(u.path) ||
          lower.endsWith('menu.pdf');
      if (textHit || pathHit) {
        add(MenuLink(u.toString(), text.isEmpty || text.length > 40 ? 'Menu page' : text));
      }
    }
    // Prefer links whose visible text says "menu", then PDFs.
    links.sort((a, b) => _rank(a).compareTo(_rank(b)));
    return MenuScanResult(links.take(6).toList(), items.take(30).toList());
  }

  static int _rank(MenuLink l) {
    if (l.fromSchema) return 0;
    final t = l.label.toLowerCase();
    if (t == 'menu' || t == 'menus' || t == 'our menu' || t == 'view menu') return 1;
    if (t.contains('menu')) return 2;
    return 3;
  }

  static void _walkLd(dynamic node, Uri base, void Function(MenuLink) add,
      List<String> items) {
    if (node is List) {
      for (final n in node) {
        _walkLd(n, base, add, items);
      }
      return;
    }
    if (node is! Map) return;
    final type = node['@type'];
    final types = type is List ? type.map((e) => '$e').toList() : ['$type'];
    if (types.contains('Menu') || types.contains('MenuSection')) {
      final name = node['name'];
      if (name is String && name.trim().isNotEmpty) items.add(name.trim());
      final url = node['url'];
      if (url is String && types.contains('Menu')) {
        add(MenuLink(base.resolve(url).toString(),
            name is String && name.isNotEmpty ? name : 'Menu (from site data)',
            fromSchema: true));
      }
    }
    if (types.contains('MenuItem')) {
      final name = node['name'];
      if (name is String && name.trim().isNotEmpty) items.add(name.trim());
    }
    final hm = node['hasMenu'];
    if (hm is String) {
      add(MenuLink(base.resolve(hm).toString(), 'Menu (from site data)',
          fromSchema: true));
    }
    for (final v in node.values) {
      if (v is Map || v is List) _walkLd(v, base, add, items);
    }
  }
}
