import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'screens/ar_survey_screen.dart';
import 'services/supabase_api.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(SupabaseApi.initialize());
  runApp(const ArcisApp());
}

class ArcisApp extends StatelessWidget {
  const ArcisApp({super.key});

  @override
  Widget build(BuildContext context) {
    final platform = defaultTargetPlatform;
    return MaterialApp(
      title: 'ARCIS Survey',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        platform: platform,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF67E8F9),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF071014),
        useMaterial3: true,
      ),
      home: const ArSurveyScreen(),
    );
  }
}

// Kept as an alias while existing widget tests and callers migrate to ArcisApp.
class MyApp extends ArcisApp {
  const MyApp({super.key});
}
