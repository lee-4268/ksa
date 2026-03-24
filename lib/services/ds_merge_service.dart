import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

// 조건부 import - 플랫폼별 DS 병합
import 'ds_merge_service_stub.dart'
    if (dart.library.html) 'ds_merge_service_web.dart' as platform_merge;

class DsMergeService {
  /// ZIP 파일(들)을 선택하고 DS 파일 병합을 실행
  /// - 단일 ZIP: 기존과 동일하게 JS 병합 함수로 전달
  /// - 복수 ZIP: Dart에서 XLS 파일만 추출해 하나의 ZIP으로 합친 후 JS 병합 함수로 전달
  Future<String> pickAndMerge({
    required void Function(String stage, double percent) onProgress,
  }) async {
    onProgress('파일 선택 중...', 0);

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withData: true,
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) {
      throw Exception('파일이 선택되지 않았습니다.');
    }

    final files = result.files.where((f) => f.bytes != null).toList();
    if (files.isEmpty) throw Exception('파일을 읽을 수 없습니다.');

    Uint8List zipBytes;

    if (files.length == 1) {
      // 단일 파일: 기존 그대로
      zipBytes = files.first.bytes!;
      debugPrint('ZIP 파일 선택됨: ${files.first.name} (${zipBytes.length} bytes)');
    } else {
      // 복수 파일: Dart에서 XLS만 추출해 하나의 ZIP으로 병합
      onProgress('ZIP 파일 병합 중... (${files.length}개)', 2);
      debugPrint('복수 ZIP 선택: ${files.map((f) => f.name).join(', ')}');
      zipBytes = await compute(_mergeZipsIsolate,
          _MergeZipsArgs(files.map((f) => f.bytes!).toList(), files.map((f) => f.name).toList()));
      debugPrint('ZIP 병합 완료: ${zipBytes.length} bytes');
    }

    return platform_merge.mergeDsFiles(
      zipBytes: zipBytes,
      onProgress: onProgress,
    );
  }
}

/// isolate에서 실행할 ZIP 병합 (UI 스레드 블로킹 방지)
Uint8List _mergeZipsIsolate(_MergeZipsArgs args) {
  final outArchive = Archive();
  final seen = <String>{};

  for (var i = 0; i < args.zipBytesList.length; i++) {
    final bytes = args.zipBytesList[i];
    final rawName = args.fileNames[i];
    // 파일명 충돌 방지용 접두사 (확장자 제거)
    final prefix = rawName.endsWith('.zip')
        ? rawName.substring(0, rawName.length - 4)
        : rawName;

    late Archive srcArchive;
    try {
      srcArchive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      continue; // 손상된 ZIP 건너뜀
    }

    for (final file in srcArchive.files) {
      if (!file.isFile) continue;
      final entryName = file.name;
      final baseName = entryName.contains('/')
          ? entryName.split('/').last
          : entryName;
      final lower = baseName.toLowerCase();

      // XLS만 추출, xlsx 및 임시파일 제외
      if (!lower.endsWith('.xls')) continue;
      if (lower.endsWith('.xlsx')) continue;
      if (baseName.startsWith('~') || baseName.startsWith('.')) continue;

      final outName = '$prefix/$baseName';
      // 같은 경로 중복 방지
      if (seen.contains(outName)) continue;
      seen.add(outName);

      final content = file.content as List<int>;
      outArchive.addFile(ArchiveFile(outName, content.length, content));
    }
  }

  if (outArchive.isEmpty) {
    throw Exception('선택한 ZIP 파일 안에 .xls 파일이 없습니다.');
  }

  final encoded = ZipEncoder().encode(outArchive);
  if (encoded == null) throw Exception('ZIP 병합 실패');
  return Uint8List.fromList(encoded);
}

class _MergeZipsArgs {
  final List<Uint8List> zipBytesList;
  final List<String> fileNames;
  _MergeZipsArgs(this.zipBytesList, this.fileNames);
}
