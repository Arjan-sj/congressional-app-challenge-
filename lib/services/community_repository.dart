import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/hazard_report.dart';
import 'hazard_codec.dart';

class CommunityReview {
  CommunityReview(Map<String, dynamic> data)
    : report =
          HazardCodec.fromRow(Map<String, dynamic>.from(data['report'] as Map))
              .withPhoto(
                path: data['photo_path'] as String?,
                signedUrl: data['photo_url'] as String?,
              ),
      counts = Map<String, dynamic>.from(data['counts'] as Map),
      ownChoice = data['own_choice'] as String?,
      canReview = data['can_review'] == true,
      changed = data['changed'] == true;
  final HazardReport report;
  final Map<String, dynamic> counts;
  final String? ownChoice;
  final bool canReview, changed;
  int get round => (counts['review_round'] as num? ?? 0).toInt();
  int count(String key) => (counts[key] as num? ?? 0).toInt();
}

class CommunityRepository {
  const CommunityRepository(this.client);
  final SupabaseClient client;
  static String newReportId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final s = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  static Future<String>? _visitor;
  static Future<String> visitorToken() => _visitor ??= _loadVisitor();
  static Future<String> _loadVisitor() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('community_visitor_token');
      if (stored != null && RegExp(r'^[-_A-Za-z0-9]{43}$').hasMatch(stored)) {
        return stored;
      }
      final random = Random.secure();
      final token = base64UrlEncode(
        List<int>.generate(32, (_) => random.nextInt(256)),
      ).replaceAll('=', '');
      if (!await prefs.setString('community_visitor_token', token)) {
        throw StateError('Unable to retain this browser’s review token.');
      }
      return token;
    } catch (_) {
      _visitor = null;
      rethrow;
    }
  }

  Future<Map<String, dynamic>> action(
    String action,
    Map<String, Object?> report, {
    Map<String, Object?>? photo,
  }) async {
    try {
      final r = await client.functions.invoke(
        'community-reports',
        body: {
          'action': action,
          'visitor': await visitorToken(),
          'report': report,
          'photo': ?photo,
        },
      );
      if (r.data is! Map) throw StateError('Unexpected community response.');
      return Map<String, dynamic>.from(r.data as Map);
    } on FunctionException catch (e) {
      final data = e.details;
      throw StateError(
        data is Map && data['error'] is String
            ? data['error'] as String
            : 'Community service is unavailable. Please retry.',
      );
    }
  }

  Future<CommunityReview> summary(String id) async =>
      CommunityReview(await action('summary', {'id': id}));
  Future<CommunityReview> review(
    CommunityReview current,
    String choice,
    String reason,
  ) async => CommunityReview(
    await action('review', {
      'id': current.report.id,
      'review_round': current.round,
      'expected_status': current.report.status.name,
      'choice': choice,
      'reason': reason.trim(),
    }),
  );
  Future<Map<String, Map<String, dynamic>>> totals(
    Iterable<String> reportIds,
  ) async {
    final ids = reportIds.toSet().toList(),
        result = <String, Map<String, dynamic>>{};
    for (var start = 0; start < ids.length; start += 100) {
      final rows = await client
          .from('community_review_totals')
          .select()
          .inFilter(
            'report_id',
            ids.sublist(start, (start + 100).clamp(0, ids.length)),
          );
      for (final row in rows) {
        result[row['report_id'] as String] = row;
      }
    }
    return result;
  }
}
