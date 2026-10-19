import 'package:flutter_test/flutter_test.dart';
import 'package:congressional_app/models/hazard_report.dart';
import 'package:congressional_app/services/hazard_codec.dart';

void main() {
  test('database record decodes', () {
    final result = HazardCodec.fromRow({
      'id': 'id',
      'school_id': 'sample-school',
      'type': 'blocked_path',
      'severity': 3,
      'description': 'Fictional example',
      'status': 'unverified',
      'latitude': 42.02,
      'longitude': -88.10,
      'is_demo': true,
      'created_at': '2026-10-18T00:00:00Z',
    });
    expect(result.type, HazardType.blockedPath);
    expect(result.isDemo, isTrue);
  });
  test('inserts cannot self-verify', () {
    final row = HazardCodec.insertPayload(
      HazardReport(
        id: 'local',
        schoolId: 'sample-school',
        type: HazardType.bikeRoute,
        severity: 3,
        description: 'Fictional example',
        createdAt: DateTime(2026),
        latitude: 42.02,
        longitude: -88.10,
      ),
      reporterId: 'user-id',
    );
    expect(row.containsKey('status'), isFalse);
    expect(row['is_demo'], isFalse);
  });
}
