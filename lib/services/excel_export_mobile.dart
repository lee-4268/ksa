// 모바일 (Android/iOS) 플랫폼용 Excel 내보내기
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 저장 디렉토리 가져오기
Future<Directory> _getExportDirectory() async {
  Directory? directory;

  if (Platform.isAndroid) {
    // Android: Downloads 폴더 시도 -> 외부 저장소 -> 앱 문서 디렉토리
    try {
      directory = Directory('/storage/emulated/0/Download');
      if (!await directory.exists()) {
        directory = await getExternalStorageDirectory();
      }
    } catch (_) {
      directory = await getExternalStorageDirectory();
    }
    directory ??= await getApplicationDocumentsDirectory();
  } else {
    // iOS: 앱 문서 디렉토리
    directory = await getApplicationDocumentsDirectory();
  }

  return directory;
}

/// 모바일에서 Excel 파일 저장
/// saveOnly: true면 저장만, false면 공유 다이얼로그도 표시
Future<String?> saveExcelFile(Uint8List bytes, String fileName, {bool saveOnly = false}) async {
  try {
    final directory = await _getExportDirectory();
    final filePath = '${directory.path}/$fileName';
    debugPrint('Excel 파일 저장 경로: $filePath');

    final file = File(filePath);
    await file.writeAsBytes(bytes);

    debugPrint('Excel 파일 저장 완료: ${file.lengthSync()} bytes');

    // saveOnly가 false면 공유 다이얼로그 표시
    if (!saveOnly) {
      await Share.shareXFiles(
        [XFile(filePath)],
        subject: 'Excel 검사 결과',
        text: '$fileName 파일을 공유합니다.',
      );
    }

    return filePath;
  } catch (e) {
    debugPrint('Excel 파일 저장 오류: $e');
    rethrow;
  }
}

/// 모바일에서 Excel + 사진을 ZIP으로 저장
/// saveOnly: true면 저장만, false면 공유 다이얼로그도 표시
Future<String?> saveExcelWithPhotosAsZip(
  Uint8List excelBytes,
  String excelFileName,
  List<Map<String, dynamic>> photoInfoList,
  String zipFileName,
  {bool saveOnly = false}
) async {
  try {
    final directory = await _getExportDirectory();

    // ZIP 아카이브 생성
    final archive = Archive();

    // Excel 파일 추가
    archive.addFile(ArchiveFile(excelFileName, excelBytes.length, excelBytes));

    // 사진 파일들 추가 (국소명 폴더별로 저장)
    for (final photoInfo in photoInfoList) {
      final originalPath = photoInfo['originalPath'] as String;
      final folderName = photoInfo['folderName'] as String;
      final fileName = photoInfo['fileName'] as String;

      try {
        final file = File(originalPath);
        if (await file.exists()) {
          final photoBytes = await file.readAsBytes();
          // photos/국소명/사진.jpg 구조로 저장
          archive.addFile(ArchiveFile('photos/$folderName/$fileName', photoBytes.length, photoBytes));
          debugPrint('사진 추가: $originalPath -> photos/$folderName/$fileName');
        }
      } catch (e) {
        debugPrint('사진 파일 읽기 오류: $originalPath - $e');
      }
    }

    // ZIP 파일 인코딩 및 저장
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw Exception('ZIP 파일 생성 실패');
    }

    final zipPath = '${directory.path}/$zipFileName';
    final zipFile = File(zipPath);
    await zipFile.writeAsBytes(zipBytes);

    debugPrint('ZIP 파일 저장 완료: $zipPath (${zipFile.lengthSync()} bytes)');

    // saveOnly가 false면 공유 다이얼로그 표시
    if (!saveOnly) {
      await Share.shareXFiles(
        [XFile(zipPath)],
        subject: '검사 결과 (Excel + 사진)',
        text: '$zipFileName 파일을 공유합니다.',
      );
    }

    return zipPath;
  } catch (e) {
    debugPrint('ZIP 파일 저장 오류: $e');
    rethrow;
  }
}

/// 모바일에서 파일 공유
Future<void> shareExcelFile(String filePath) async {
  try {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('파일이 존재하지 않습니다: $filePath');
    }

    await Share.shareXFiles(
      [XFile(filePath)],
      subject: '검사 결과 내보내기',
    );
  } catch (e) {
    debugPrint('파일 공유 오류: $e');
    rethrow;
  }
}
