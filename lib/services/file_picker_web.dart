// ignore_for_file: avoid_web_libraries_in_flutter
/// 웹 전용 파일 선택 유틸리티
/// file_picker 웹 구현의 focus 타이밍 버그를 우회하기 위해 HTML input을 직접 사용
library;

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

class PickedFile {
  final String name;
  final Uint8List bytes;
  PickedFile({required this.name, required this.bytes});
}

/// 웹에서 파일 선택 다이얼로그를 직접 열고 바이트를 반환
/// [accept] : 예) '.zip'
/// [multiple]: 복수 선택 허용 여부
/// 취소 시 null 반환
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

  input.onChange.listen((_) async {
    if (handled) return;
    handled = true;
    cleanup();

    final files = input.files;
    if (files == null || files.isEmpty) {
      completer.complete(null);
      return;
    }

    final results = <PickedFile>[];
    for (final file in files) {
      final bytes = await _readFileAsBytes(file);
      if (bytes != null) {
        results.add(PickedFile(name: file.name, bytes: bytes));
      }
    }
    completer.complete(results.isEmpty ? null : results);
  });

  // Chrome 113+: cancel 이벤트 직접 지원
  input.addEventListener('cancel', (html.Event _) {
    if (handled) return;
    handled = true;
    cleanup();
    completer.complete(null);
  });

  input.click();
  return completer.future;
}

Future<Uint8List?> _readFileAsBytes(html.File file) {
  final completer = Completer<Uint8List?>();
  final reader = html.FileReader();
  reader.onLoadEnd.listen((_) {
    final result = reader.result;
    if (result is Uint8List) {
      completer.complete(result);
    } else {
      completer.complete(null);
    }
  });
  reader.readAsArrayBuffer(file);
  return completer.future;
}
