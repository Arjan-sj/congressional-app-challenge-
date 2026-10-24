import 'dart:convert';

import 'package:congressional_app/models/app_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production preserves the existing public project configuration', () {
    final config = AppEnvironment.parse(name: 'production');
    expect(config.url, AppEnvironment.productionUrl);
    expect(config.publishableKey, AppEnvironment.productionKey);
  });
  test('staging requires separate explicit public credentials', () {
    expect(() => AppEnvironment.parse(name: 'staging'), throwsStateError);
    expect(
      () => AppEnvironment.parse(
        name: 'staging',
        url: AppEnvironment.productionUrl,
        key: AppEnvironment.productionKey,
      ),
      throwsStateError,
    );
    final config = AppEnvironment.parse(
      name: 'staging',
      url: 'https://abcdefghijklmnopqrst.supabase.co',
      key: 'sb_publishable_test',
    );
    expect(config.name, 'staging');
    expect(
      () => AppEnvironment.parse(
        name: 'production',
        url: config.url,
        key: config.publishableKey,
      ),
      throwsStateError,
    );
  });
  test('local uses explicit loopback credentials and rejects hosted URLs', () {
    expect(
      AppEnvironment.parse(
        name: 'local',
        url: 'http://127.0.0.1:54321',
        key: 'sb_publishable_local',
      ).name,
      'local',
    );
    expect(
      () => AppEnvironment.parse(
        name: 'local',
        url: AppEnvironment.productionUrl,
        key: AppEnvironment.productionKey,
      ),
      throwsStateError,
    );
    expect(
      () => AppEnvironment.parse(
        name: 'staging',
        url: 'http://127.0.0.1:54321',
        key: 'sb_publishable_local',
      ),
      throwsStateError,
    );
  });
  test('secret, service-role, malformed and incomplete client configuration is rejected', () {
    String jwt(String role) =>
        'e30.${base64Url.encode(utf8.encode(jsonEncode({'role': role}))).replaceAll('=', '')}.signature';
    for (final key in [
      'sb_secret_never_in_flutter',
      jwt('service_role'),
      'invalid',
    ]) {
      expect(
        () => AppEnvironment.parse(
          name: 'production',
          url: AppEnvironment.productionUrl,
          key: key,
        ),
        throwsStateError,
      );
    }
    expect(
      AppEnvironment.parse(
        name: 'local',
        url: 'http://localhost:54321',
        key: jwt('anon'),
      ).name,
      'local',
    );
    expect(() => AppEnvironment.parse(name: 'unknown'), throwsStateError);
    expect(
      () => AppEnvironment.parse(
        name: 'production',
        url: AppEnvironment.productionUrl,
      ),
      throwsStateError,
    );
    expect(
      () => AppEnvironment.parse(
        name: 'staging',
        url: 'https://',
        key: 'sb_publishable_test',
      ),
      throwsStateError,
    );
  });
}
