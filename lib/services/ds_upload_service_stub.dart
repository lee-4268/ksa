// 비웹 플랫폼용 DS 업로드 stub
import 'dart:typed_data';

Future<String> parseDsForUpload({
  required Uint8List zipBytes,
  required Future<void> Function(String chunkJson) onChunk,
  required void Function(String stage, double percent) onProgress,
}) async {
  throw UnsupportedError('DS 파일 업로드는 웹 플랫폼에서만 지원됩니다.');
}

Future<void> buildDsXlsxAndUploadToS3({
  required Uint8List zipBytes,
  required String xlsxPutUrl,
  required String metaJson,
  required void Function(String stage, double percent) onProgress,
}) async {
  throw UnsupportedError('DS xlsx 생성은 웹 플랫폼에서만 지원됩니다.');
}
