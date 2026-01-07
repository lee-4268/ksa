// 웹 플랫폼용 Excel 내보내기
// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:convert';
import 'dart:html' as html;
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'photo_storage_service.dart';

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

    // 사진 파일들 추가
    int addedCount = 0;
    for (final photoInfo in photoInfoList) {
      final originalPath = photoInfo['originalPath'] as String;
      final folderName = photoInfo['folderName'] as String;
      final fileName = photoInfo['fileName'] as String;

      try {
        Uint8List? photoBytes;

        // 1. S3 URL인 경우 - presigned URL을 가져와서 다운로드
        if (originalPath.startsWith('s3://')) {
          debugPrint('S3 사진 처리 중: $originalPath');
          try {
            final presignedUrl = await PhotoStorageService.getPhotoUrl(originalPath);
            debugPrint('Presigned URL 획득: ${presignedUrl.substring(0, 50)}...');
            final response = await http.get(Uri.parse(presignedUrl));
            if (response.statusCode == 200) {
              photoBytes = response.bodyBytes;
              debugPrint('S3 사진 다운로드 완료: ${photoBytes.length} bytes');
            } else {
              debugPrint('S3 사진 다운로드 실패: HTTP ${response.statusCode}');
            }
          } catch (e) {
            debugPrint('S3 사진 처리 오류: $e');
          }
        }
        // 2. base64 data URL인 경우 - 디코딩
        else if (originalPath.startsWith('data:')) {
          debugPrint('Base64 사진 처리 중');
          try {
            // data:image/jpeg;base64,/9j/4AAQSkZJRgABA... 형식에서 base64 부분 추출
            final base64Start = originalPath.indexOf(',');
            if (base64Start != -1) {
              final base64String = originalPath.substring(base64Start + 1);
              photoBytes = base64Decode(base64String);
              debugPrint('Base64 사진 디코딩 완료: ${photoBytes.length} bytes');
            }
          } catch (e) {
            debugPrint('Base64 사진 디코딩 오류: $e');
          }
        }
        // 3. HTTP/HTTPS URL인 경우 - 직접 다운로드
        else if (originalPath.startsWith('http://') || originalPath.startsWith('https://')) {
          debugPrint('HTTP 사진 다운로드 중: $originalPath');
          try {
            final response = await http.get(Uri.parse(originalPath));
            if (response.statusCode == 200) {
              photoBytes = response.bodyBytes;
              debugPrint('HTTP 사진 다운로드 완료: ${photoBytes.length} bytes');
            }
          } catch (e) {
            debugPrint('HTTP 사진 다운로드 오류: $e');
          }
        }
        // 4. blob: URL인 경우 (세션 만료로 대부분 실패)
        else if (originalPath.startsWith('blob:')) {
          debugPrint('Blob URL 사진 시도 (세션 만료 가능): $originalPath');
          try {
            final response = await http.get(Uri.parse(originalPath));
            if (response.statusCode == 200) {
              photoBytes = response.bodyBytes;
            }
          } catch (e) {
            debugPrint('Blob URL 접근 실패 (세션 만료): $e');
          }
        }

        // 사진 바이트가 있으면 ZIP에 추가
        if (photoBytes != null && photoBytes.isNotEmpty) {
          archive.addFile(ArchiveFile('photos/$folderName/$fileName', photoBytes.length, photoBytes));
          addedCount++;
          debugPrint('사진 추가 완료: photos/$folderName/$fileName');
        } else {
          debugPrint('사진 추가 실패 (바이트 없음): $originalPath');
        }
      } catch (e) {
        debugPrint('웹 사진 파일 읽기 오류: $originalPath - $e');
      }
    }

    debugPrint('총 ${photoInfoList.length}개 중 $addedCount개 사진 추가됨');

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

    debugPrint('웹 ZIP 파일 다운로드 완료: $zipFileName (사진 $addedCount개 포함)');
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
