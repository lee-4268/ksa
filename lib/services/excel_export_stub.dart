// Stub 파일 - 실제로는 사용되지 않음
import 'dart:typed_data';

Future<String?> saveExcelFile(Uint8List bytes, String fileName, {bool saveOnly = false}) async {
  throw UnsupportedError('플랫폼을 지원하지 않습니다.');
}

Future<String?> saveExcelWithPhotosAsZip(
  Uint8List excelBytes,
  String excelFileName,
  List<Map<String, dynamic>> photoInfoList,
  String zipFileName,
  {bool saveOnly = false}
) async {
  throw UnsupportedError('플랫폼을 지원하지 않습니다.');
}

Future<void> shareExcelFile(String filePath) async {
  throw UnsupportedError('플랫폼을 지원하지 않습니다.');
}
