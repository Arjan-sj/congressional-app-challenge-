import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'models/app_environment.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = AppEnvironment.fromDefines();
  await Supabase.initialize(
    url: environment.url,
    publishableKey: environment.publishableKey,
  );
  runApp(
    SafeRoutesApp(
      liveClient: Supabase.instance.client,
      environmentName: environment.name,
    ),
  );
}
