// 웹 플랫폼용 Excel 내보내기
// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 웹에서 Excel 파일 저장 (다운로드)
Future<String?> saveExcelFile(Uint8List bytes, String fileName, {bool saveOnly = false}) async {
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

/// 웹에서 Excel + 사진을 ZIP으로 저장
Future<String?> saveExcelWithPhotosAsZip(
  Uint8List excelBytes,
  String excelFileName,
  List<Map<String, dynamic>> photoInfoList,
  String zipFileName,
  {bool saveOnly = false}
) async {
  try {
    // 사진이 없으면 Excel만 다운로드
    if (photoInfoList.isEmpty) {
      return saveExcelFile(excelBytes, excelFileName, saveOnly: saveOnly);
    }

    // ZIP 아카이브 생성
    final archive = Archive();

    // Excel 파일 추가
    archive.addFile(ArchiveFile(excelFileName, excelBytes.length, excelBytes));

    // 사진 파일들 추가 (웹에서는 blob URL에서 가져오기)
    for (final photoInfo in photoInfoList) {
      final originalPath = photoInfo['originalPath'] as String;
      final folderName = photoInfo['folderName'] as String;
      final fileName = photoInfo['fileName'] as String;

      try {
        // 웹에서는 blob: URL이므로 HTTP로 가져오기
        if (originalPath.startsWith('blob:')) {
          final response = await http.get(Uri.parse(originalPath));
          if (response.statusCode == 200) {
            final photoBytes = response.bodyBytes;
            // photos/국소명/사진.jpg 구조로 저장
            archive.addFile(ArchiveFile('photos/$folderName/$fileName', photoBytes.length, photoBytes));
            debugPrint('웹 사진 추가: photos/$folderName/$fileName');
          }
        }
      } catch (e) {
        debugPrint('웹 사진 파일 읽기 오류: $originalPath - $e');
      }
    }

    // ZIP 파일 인코딩
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw Exception('ZIP 파일 생성 실패');
    }

    // ZIP 파일 다운로드
    final blob = html.Blob([zipBytes], 'application/zip');
    final url = html.Url.createObjectUrlFromBlob(blob);

    final anchor = html.AnchorElement()
      ..href = url
      ..download = zipFileName
      ..style.display = 'none';

    html.document.body?.children.add(anchor);
    anchor.click();

    // 정리
    html.document.body?.children.remove(anchor);
    html.Url.revokeObjectUrl(url);

    debugPrint('웹 ZIP 파일 다운로드 완료: $zipFileName');
    return zipFileName;
  } catch (e) {
    debugPrint('웹 ZIP 파일 생성 오류: $e');
    // 오류 발생 시 Excel만 다운로드
    return saveExcelFile(excelBytes, excelFileName, saveOnly: saveOnly);
  }
}

/// 웹에서 Excel 파일 공유 (웹에서는 다운로드로 대체)
Future<void> shareExcelFile(String filePath) async {
  // 웹에서는 이미 다운로드되었으므로 아무 작업 안함
  // 또는 Web Share API 사용 가능 (브라우저 지원 확인 필요)
}
