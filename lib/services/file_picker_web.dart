// ignore_for_file: avoid_web_libraries_in_flutter
/// 웹 전용 파일 선택 유틸리티
/// file_picker 웹 구현의 focus 타이밍 버그를 우회하기 위해 HTML input을 직접 사용
library;

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

class PickedFile {
  final String name;
  final int size;
  final html.File? _htmlFile;
  Uint8List? _bytes;

  PickedFile({required this.name, required this.size, html.File? htmlFile, Uint8List? bytes})
      : _htmlFile = htmlFile, _bytes = bytes;

  html.File? get htmlFile => _htmlFile;

  /// bytes가 필요할 때만 읽기 (lazy)
  Future<Uint8List> get bytes async {
    if (_bytes != null) return _bytes!;
    if (_htmlFile != null) {
      _bytes = await _readFileAsBytes(_htmlFile);
      return _bytes!;
    }
    throw Exception('파일 데이터 없음');
  }
}

/// 웹에서 파일 선택 다이얼로그를 직접 열고 File 객체를 반환 (bytes 즉시 로드 안 함)
Future<List<PickedFile>?> pickFilesWeb({
  String accept = '',
  bool multiple = false,
}) {
  final completer = Completer<List<PickedFile>?>();

  final input = html.FileUploadInputElement()
    ..accept = accept
    ..multiple = multiple
    ..style.display = 'none';

  html.document.body!.append(input);

  bool handled = false;

  void cleanup() {
    try { input.remove(); } catch (_) {}
  }

  input.onChange.listen((_) {
    if (handled) return;
    handled = true;
    cleanup();

    final files = input.files;
    if (files == null || files.isEmpty) {
      completer.complete(null);
      return;
    }

    final results = files.map((f) => PickedFile(
      name: f.name,
      size: f.size,
      htmlFile: f,
    )).toList();

    completer.complete(results);
  });

  input.addEventListener('cancel', (html.Event _) {
    if (handled) return;
    handled = true;
    cleanup();
    completer.complete(null);
  });

  input.click();
  return completer.future;
}

/// XHR 스트리밍 업로드 — 진행률 콜백 포함
/// [url]: 업로드 엔드포인트
/// [file]: html.File 객체 (메모리에 올리지 않음)
/// [fieldName]: multipart field 이름
/// [headers]: 추가 헤더 (Authorization 등)
/// [onProgress]: 0.0~1.0 진행률
/// 반환: 응답 body 문자열
Future<String> uploadFileXhr({
  required String url,
  required html.File file,
  String fieldName = 'file',
  Map<String, String> headers = const {},
  void Function(double progress)? onProgress,
}) {
  final completer = Completer<String>();
  final xhr = html.HttpRequest();
  xhr.open('POST', url);

  for (final entry in headers.entries) {
    xhr.setRequestHeader(entry.key, entry.value);
  }

  xhr.upload.onProgress.listen((event) {
    if (event.lengthComputable && onProgress != null) {
      onProgress(event.loaded! / event.total!);
    }
  });

  xhr.onLoad.listen((_) {
    if (xhr.status == 200) {
      completer.complete(xhr.responseText ?? '');
    } else {
      completer.completeError(
        Exception('업로드 실패 (${xhr.status}): ${xhr.responseText}'),
      );
    }
  });

  xhr.onError.listen((_) {
    completer.completeError(Exception('네트워크 오류'));
  });

  final formData = html.FormData();
  formData.appendBlob(fieldName, file, file.name);
  xhr.send(formData);

  return completer.future;
}

Future<Uint8List> _readFileAsBytes(html.File file) {
  final completer = Completer<Uint8List>();
  final reader = html.FileReader();
  reader.onLoadEnd.listen((_) {
    final result = reader.result;
    if (result is Uint8List) {
      completer.complete(result);
    } else {
      completer.completeError(Exception('파일 읽기 실패'));
    }
  });
  reader.readAsArrayBuffer(file);
  return completer.future;
}
