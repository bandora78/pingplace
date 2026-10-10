import 'package:flutter/material.dart';

import 'src/simulation/development_simulation_screen.dart';

void main() {
  runApp(const PingPlaceApp());
}

final class PingPlaceApp extends StatelessWidget {
  const PingPlaceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PingPlace',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const DevelopmentSimulationScreen(),
    );
  }
}
