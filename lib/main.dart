import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'models/app_environment.dart';

Future<void> discardPreviousSession(String url) async {
  final storage = SharedPreferencesLocalStorage(
    persistSessionKey: 'sb-${Uri.parse(url).host.split('.').first}-auth-token',
  );
  try {
    await storage.initialize();
    await storage.removePersistedSession();
  } catch (_) {
    // EmptyLocalStorage below still prevents any previous identity restoration.
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = AppEnvironment.fromDefines();
  await discardPreviousSession(environment.url);
  await Supabase.initialize(
    url: environment.url,
    publishableKey: environment.publishableKey,
    authOptions: FlutterAuthClientOptions(
      autoRefreshToken: false,
      detectSessionInUri: false,
      localStorage: EmptyLocalStorage(),
    ),
  );
  runApp(
    SafeRoutesApp(
      liveClient: Supabase.instance.client,
      environmentName: environment.name,
    ),
  );
}
