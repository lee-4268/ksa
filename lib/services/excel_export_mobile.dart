// 모바일 (Android/iOS) 플랫폼용 Excel 내보내기
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 모바일에서 Excel 파일 저장
Future<String?> saveExcelFile(Uint8List bytes, String fileName) async {
  final directory = await getApplicationDocumentsDirectory();
  final filePath = '${directory.path}/$fileName';

  final file = File(filePath);
  await file.writeAsBytes(bytes);

  return filePath;
}

/// 모바일에서 Excel 파일 공유
Future<void> shareExcelFile(String filePath) async {
  await Share.shareXFiles(
    [XFile(filePath)],
    subject: 'Excel 검사 결과 내보내기',
  );
}
