/// 비웹 플랫폼 stub
library;

import 'dart:typed_data';

class PickedFile {
  final String name;
  final int size;
  dynamic get htmlFile => null;
  PickedFile({required this.name, required this.size, Uint8List? bytes}) : _bytes = bytes;
  final Uint8List? _bytes;
  Future<Uint8List> get bytes async {
    if (_bytes != null) return _bytes;
    throw UnsupportedError('stub');
  }
}

Future<List<PickedFile>?> pickFilesWeb({
  String accept = '',
  bool multiple = false,
}) {
  throw UnsupportedError('pickFilesWeb은 웹 플랫폼에서만 지원됩니다.');
}

Future<String> uploadFileXhr({
  required String url,
  required dynamic file,
  String fieldName = 'file',
  Map<String, String> headers = const {},
  void Function(double progress)? onProgress,
}) {
  throw UnsupportedError('uploadFileXhr은 웹 플랫폼에서만 지원됩니다.');
}
