import 'dart:typed_data';

import 'package:congressional_app/models/hazard_photo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts supported image signatures', () {
    final photo = HazardPhotoDraft.validate(
      bytes: Uint8List.fromList([
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]),
      fileName: 'evidence.png',
      declaredMimeType: 'image/png',
    );

    expect(photo.mimeType, 'image/png');
    expect(photo.extension, 'png');
  });

  test('rejects disguised and oversized files', () {
    expect(
      () => HazardPhotoDraft.validate(
        bytes: Uint8List.fromList([0xff, 0xd8, 0xff, 0x00]),
        fileName: 'not-really.png',
        declaredMimeType: 'image/png',
      ),
      throwsA(isA<HazardPhotoException>()),
    );
    expect(
      () => HazardPhotoDraft.validate(
        bytes: Uint8List(HazardPhotoDraft.maxBytes + 1),
        fileName: 'large.jpg',
        declaredMimeType: 'image/jpeg',
      ),
      throwsA(
        isA<HazardPhotoException>().having(
          (error) => error.message,
          'message',
          contains('5 MB'),
        ),
      ),
    );
  });
}
