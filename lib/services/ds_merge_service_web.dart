// 웹 플랫폼용 DS 파일 병합 - JS interop
// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

/// JavaScript에서 DS 병합 함수 호출
@JS('_mergeDsFilesFromDart')
external void _jsMergeDsFiles(
  JSArrayBuffer zipBytes,
  JSFunction progressCallback,
  JSFunction completionCallback,
);

/// DS 파일 병합 실행 (웹 전용)
Future<String> mergeDsFiles({
  required Uint8List zipBytes,
  required void Function(String stage, double percent) onProgress,
}) async {
  final completer = Completer<String>();

  void progressHandler(JSString stage, JSNumber percent) {
    onProgress(stage.toDart, percent.toDartDouble);
  }

  void completionHandler(JSBoolean success, JSString message) {
    if (success.toDart) {
      completer.complete(message.toDart);
    } else {
      completer.completeError(Exception(message.toDart));
    }
  }

  final jsArrayBuffer = zipBytes.buffer.toJS;

  _jsMergeDsFiles(
    jsArrayBuffer,
    progressHandler.toJS,
    completionHandler.toJS,
  );

  return completer.future.timeout(
    const Duration(minutes: 10),
    onTimeout: () => throw Exception('DS 파일 병합 타임아웃 (10분 초과)'),
  );
}
