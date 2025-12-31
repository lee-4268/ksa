// 웹 플랫폼용 Excel 내보내기
// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;
import 'dart:typed_data';

/// 웹에서 Excel 파일 저장 (다운로드)
Future<String?> saveExcelFile(Uint8List bytes, String fileName) async {
  // Blob 생성
  final blob = html.Blob([bytes], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');

  // 다운로드 URL 생성
  final url = html.Url.createObjectUrlFromBlob(blob);

  // 다운로드 링크 생성 및 클릭
  final anchor = html.AnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';

  html.document.body?.children.add(anchor);
  anchor.click();

  // 정리
  html.document.body?.children.remove(anchor);
  html.Url.revokeObjectUrl(url);

  // 웹에서는 파일 경로가 없으므로 파일명 반환
  return fileName;
}

/// 웹에서 Excel 파일 공유 (웹에서는 다운로드로 대체)
Future<void> shareExcelFile(String filePath) async {
  // 웹에서는 이미 다운로드되었으므로 아무 작업 안함
  // 또는 Web Share API 사용 가능 (브라우저 지원 확인 필요)
}
