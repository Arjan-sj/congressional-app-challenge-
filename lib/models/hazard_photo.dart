import 'dart:typed_data';

class HazardPhotoException implements Exception {
  const HazardPhotoException(this.message);

  final String message;

  @override
  String toString() => message;
}

class HazardPhotoDraft {
  const HazardPhotoDraft({
    required this.bytes,
    required this.mimeType,
    required this.extension,
    required this.fileName,
  });

  static const maxBytes = 5 * 1024 * 1024;
  static const allowedMimeTypes = {'image/jpeg', 'image/png', 'image/webp'};

  final Uint8List bytes;
  final String mimeType;
  final String extension;
  final String fileName;

  double get sizeMegabytes => bytes.length / (1024 * 1024);

  factory HazardPhotoDraft.validate({
    required Uint8List bytes,
    required String fileName,
    String? declaredMimeType,
  }) {
    if (bytes.isEmpty) {
      throw const HazardPhotoException('The selected image is empty.');
    }
    if (bytes.length > maxBytes) {
      throw const HazardPhotoException('Photos must be 5 MB or smaller.');
    }

    final detected = _detectMimeType(bytes);
    if (detected == null) {
      throw const HazardPhotoException('Choose a JPEG, PNG, or WebP image.');
    }
    final normalizedDeclared = declaredMimeType?.toLowerCase().split(';').first;
    if (normalizedDeclared != null &&
        normalizedDeclared.isNotEmpty &&
        normalizedDeclared != 'application/octet-stream' &&
        normalizedDeclared != detected) {
      throw const HazardPhotoException(
        'The image contents do not match its file type.',
      );
    }

    return HazardPhotoDraft(
      bytes: bytes,
      mimeType: detected,
      extension: switch (detected) {
        'image/jpeg' => 'jpg',
        'image/png' => 'png',
        'image/webp' => 'webp',
        _ => throw const HazardPhotoException('Unsupported image type.'),
      },
      fileName: fileName,
    );
  }

  static String? _detectMimeType(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }
}
