import 'package:flutter/material.dart';
import '../services/app_state.dart';
import '../widgets/place_tile.dart';
import 'detail_screen.dart';

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key, required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) => Scaffold(
          appBar: AppBar(title: const Text('Favorites')),
          body: state.favorites.isEmpty
              ? const StateMessage(
                  icon: Icons.favorite_border,
                  title: 'No favorites yet',
                  body: 'Tap the heart on a restaurant to save it here.')
              : ListView(children: [
                  for (final p in state.favorites)
                    PlaceTile(
                      place: p,
                      state: state,
                      unit: state.unit,
                      favorite: true,
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DetailScreen(state: state, place: p))),
                    ),
                ]),
        ),
      );
}
