import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

// 조건부 import - 플랫폼별 DS 병합
import 'ds_merge_service_stub.dart'
    if (dart.library.html) 'ds_merge_service_web.dart' as platform_merge;

class DsMergeService {
  /// ZIP 파일을 선택하고 DS 파일 병합을 실행
  Future<String> pickAndMerge({
    required void Function(String stage, double percent) onProgress,
  }) async {
    onProgress('파일 선택 중...', 0);

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) {
      throw Exception('파일이 선택되지 않았습니다.');
    }

    final file = result.files.first;
    final Uint8List? bytes = file.bytes;

    if (bytes == null) {
      throw Exception('파일을 읽을 수 없습니다.');
    }

    debugPrint('ZIP 파일 선택됨: ${file.name} (${bytes.length} bytes)');

    return platform_merge.mergeDsFiles(
      zipBytes: bytes,
      onProgress: onProgress,
    );
  }
}
