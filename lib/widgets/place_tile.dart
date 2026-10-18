import 'package:flutter/material.dart';
import '../models/place.dart';
import '../services/app_state.dart';
import '../services/settings_store.dart';
import 'status_icons.dart';

IconData typeIcon(PlaceType t) => switch (t) {
      PlaceType.restaurant => Icons.restaurant,
      PlaceType.fastFood => Icons.fastfood,
      PlaceType.cafe => Icons.local_cafe,
      PlaceType.barPub => Icons.sports_bar,
      PlaceType.other => Icons.storefront,
    };

class PlaceTile extends StatelessWidget {
  const PlaceTile({super.key, required this.place, required this.state, required this.unit, required this.onTap, this.favorite = false});
  final Place place;
  final AppState state;
  final DistUnit unit;
  final VoidCallback onTap;
  final bool favorite;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final sub = [place.type.label, if (place.cuisineLabel != null) place.cuisineLabel!].join(' · ');
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
                backgroundColor: cs.primaryContainer,
                foregroundColor: cs.onPrimaryContainer,
                child: Icon(typeIcon(place.type))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(place.name, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (favorite) Icon(Icons.favorite, size: 16, color: cs.primary),
                  StatusIcons(place: place, state: state, size: 20),
                ]),
                Text(sub, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                if (place.address != null) Text(place.address!, style: tt.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (place.openingHours != null)
                  Row(children: [
                    Icon(Icons.schedule, size: 14, color: cs.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(child: Text(place.openingHours!, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                if (place.phone != null)
                  Row(children: [
                    Icon(Icons.phone, size: 14, color: cs.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(place.phone!, style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ]),
              ]),
            ),
            const SizedBox(width: 8),
            Text(formatDistance(place.distanceM, unit), style: tt.labelLarge?.copyWith(color: cs.primary, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}

class StateMessage extends StatelessWidget {
  const StateMessage({super.key, required this.icon, required this.title, this.body, this.actions = const []});
  final IconData icon;
  final String title;
  final String? body;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            if (body != null) ...[const SizedBox(height: 6), Text(body!, textAlign: TextAlign.center)],
            const SizedBox(height: 14),
            Wrap(spacing: 8, children: actions),
          ]),
        ),
      );
}
