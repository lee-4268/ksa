/// 비웹 플랫폼 stub
library;

import 'dart:typed_data';

class PickedFile {
  final String name;
  final Uint8List bytes;
  PickedFile({required this.name, required this.bytes});
}

Future<List<PickedFile>?> pickFilesWeb({
  String accept = '',
  bool multiple = false,
}) {
  throw UnsupportedError('pickFilesWeb은 웹 플랫폼에서만 지원됩니다.');
}
