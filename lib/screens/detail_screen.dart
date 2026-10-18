import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/place.dart';
import '../services/app_state.dart';
import '../services/menu_scanner.dart';
import '../widgets/status_icons.dart';
import '../services/settings_store.dart';
import '../widgets/place_tile.dart';

Uri searchMenuUri(Place p) {
  final q = '${p.name} ${p.city ?? ''} menu'.replaceAll(RegExp(r'\s+'), ' ').trim();
  return Uri.https('www.google.com', '/search', {'q': q});
}

Uri directionsUri(Place p) => Uri.parse(
    'https://www.google.com/maps/dir/?api=1&destination=${p.lat},${p.lon}');

class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.state, required this.place});
  final AppState state;
  final Place place;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  MenuScanResult? scan;
  bool scanning = false;
  String? scanError;

  Place get p => widget.place;

  @override
  void initState() {
    super.initState();
    final site = p.website ?? p.menuUrl;
    final c = widget.state.checks[p.id];
    if (c != null && c.isFresh()) {
      scan = c.scan;
      if (!c.ok) scanError = 'Couldn\'t read the restaurant website.';
    } else if (site != null) {
      _scan();
    }
  }

  Future<void> _scan() async {
    setState(() => scanning = true);
    final c = await widget.state.ensureCheck(p, timeout: const Duration(seconds: 8));
    if (!mounted) return;
    setState(() {
      scan = c.scan;
      if (!c.ok) scanError = 'Couldn\'t read the restaurant website.';
      scanning = false;
    });
  }

  Future<void> _open(Uri u) async {
    final ok = await launchUrl(u, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No app available to open this.')));
    }
  }

  Future<void> _directions() async {
    final geo = Uri.parse('geo:${p.lat},${p.lon}?q=${p.lat},${p.lon}(${Uri.encodeComponent(p.name)})');
    if (await canLaunchUrl(geo)) {
      await launchUrl(geo);
    } else {
      await _open(directionsUri(p));
    }
  }

  /// Best direct menu link: OSM tag > scanned page link.
  ({Uri uri, String kind})? get bestMenu {
    if (p.menuUrl != null) return (uri: Uri.parse(p.menuUrl!), kind: 'tagged');
    final l = scan?.links;
    if (l != null && l.isNotEmpty) return (uri: Uri.parse(l.first.url), kind: 'scanned');
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final fav = widget.state.isFavorite(p);
        final best = bestMenu;
        return Scaffold(
          appBar: AppBar(
            title: Text(p.name, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                tooltip: fav ? 'Remove favorite' : 'Add favorite',
                icon: Icon(fav ? Icons.favorite : Icons.favorite_border, color: fav ? cs.primary : null),
                onPressed: () => widget.state.toggleFavorite(p),
              ),
            ],
          ),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              CircleAvatar(radius: 26, backgroundColor: cs.primaryContainer, child: Icon(typeIcon(p.type), color: cs.onPrimaryContainer)),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                Text([p.type.label, if (p.cuisineLabel != null) p.cuisineLabel!].join(' · ')),
                Text('${formatDistance(p.distanceM, widget.state.unit)} away', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
                Row(children: [
                  StatusIcons(place: p, state: widget.state, size: 24),
                  Expanded(child: Text(
                    switch (widget.state.menuInfo(p).state) {
                      MenuState.found => 'Menu found',
                      MenuState.pending => 'Checking menu…',
                      MenuState.none => 'No menu found',
                    } + (p.website != null ? ' · Website' : ' · No website'),
                    style: tt.bodySmall)),
                ]),
              ])),
            ]),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                icon: const Icon(Icons.menu_book),
                label: const Text('View menu'),
                onPressed: () => _open(best?.uri ?? (p.website != null ? Uri.parse(p.website!) : searchMenuUri(p))),
              ),
              if (p.phone != null)
                FilledButton.tonalIcon(icon: const Icon(Icons.call), label: const Text('Call'), onPressed: () => _open(Uri(scheme: 'tel', path: p.phone!.replaceAll(RegExp(r'[^0-9+]'), '')))),
              FilledButton.tonalIcon(icon: const Icon(Icons.directions), label: const Text('Directions'), onPressed: _directions),
              if (p.website != null)
                OutlinedButton.icon(icon: const Icon(Icons.language), label: const Text('Website'), onPressed: () => _open(Uri.parse(p.website!))),
            ]),
            const SizedBox(height: 20),
            _menuCard(context, best),
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              child: Column(children: [
                if (p.address != null) ListTile(leading: const Icon(Icons.place_outlined), title: Text(p.address!)),
                if (p.openingHours != null) ListTile(leading: const Icon(Icons.schedule), title: Text(p.openingHours!), subtitle: const Text('Opening hours (OSM format)')),
                if (p.phone != null) ListTile(leading: const Icon(Icons.phone_outlined), title: Text(p.phone!)),
                if (p.website != null) ListTile(leading: const Icon(Icons.language), title: Text(p.website!, maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (p.address == null && p.openingHours == null && p.phone == null && p.website == null)
                  const ListTile(leading: Icon(Icons.info_outline), title: Text('OpenStreetMap has no extra details for this place.')),
              ]),
            ),
            const SizedBox(height: 16),
            Text('Data © OpenStreetMap contributors · ${p.id}', style: tt.bodySmall?.copyWith(color: cs.outline)),
          ]),
        );
      },
    );
  }

  Widget _menuCard(BuildContext context, ({Uri uri, String kind})? best) {
    final cs = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    Widget row(IconData i, String title, String sub, Uri u, {bool good = true}) => ListTile(
          leading: Icon(i, color: good ? Colors.green : cs.outline),
          title: Text(title),
          subtitle: Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _open(u),
        );
    if (p.menuUrl != null) {
      rows.add(row(Icons.verified, 'Direct menu link', 'Listed in OpenStreetMap · ${p.menuUrl}', Uri.parse(p.menuUrl!)));
    }
    for (final l in scan?.links ?? <MenuLink>[]) {
      if (l.url == p.menuUrl) continue;
      rows.add(row(Icons.link, 'Menu link found on website: ${l.label}', l.url, Uri.parse(l.url)));
    }
    final items = scan?.schemaItems ?? [];
    Widget? itemsW;
    if (items.isNotEmpty) {
      itemsW = Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Published by the restaurant (schema.org data on its site):', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [for (final i in items) Chip(label: Text(i), visualDensity: VisualDensity.compact)]),
        ]),
      );
    }
    final hasDirect = rows.isNotEmpty;
    if (!hasDirect) {
      if (p.website != null) {
        rows.add(row(Icons.language, 'Restaurant website', 'No menu link detected. Opens the homepage — menu may be there.', Uri.parse(p.website!), good: false));
      }
      rows.add(row(Icons.search, 'Search fallback', 'Not a direct menu: a web search for "${p.name} ${p.city ?? ''} menu"', searchMenuUri(p), good: false));
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Row(children: [
            Text('Menu', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: 10),
            if (scanning) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            if (scanning) const Padding(padding: EdgeInsets.only(left: 6), child: Text('Checking website…')),
          ]),
        ),
        ...rows,
        if (itemsW != null) itemsW,
        if (scanError != null) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(scanError!, style: TextStyle(color: cs.outline))),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: Text(
            hasDirect
                ? 'Links come from OpenStreetMap tags or the restaurant\'s own site.'
                : 'No menu data is published for this place, so no menu items are shown.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
        ),
      ]),
    );
  }
}
