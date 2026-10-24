import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/hazard_photo.dart';
import '../models/hazard_report.dart';
import '../models/report_moderation.dart';
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
    // RLS returns reviewed/own reports, or the full queue for moderators.
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
    final user = client.auth.currentUser;
    if (user == null) {
      throw StateError('Sign in using the account icon before saving.');
    }
    final row = await client
        .from('hazard_reports')
        .insert(HazardCodec.insertPayload(report, reporterId: user.id))
        .select(fields)
        .single();
    final saved = HazardCodec.fromRow(row);
    if (photo == null) return saved;

    onProgress?.call(.1);
    final path =
        '${saved.id}/${DateTime.now().microsecondsSinceEpoch}.${photo.extension}';
    var uploadStarted = false;
    try {
      await client.from('hazard_report_photos').insert({
        'report_id': saved.id,
        'owner_id': user.id,
        'storage_path': path,
      });
      onProgress?.call(.2);
      uploadStarted = true;
      onProgress?.call(.25);
      await client.storage
          .from('hazard-photos')
          .uploadBinary(
            path,
            photo.bytes,
            fileOptions: FileOptions(
              contentType: photo.mimeType,
              cacheControl: '3600',
              upsert: false,
            ),
          );
      onProgress?.call(.95);
      String? signedUrl;
      try {
        signedUrl = await client.storage
            .from('hazard-photos')
            .createSignedUrl(path, 600);
      } on StorageException {
        // The upload is complete. A later refresh can request a fresh URL.
      }
      onProgress?.call(1);
      return saved.withPhoto(path: path, signedUrl: signedUrl);
    } catch (error) {
      var objectRemoved = !uploadStarted;
      if (uploadStarted) {
        try {
          await client.storage.from('hazard-photos').remove([path]);
          objectRemoved = true;
        } catch (_) {
          objectRemoved = false;
        }
      }
      if (objectRemoved) {
        try {
          await client.from('hazard_reports').delete().eq('id', saved.id);
        } catch (_) {
          // The report remains visible to its owner and can be deleted later.
        }
      }
      throw StateError(_photoUploadMessage(error, objectRemoved));
    }
  }

  Future<void> deleteHazard(HazardReport report) async {
    final user = client.auth.currentUser;
    if (user == null) throw StateError('Sign in before deleting a report.');
    if (report.photoPath case final path?) {
      try {
        await client.storage.from('hazard-photos').remove([path]);
      } on StorageException catch (error) {
        throw StateError(
          'The report was not deleted because its photo could not be removed: ${error.message}',
        );
      }
    }
    await client.from('hazard_reports').delete().eq('id', report.id);
  }

  String _photoUploadMessage(Object error, bool cleanedUp) {
    final detail = switch (error) {
      StorageException(statusCode: '413') => 'The photo exceeds 5 MB.',
      StorageException(statusCode: '400', :final message) => message,
      StorageException(statusCode: '401' || '403') =>
        'Your account is not allowed to upload this photo.',
      StorageException(:final message) => message,
      PostgrestException(:final message) => message,
      _ => 'Check your connection and try again.',
    };
    return cleanedUp
        ? 'Photo upload failed. $detail No incomplete upload was kept.'
        : 'Photo upload failed. $detail The report was retained so its photo can be cleaned up safely.';
  }

  Future<bool> canModerate() async {
    if (client.auth.currentUser == null) return false;
    return await client.rpc('is_report_moderator') as bool;
  }

  Future<List<ReportFlag>> fetchFlags([String? schoolId]) async {
    if (client.auth.currentUser == null) return [];
    var query = client
        .from('report_flags')
        .select(
          'report_id,user_id,reason,created_at,reviewed_at,hazard_reports!inner(school_id)',
        );
    if (schoolId != null) {
      query = query.eq('hazard_reports.school_id', schoolId);
    }
    final rows = await query.order('created_at', ascending: false);
    return rows.map(ReportFlag.fromRow).toList();
  }

  Future<List<ModerationEvent>> fetchHistory(String reportId) async {
    if (client.auth.currentUser == null) return [];
    final rows = await client
        .from('report_moderation_history')
        .select('report_id,actor_id,previous_status,status,reason,created_at')
        .eq('report_id', reportId)
        .order('created_at', ascending: false);
    return rows.map(ModerationEvent.fromRow).toList();
  }

  Future<void> flagReport(HazardReport report, String reason) async {
    final user = client.auth.currentUser;
    if (user == null) throw StateError('Sign in before flagging a report.');
    await client.from('report_flags').insert({
      'report_id': report.id,
      'user_id': user.id,
      'reason': reason.trim(),
    });
  }

  Future<HazardReport> moderateReport(
    HazardReport report,
    ReportStatus status,
    String reason,
  ) async {
    final row = await client
        .rpc(
          'moderate_hazard_report',
          params: {
            'p_report_id': report.id,
            'p_status': status.name,
            'p_reason': reason.trim(),
            'p_expected_status': report.status.name,
          },
        )
        .single();
    final saved = HazardCodec.fromRow(row);
    return saved.withPhoto(
      path: report.photoPath,
      signedUrl: report.photoSignedUrl,
    );
  }
}
