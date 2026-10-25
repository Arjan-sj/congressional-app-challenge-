import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class MemoryAccountStorage extends GotrueAsyncStorage {
  final values = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => values[key];
  @override
  Future<void> setItem({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    values.remove(key);
  }
}

class AccountFixture {
  AccountFixture() {
    client = SupabaseClient(
      'https://example.supabase.co',
      'public-test-key',
      authOptions: AuthClientOptions(
        autoRefreshToken: false,
        pkceAsyncStorage: MemoryAccountStorage(),
      ),
      httpClient: MockClient(_respond),
    );
  }
  late final SupabaseClient client;
  final calls = <http.Request>[];
  bool invalid = false,
      unverified = false,
      failRefresh = false,
      requiresPassword = false,
      moderator = false;
  String? username = 'traveler', applicationStatus;
  String email = 'one@example.test';
  String get userId => email == 'two@example.test'
      ? '93000000-0000-0000-0000-000000000002'
      : '93000000-0000-0000-0000-000000000001';
  Map<String, dynamic> get user => {
    'id': userId,
    'email': email,
    'aud': 'authenticated',
    'email_confirmed_at': unverified ? null : '2026-01-01T00:00:00Z',
    'created_at': '2026-01-01T00:00:00Z',
    'app_metadata': {},
    'user_metadata': {},
  };
  String get token {
    String encode(Object data) =>
        base64Url.encode(utf8.encode(jsonEncode(data))).replaceAll('=', '');
    return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': userId, 'role': 'authenticated', 'exp': 4102444800})}.synthetic';
  }

  Future<http.Response> _respond(http.Request r) async {
    calls.add(r);
    final p = r.url.path;
    final raw = r.body.isEmpty ? null : jsonDecode(r.body);
    final data = raw is Map<String, dynamic> ? raw : <String, dynamic>{};
    Object? body;
    if (p.endsWith('/functions/v1/account-auth')) {
      if (invalid) {
        return http.Response(
          '{"error":"private email and backend detail"}',
          401,
          headers: {'content-type': 'application/json'},
        );
      }
      body = data['action'] == 'preflight'
          ? {'allowed': true}
          : {'access_token': token, 'refresh_token': 'username-refresh'};
    } else if (p.endsWith('/token')) {
      if (invalid ||
          failRefresh && r.url.queryParameters['grant_type'] == 'refresh_token') {
        return http.Response(
          '{"msg":"private backend detail","error_code":"invalid_credentials"}',
          400,
          headers: {'content-type': 'application/json'},
        );
      }
      email = data['email'] as String? ?? email;
      body = {
        'access_token': token,
        'refresh_token': 'synthetic-refresh',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': user,
      };
    } else if (p.endsWith('/signup')) {
      body = {...user, 'email_confirmed_at': null};
    } else if (p.endsWith('/logout')) {
      return http.Response('', 204);
    } else if (p.endsWith('/recover') || p.endsWith('/resend')) {
      body = {};
    } else if (p.endsWith('/user')) {
      if (data['password'] != null) requiresPassword = false;
      body = user;
    } else if (p.endsWith('/user_profiles')) {
      if (r.method == 'PATCH') {
        username = data['username'] as String?;
        return http.Response(
          jsonEncode({'user_id': userId, 'username': username}),
          200,
          request: r,
          headers: {'content-type': 'application/json'},
        );
      }
      body = [
        {
          'user_id': userId,
          'username': username,
          'requires_password_change': requiresPassword,
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        },
      ];
    } else if (p.endsWith('/moderator_access_requests')) {
      body = applicationStatus == null
          ? []
          : [
              {
                'id': '94000000-0000-0000-0000-000000000001',
                'request_status': applicationStatus,
                'created_at': '2026-01-01T00:00:00Z',
              },
            ];
    } else if (p.endsWith('/request_moderator_access')) {
      applicationStatus = 'pending';
      body = {'request_status': 'pending'};
    } else if (p.endsWith('/is_report_moderator')) {
      body = moderator && !requiresPassword;
    } else {
      throw StateError('Unexpected account fixture request: ${r.method} $p');
    }
    return http.Response(
      jsonEncode(body),
      200,
      request: r,
      headers: {'content-type': 'application/json'},
    );
  }
}
