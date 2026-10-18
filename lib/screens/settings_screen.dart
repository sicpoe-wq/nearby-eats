import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../services/settings_store.dart';
import '../widgets/status_icons.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state});
  final AppState state;

  static const radii = [500, 1000, 2000, 5000, 10000, 20000];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) => Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Text('Distance units', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<DistUnit>(
              segments: const [
                ButtonSegment(value: DistUnit.mi, label: Text('Miles')),
                ButtonSegment(value: DistUnit.km, label: Text('Kilometers')),
              ],
              selected: {state.unit},
              onSelectionChanged: (s) => state.setDefaults(state.radiusM, s.first),
            ),
            const SizedBox(height: 24),
            Text('Default search radius', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final r in radii)
                ChoiceChip(
                  label: Text(formatDistance(r.toDouble(), state.unit)),
                  selected: state.radiusM == r,
                  onSelected: (_) {
                    state.setDefaults(r, state.unit);
                    state.setRadius(r);
                  },
                ),
            ]),
            const SizedBox(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Include Overture Maps places'),
              subtitle: const Text(
                  'Adds places OpenStreetMap is missing (for example small-town pizza shops). '
                  'Downloads small regional data files the first time you search an area, then keeps them on your phone.'),
              value: state.overtureEnabled,
              onChanged: state.setOvertureEnabled,
            ),
            const SizedBox(height: 16),
            Text('Menu & website icons', style: Theme.of(context).textTheme.titleMedium),
            const IconLegend(),
            const SizedBox(height: 16),
            const Divider(),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Data sources & attribution'),
              subtitle: Text('Restaurants: © OpenStreetMap contributors (ODbL) via the '
                  'Overpass API, plus places from Overture Maps Foundation (overturemaps.org), '
                  'which includes data from Meta, Microsoft, Foursquare, PinMeTo, Krick, RenderSEO, '
                  'DAC, BrightQuery and AllThePlaces, under CDLA Permissive 2.0 / Apache 2.0 / CC0. '
                  'Foursquare data © Foursquare Labs, Inc. (Apache 2.0). '
                  'Overture Maps Foundation, overturemaps.org. '
                  'The two sources are combined on your phone only when shown; Nearby Eats does not '
                  'publish a combined database. '
                  'Geocoding: OpenStreetMap Nominatim. Menus are only what restaurants '
                  'publish on their own websites or in OSM tags; the app never invents menu items.'),
            ),
          ]),
        ),
      );
}
