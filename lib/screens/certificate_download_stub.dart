import 'dart:typed_data';

/// Stub for non-web platforms
void downloadFileBytes(Uint8List bytes, String filename) {
  // No-op on non-web platforms
}

void openDownloadUrl(String url, String filename) {
  // No-op on non-web platforms
}
