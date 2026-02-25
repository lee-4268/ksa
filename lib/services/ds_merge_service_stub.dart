// Stub 파일 - 웹이 아닌 플랫폼에서는 사용 불가
import 'dart:typed_data';

Future<String> mergeDsFiles({
  required Uint8List zipBytes,
  required void Function(String stage, double percent) onProgress,
}) async {
  throw UnsupportedError('DS 파일 병합은 웹 플랫폼에서만 지원됩니다.');
}
