import 'package:flutter/material.dart';
import 'screens/home_shell.dart';
import 'services/app_state.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const NearbyEatsApp());
}

class NearbyEatsApp extends StatefulWidget {
  const NearbyEatsApp({super.key});
  @override
  State<NearbyEatsApp> createState() => _NearbyEatsAppState();
}

class _NearbyEatsAppState extends State<NearbyEatsApp> {
  final state = AppState();
  @override
  void initState() {
    super.initState();
    state.init();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Nearby Eats',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(Brightness.light),
        darkTheme: AppTheme.build(Brightness.dark),
        themeMode: ThemeMode.system,
        home: HomeShell(state: state),
      );
}
