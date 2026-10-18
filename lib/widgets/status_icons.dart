import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/place.dart';
import '../services/app_state.dart';

/// Colors/semantics shared by every place of the app.
const menuActive = Color(0xFF2E9E5B);

Future<void> openUrlOrToast(BuildContext context, String url) async {
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No app available to open this.')));
  }
}

/// Menu + website status icons for one place. Tap = open directly.
class StatusIcons extends StatelessWidget {
  const StatusIcons({super.key, required this.place, required this.state, this.size = 22});
  final Place place;
  final AppState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dim = cs.onSurfaceVariant.withValues(alpha: 0.35);
    final m = state.menuInfo(place);
    final site = place.website;

    Widget btn({required Widget child, required String tip, VoidCallback? onTap}) =>
        Tooltip(
          message: tip,
          child: InkResponse(
            onTap: onTap,
            radius: size,
            child: Padding(padding: const EdgeInsets.all(5), child: SizedBox(width: size, height: size, child: Center(child: child))),
          ),
        );

    final menu = switch (m.state) {
      MenuState.found => btn(
          child: Icon(Icons.restaurant_menu, size: size, color: menuActive),
          tip: 'Menu found — tap to open',
          onTap: () => openUrlOrToast(context, m.url!)),
      MenuState.pending => btn(
          child: SizedBox(width: size * 0.7, height: size * 0.7, child: const CircularProgressIndicator(strokeWidth: 2)),
          tip: 'Checking for a menu…',
          onTap: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Still checking this website for a menu…')))),
      MenuState.none => btn(
          child: Icon(Icons.no_meals, size: size, color: dim),
          tip: 'No menu link found',
          onTap: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(site == null ? 'No website or menu on record for this place.' : 'No menu link found on its website. Open the place for options.')))),
    };
    final web = site != null
        ? btn(
            child: Icon(Icons.language, size: size, color: cs.primary),
            tip: 'Website found — tap to open',
            onTap: () => openUrlOrToast(context, site))
        : btn(
            child: Icon(Icons.public_off, size: size, color: dim),
            tip: 'No website on record',
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No website on record for this place.'))));
    return Row(mainAxisSize: MainAxisSize.min, children: [menu, web]);
  }
}

/// Thin progress bar + stage label shown above the list/map.
class LoadProgressBar extends StatelessWidget {
  const LoadProgressBar({super.key, required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) {
    if (!state.busy) return const SizedBox(height: 0);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      LinearProgressIndicator(value: state.progress, minHeight: 3),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 3, 16, 0),
        child: Text(state.stageLabel, style: Theme.of(context).textTheme.labelSmall),
      ),
    ]);
  }
}

class IconLegend extends StatelessWidget {
  const IconLegend({super.key});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dim = cs.onSurfaceVariant.withValues(alpha: 0.35);
    Widget row(Widget icon, String t) => ListTile(dense: true, leading: SizedBox(width: 28, child: Center(child: icon)), title: Text(t));
    return Column(mainAxisSize: MainAxisSize.min, children: [
      row(const Icon(Icons.restaurant_menu, color: menuActive), 'Green menu: a menu link was found (OpenStreetMap or the restaurant\'s site). Tap to open.'),
      row(const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)), 'Spinner: still checking the website for a menu.'),
      row(Icon(Icons.no_meals, color: dim), 'Dim crossed menu: no menu link found (or the site didn\'t respond).'),
      row(Icon(Icons.language, color: cs.primary), 'Blue globe: a website is on record. Tap to open.'),
      row(Icon(Icons.public_off, color: dim), 'Dim globe: no website on record.'),
    ]);
  }
}

Future<void> showIconLegend(BuildContext context) => showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('What the icons mean'),
        content: const SingleChildScrollView(child: IconLegend()),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Got it'))],
      ),
    );
