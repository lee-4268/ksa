// 웹 플랫폼용 DS 업로드 - JS interop
// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

/// JavaScript에서 DS 파싱 함수 호출
@JS('_parseDsForUpload')
external void _jsParseDsForUpload(
  JSArrayBuffer zipBytes,
  JSFunction chunkCallback,
  JSFunction progressCallback,
  JSFunction completionCallback,
);

/// ZIP → 병합 xlsx → S3 PUT
@JS('_buildDsXlsxAndUploadToS3')
external void _jsBuildDsXlsxAndUploadToS3(
  JSArrayBuffer zipBytes,
  JSString xlsxPutUrl,
  JSString metaJson,
  JSFunction progressCallback,
  JSFunction completionCallback,
);

/// ZIP bytes → 병합 xlsx 생성 → S3 PUT (업로드 시 pre-built xlsx 저장)
Future<void> buildDsXlsxAndUploadToS3({
  required Uint8List zipBytes,
  required String xlsxPutUrl,
  required String metaJson,
  required void Function(String stage, double percent) onProgress,
}) async {
  final completer = Completer<void>();

  void progressHandler(JSString stage, JSNumber percent) {
    onProgress(stage.toDart, percent.toDartDouble);
  }

  void completionHandler(JSBoolean success, JSString message) {
    if (success.toDart) {
      completer.complete();
    } else {
      completer.completeError(Exception(message.toDart));
    }
  }

  _jsBuildDsXlsxAndUploadToS3(
    zipBytes.buffer.toJS,
    xlsxPutUrl.toJS,
    metaJson.toJS,
    progressHandler.toJS,
    completionHandler.toJS,
  );

  return completer.future.timeout(
    const Duration(minutes: 20),
    onTimeout: () => throw Exception('xlsx 생성 타임아웃 (20분 초과)'),
  );
}

/// DS 파일 파싱 실행 (웹 전용)
/// 반환값: 메타 JSON 문자열 (divisionId, importDate, sheetStats 등)
Future<String> parseDsForUpload({
  required Uint8List zipBytes,
  required Future<void> Function(String chunkJson) onChunk,
  required void Function(String stage, double percent) onProgress,
}) async {
  final completer = Completer<String>();

  // 청크 큐: JS는 동기, Dart HTTP는 비동기이므로 큐에 쌓아서 순차 처리
  final chunkQueue = <String>[];
  var processingDone = false;

  void chunkHandler(JSString chunkJson) {
    chunkQueue.add(chunkJson.toDart);
  }

  void progressHandler(JSString stage, JSNumber percent) {
    onProgress(stage.toDart, percent.toDartDouble);
  }

  void completionHandler(JSBoolean success, JSString message, JSString metaJson) {
    processingDone = true;
    if (success.toDart) {
      completer.complete(metaJson.toDart);
    } else {
      completer.completeError(Exception(message.toDart));
    }
  }

  final jsArrayBuffer = zipBytes.buffer.toJS;

  _jsParseDsForUpload(
    jsArrayBuffer,
    chunkHandler.toJS,
    progressHandler.toJS,
    completionHandler.toJS,
  );

  // JS 파싱이 완료될 때까지 청크 큐를 순차 처리
  while (!processingDone || chunkQueue.isNotEmpty) {
    if (chunkQueue.isNotEmpty) {
      final chunk = chunkQueue.removeAt(0);
      await onChunk(chunk);
    } else {
      // 큐가 비어있으면 잠시 대기
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  return completer.future.timeout(
    const Duration(minutes: 15),
    onTimeout: () => throw Exception('DS 파일 파싱 타임아웃 (15분 초과)'),
  );
}
