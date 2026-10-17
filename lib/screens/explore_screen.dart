import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/place.dart';
import '../services/app_state.dart';
import '../services/geocode_service.dart';
import '../services/settings_store.dart';
import '../widgets/place_tile.dart';
import 'detail_screen.dart';

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key, required this.state});
  final AppState state;
  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  final locCtrl = TextEditingController();
  final nameCtrl = TextEditingController();
  final mapCtrl = MapController();
  Timer? _debounce;
  List<GeoResult> suggestions = [];
  bool geocoding = false;
  String? geoError;
  bool mapView = false;

  AppState get s => widget.state;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onLocChanged(String v) {
    _debounce?.cancel();
    if (v.trim().length < 3) {
      setState(() => suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 900), () => _geocode(v, pickFirst: false));
  }

  Future<void> _geocode(String q, {required bool pickFirst}) async {
    _debounce?.cancel();
    if (q.trim().isEmpty) return;
    setState(() {
      geocoding = true;
      geoError = null;
    });
    try {
      final r = await s.geocoder.search(q.trim());
      if (!mounted) return;
      if (r.isEmpty) {
        setState(() {
          geoError = 'No place found for "$q"';
          suggestions = [];
        });
      } else if (pickFirst) {
        _choose(r.first);
      } else {
        setState(() => suggestions = r);
      }
    } catch (e) {
      if (mounted) setState(() => geoError = 'Search failed: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => geocoding = false);
    }
  }

  void _choose(GeoResult g) {
    FocusScope.of(context).unfocus();
    final short = g.name.split(',').take(2).join(',').trim();
    locCtrl.text = short;
    setState(() => suggestions = []);
    s.useCoordinates(g.lat, g.lon, short);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          final list = s.filtered;
          return Scaffold(
            appBar: AppBar(
              title: const Text('Nearby Eats', style: TextStyle(fontWeight: FontWeight.w800)),
              actions: [
                IconButton(
                  tooltip: mapView ? 'List view' : 'Map view',
                  icon: Icon(mapView ? Icons.view_list : Icons.map_outlined),
                  onPressed: () => setState(() => mapView = !mapView),
                ),
              ],
            ),
            body: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: TextField(
                  controller: locCtrl,
                  textInputAction: TextInputAction.search,
                  onChanged: _onLocChanged,
                  onSubmitted: (v) => _geocode(v, pickFirst: true),
                  decoration: InputDecoration(
                    hintText: 'City or ZIP (or use GPS)',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: geocoding
                        ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                        : IconButton(
                            tooltip: 'Use my location',
                            icon: const Icon(Icons.my_location),
                            onPressed: () {
                              locCtrl.clear();
                              setState(() => suggestions = []);
                              s.useGps();
                            }),
                  ),
                ),
              ),
              if (geoError != null)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Align(alignment: Alignment.centerLeft, child: Text(geoError!, style: TextStyle(color: Theme.of(context).colorScheme.error)))),
              if (suggestions.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView(shrinkWrap: true, children: [
                    for (final g in suggestions)
                      ListTile(dense: true, leading: const Icon(Icons.place_outlined), title: Text(g.name, maxLines: 2, overflow: TextOverflow.ellipsis), onTap: () => _choose(g)),
                  ]),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
                  child: TextField(
                    controller: nameCtrl,
                    onChanged: (v) => s.setFilters(name: v),
                    decoration: const InputDecoration(hintText: 'Filter by name', prefixIcon: Icon(Icons.restaurant_menu), isDense: true),
                  ),
                ),
                _filters(),
                if (s.showingCache && s.status == LoadStatus.ready)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      const Icon(Icons.history, size: 14),
                      const SizedBox(width: 4),
                      Expanded(child: Text('Saved results${s.cachedAt != null ? ' from ${_ago(s.cachedAt!)}' : ''}', style: Theme.of(context).textTheme.bodySmall)),
                      TextButton(onPressed: () => s.refresh(force: true), child: const Text('Refresh')),
                    ]),
                  ),
                Expanded(child: _body(list)),
              ],
            ]),
          );
        },
      );

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)} min ago';
    if (d.inHours < 48) return '${d.inHours} h ago';
    return '${d.inDays} days ago';
  }

  Widget _filters() {
    final cuisines = s.cuisineOptions.take(40).toList();
    return SizedBox(
      height: 48,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 10), children: [
        for (final t in PlaceType.values.where((t) => t != PlaceType.other))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
            child: FilterChip(
              label: Text(t.label),
              selected: s.types.contains(t),
              onSelected: (v) {
                final n = {...s.types};
                v ? n.add(t) : n.remove(t);
                s.setFilters(t: n);
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
          child: ActionChip(
            avatar: const Icon(Icons.radar, size: 16),
            label: Text('Radius ${formatDistance(s.radiusM.toDouble(), s.unit)}'),
            onPressed: _pickRadius,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
          child: ActionChip(
            avatar: const Icon(Icons.ramen_dining, size: 16),
            label: Text(s.cuisine == null ? 'Cuisine' : 'Cuisine: ${s.cuisine}'),
            onPressed: cuisines.isEmpty ? null : () => _pickCuisine(cuisines),
          ),
        ),
      ]),
    );
  }

  Future<void> _pickRadius() async {
    final r = await showModalBottomSheet<int>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final r in const [500, 1000, 2000, 5000, 10000, 20000])
            ListTile(
              title: Text(formatDistance(r.toDouble(), s.unit)),
              trailing: r == s.radiusM ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, r),
            ),
        ]),
      ),
    );
    if (r != null) s.setRadius(r);
  }

  Future<void> _pickCuisine(List<String> cuisines) async {
    final c = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: const Text('All cuisines'), onTap: () => Navigator.pop(context, '')),
            for (final c in cuisines)
              ListTile(
                title: Text(c[0].toUpperCase() + c.substring(1)),
                trailing: c == s.cuisine ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, c),
              ),
          ]),
        ),
      ),
    );
    if (c == null) return;
    c.isEmpty ? s.setFilters(clearCuisine: true) : s.setFilters(cuisine: c);
  }

  Widget _body(List<Place> list) {
    switch (s.status) {
      case LoadStatus.idle:
      case LoadStatus.locating:
        return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Finding your location…')]));
      case LoadStatus.loading:
        if (s.all.isEmpty) {
          return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Searching OpenStreetMap…')]));
        }
        break;
      case LoadStatus.error:
        return StateMessage(
          icon: Icons.location_off_outlined,
          title: 'Something went wrong',
          body: s.error,
          actions: [
            FilledButton(onPressed: s.lat != null ? () => s.refresh(force: true) : s.useGps, child: const Text('Try again')),
            if (s.permissionPermanentlyDenied) OutlinedButton(onPressed: Geolocator.openAppSettings, child: const Text('Open app settings')),
          ],
        );
      case LoadStatus.ready:
        break;
    }
    if (list.isEmpty) {
      return StateMessage(
        icon: Icons.no_food_outlined,
        title: 'No places found',
        body: s.all.isEmpty
            ? 'OpenStreetMap has no named food places within this radius. Try a larger radius.'
            : 'No results match your filters.',
        actions: [if (s.all.isEmpty) FilledButton(onPressed: () => s.setRadius((s.radiusM * 2).clamp(500, 20000)), child: const Text('Widen radius'))],
      );
    }
    return mapView ? _map(list) : RefreshIndicator(
      onRefresh: () => s.refresh(force: true),
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: list.length + 1,
        itemBuilder: (c, i) => i == 0
            ? Padding(padding: const EdgeInsets.fromLTRB(18, 4, 18, 2), child: Text('${list.length} places near ${s.locationLabel} · nearest first', style: Theme.of(context).textTheme.bodySmall))
            : PlaceTile(place: list[i - 1], unit: s.unit, favorite: s.isFavorite(list[i - 1]), onTap: () => _open(list[i - 1])),
      ),
    );
  }

  void _open(Place p) => Navigator.push(context, MaterialPageRoute(builder: (_) => DetailScreen(state: s, place: p)));

  Widget _map(List<Place> list) {
    final center = LatLng(s.lat!, s.lon!);
    return FlutterMap(
      key: ValueKey('${s.lat}_${s.lon}_${s.radiusM}'),
      mapController: mapCtrl,
      options: MapOptions(initialCenter: center, initialZoom: s.radiusM > 5000 ? 12 : s.radiusM > 1500 ? 14 : 15),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.tim.nearby_eats',
        ),
        MarkerLayer(markers: [
          Marker(point: center, width: 22, height: 22, child: Container(decoration: BoxDecoration(color: Colors.blue, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)))),
          for (final p in list.take(300))
            Marker(
              point: LatLng(p.lat, p.lon),
              width: 40,
              height: 40,
              child: GestureDetector(
                onTap: () => _open(p),
                child: Container(
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                  child: Icon(typeIcon(p.type), size: 20, color: Colors.white),
                ),
              ),
            ),
        ]),
        RichAttributionWidget(attributions: [
          TextSourceAttribution('© OpenStreetMap contributors', onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright'), mode: LaunchMode.externalApplication)),
        ]),
      ],
    );
  }
}

