import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/hazard_photo.dart';
import '../models/hazard_report.dart';

import 'dart:convert';

import 'community_repository.dart';
import '../models/nearby_school.dart';
import 'hazard_codec.dart';

class SupabaseHazardRepository {
  const SupabaseHazardRepository(this.client);
  final SupabaseClient client;

  static const _metadataBatchSize = 100;
  static const _signedUrlBatchSize = 12;

  Future<List<NearbySchool>> findNearbySchools(
    double latitude,
    double longitude,
  ) async {
    final rows = await client.rpc(
      'nearest_schools',
      params: {'p_latitude': latitude, 'p_longitude': longitude},
    );
    return (rows as List)
        .map(
          (row) => NearbySchool.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList(growable: false);
  }

  static const fields =
      'id,school_id,type,severity,description,status,latitude,longitude,'
      'is_demo,created_at,reporter_id,school:schools!hazard_reports_school_id_fkey(name)';

  Future<List<HazardReport>> fetchHazards({
    String? schoolId,
    String? reportId,
  }) async {
    // RLS includes public community reports and protects historical private data.
    final rows = <Map<String, dynamic>>[];
    final schoolIds = <String>[?schoolId];
    if (schoolId != null) {
      final aliases = await client
          .from('schools')
          .select('id')
          .eq('canonical_id', schoolId);
      schoolIds.addAll(aliases.map((row) => row['id'] as String));
    }
    // Stable keyset pagination: no silent 1,000-row truncation in report lists.
    String? after;
    while (true) {
      var query = client
          .from('hazard_reports')
          .select(fields)
          .eq('is_demo', false);
      if (schoolId != null) query = query.inFilter('school_id', schoolIds);
      if (reportId != null) query = query.eq('id', reportId);
      if (after != null) query = query.gt('id', after);
      final page = await query.order('id').limit(500);
      rows.addAll(page);
      if (page.length < 500) break;
      after = page.last['id'] as String;
    }
    rows.sort(
      (a, b) =>
          (b['created_at'] as String).compareTo(a['created_at'] as String),
    );
    final reports = rows.map(HazardCodec.fromRow).toList();
    if (reports.isEmpty) return reports;

    final photoRows = <Map<String, dynamic>>[];
    final reportIds = reports.map((report) => report.id).toList();
    for (var start = 0; start < reportIds.length; start += _metadataBatchSize) {
      final end = (start + _metadataBatchSize).clamp(0, reportIds.length);
      final batchRows = await client
          .from('hazard_report_photos')
          .select('report_id,storage_path')
          .inFilter('report_id', reportIds.sublist(start, end));
      photoRows.addAll(batchRows);
    }
    final paths = <String, String>{
      for (final row in photoRows)
        row['report_id'] as String: row['storage_path'] as String,
    };
    final signedUrls = <String, String?>{};
    final uniquePaths = paths.values.toSet().toList();
    for (
      var start = 0;
      start < uniquePaths.length;
      start += _signedUrlBatchSize
    ) {
      final end = (start + _signedUrlBatchSize).clamp(0, uniquePaths.length);
      await Future.wait([
        for (final path in uniquePaths.sublist(start, end))
          () async {
            try {
              signedUrls[path] = await client.storage
                  .from('hazard-photos')
                  .createSignedUrl(path, 600);
            } catch (_) {
              // One temporary URL failure must not hide the report list.
              signedUrls[path] = null;
            }
          }(),
      ]);
    }
    return [
      for (final report in reports)
        if (paths[report.id] case final path?)
          report.withPhoto(path: path, signedUrl: signedUrls[path])
        else
          report,
    ];
  }

  Future<HazardReport> submitHazard(
    HazardReport report, {
    HazardPhotoDraft? photo,
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(.1);
    final result = await CommunityRepository(client).action('submit', {
      'id': report.id,
      'type': HazardCodec.types[report.type],
      'severity': report.severity,
      'description': report.description.trim(),
      'latitude': report.latitude,
      'longitude': report.longitude,
    }, photo: photo == null ? null : {'base64': base64Encode(photo.bytes)});
    onProgress?.call(1);
    return CommunityReview(result).report;
  }
}
