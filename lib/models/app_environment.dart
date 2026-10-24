import 'dart:convert';

/// Public client configuration only. Operator/database secrets never belong here.
class AppEnvironment {
  const AppEnvironment(this.name, this.url, this.publishableKey);
  static const productionProjectId = 'bnvmlxgdqgwjtxgtsaak';
  static const productionUrl = 'https://$productionProjectId.supabase.co';
  static const productionKey = 'sb_publishable_FoOUlumYGi4Gw35445XCRw_63QESI8k';
  final String name;
  final String url;
  final String publishableKey;

  factory AppEnvironment.fromDefines() => AppEnvironment.parse(
    name: const String.fromEnvironment(
      'SAFEROUTES_ENVIRONMENT',
      defaultValue: 'production',
    ),
    url: const String.fromEnvironment('SUPABASE_URL'),
    key: const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
  );

  factory AppEnvironment.parse({
    required String name,
    String url = '',
    String key = '',
  }) {
    if (!const ['production', 'staging', 'local'].contains(name)) {
      throw StateError(
        'SAFEROUTES_ENVIRONMENT must be production, staging, or local.',
      );
    }
    if (url.isEmpty && key.isEmpty && name == 'production') {
      return const AppEnvironment('production', productionUrl, productionKey);
    }
    final uri = Uri.tryParse(url);
    final local =
        uri != null &&
        const ['127.0.0.1', 'localhost', '::1'].contains(uri.host);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        key.isEmpty ||
        (name == 'local'
            ? !local || !const ['http', 'https'].contains(uri.scheme)
            : uri.scheme != 'https')) {
      throw StateError(
        'Set a valid SUPABASE_URL and public key for the selected environment.',
      );
    }
    if (name == 'staging' &&
        (local || uri.host == '$productionProjectId.supabase.co')) {
      throw StateError('Staging must use a separate Supabase project.');
    }
    if (name == 'production' &&
        uri.host != '$productionProjectId.supabase.co') {
      throw StateError(
        'Use the staging or local environment for a separate project.',
      );
    }
    var secret = key.startsWith('sb_secret_');
    if (key.split('.').length == 3) {
      try {
        final claims = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(key.split('.')[1]))),
        ) as Map;
        secret = secret || claims['role'] != 'anon';
      } catch (_) {
        secret = true;
      }
    } else if (!key.startsWith('sb_publishable_')) {
      secret = true;
    }
    if (secret) {
      throw StateError(
        'Flutter requires a publishable or legacy anon key, never a secret/service-role key.',
      );
    }
    return AppEnvironment(name, url, key);
  }
}
