import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';

const _url = "https://bnvmlxgdqgwjtxgtsaak.supabase.co";
const _key = "sb_publishable_FoOUlumYGi4Gw35445XCRw_63QESI8k";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_url.isEmpty != _key.isEmpty) {
    throw StateError(
      'Set both SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY or neither.',
    );
  }
  if (_url.isNotEmpty) {
    await Supabase.initialize(url: _url, publishableKey: _key);
  }
  runApp(
    SafeRoutesApp(liveClient: _url.isEmpty ? null : Supabase.instance.client),
  );
}
