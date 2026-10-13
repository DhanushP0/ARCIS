import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_config.dart';

class SupabaseApi {
  static const url = SupabaseConfig.url;
  static const publishableKey = SupabaseConfig.publishableKey;

  static bool get isConfigured =>
      url.startsWith('https://') &&
      !url.contains('YOUR_PROJECT') &&
      publishableKey.isNotEmpty &&
      !publishableKey.contains('YOUR_');

  static bool _initialized = false;
  static Future<void>? _initialization;

  static Future<void> initialize() => _initialization ??= _initialize();

  static Future<void> get ready => _initialization ?? Future<void>.value();

  static Future<void> _initialize() async {
    if (!isConfigured) return;
    try {
      await Supabase.initialize(url: url, publishableKey: publishableKey);
      _initialized = true;
    } catch (error) {
      debugPrint('ARCIS Supabase initialization failed: $error');
    }
  }

  static SupabaseClient? get client {
    if (!isConfigured || !_initialized) return null;
    return Supabase.instance.client;
  }
}
