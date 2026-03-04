// 웹 플랫폼용 DS Excel Export - JS interop
// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:js_interop';

/// S3 고속 Export (원본 ZIP → merge → xlsx)
@JS('_exportDsFromS3')
external void _jsExportDsFromS3(
  JSString s3Url,
  JSString metaJson,
  JSFunction progressCallback,
  JSFunction completionCallback,
  JSString? authToken,
);

/// DB 폴백 Export (JSON → xlsx)
@JS('_exportDsToXlsx')
external void _jsExportDsToXlsx(
  JSString jsonString,
  JSFunction progressCallback,
  JSFunction completionCallback,
);

/// S3 presigned URL에서 xlsx 직접 다운로드
@JS('_downloadXlsxFromUrl')
external void _jsDownloadXlsxFromUrl(
  JSString url,
  JSString filename,
  JSFunction progressCallback,
  JSFunction completionCallback,
  JSString? authToken,
);

/// pre-built xlsx를 S3 presigned URL에서 직접 다운로드
Future<String> downloadXlsxFromUrl({
  required String url,
  required String filename,
  required void Function(String stage, double percent) onProgress,
  String? authToken,
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

  _jsDownloadXlsxFromUrl(
    url.toJS,
    filename.toJS,
    progressHandler.toJS,
    completionHandler.toJS,
    authToken?.toJS,
  );

  return completer.future.timeout(
    const Duration(minutes: 5),
    onTimeout: () => throw Exception('xlsx 다운로드 타임아웃 (5분 초과)'),
  );
}

/// S3에서 원본 ZIP 다운로드 → merge → xlsx 다운로드 (고속)
Future<String> exportDsFromS3({
  required String s3Url,
  required String metaJson,
  required void Function(String stage, double percent) onProgress,
  String? authToken,
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

  _jsExportDsFromS3(
    s3Url.toJS,
    metaJson.toJS,
    progressHandler.toJS,
    completionHandler.toJS,
    authToken?.toJS,
  );

  return completer.future.timeout(
    const Duration(minutes: 10),
    onTimeout: () => throw Exception('Excel Export 타임아웃 (10분 초과)'),
  );
}

/// DB 데이터를 xlsx로 변환 + 다운로드 (폴백용)
Future<String> exportDsToXlsx({
  required String jsonData,
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

  _jsExportDsToXlsx(
    jsonData.toJS,
    progressHandler.toJS,
    completionHandler.toJS,
  );

  return completer.future.timeout(
    const Duration(minutes: 10),
    onTimeout: () => throw Exception('Excel Export 타임아웃 (10분 초과)'),
  );
}
