import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as excel_pkg;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import '../models/radio_station.dart';

// 조건부 import - 플랫폼별 파일 저장/공유
import 'excel_export_stub.dart'
    if (dart.library.io) 'excel_export_mobile.dart'
    if (dart.library.html) 'excel_export_web.dart' as platform_export;

class ExcelImportResult {
  final List<RadioStation> stations;
  final String fileName;
  final Uint8List? originalBytes; // 원본 Excel 파일 bytes (서식 유지 export용)

  ExcelImportResult({
    required this.stations,
    required this.fileName,
    this.originalBytes,
  });
}

class ExcelService {
  /// Excel 파일을 선택하고 파싱하여 RadioStation 목록을 반환
  Future<ExcelImportResult?> importExcelFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return null;
      }

      final file = result.files.first;
      final fileName = file.name.replaceAll(RegExp(r'\.(xlsx|xls)$'), '');

      // withData: true 설정으로 모든 플랫폼에서 file.bytes 사용 가능
      var bytes = file.bytes;

      if (bytes == null) {
        throw Exception('파일을 읽을 수 없습니다.');
      }

      // 원본 bytes 복사 (서식 유지 export용)
      final originalBytes = Uint8List.fromList(bytes);

      // excel 패키지로 파싱 (numFmtId 오류 시 XML 직접 파싱으로 fallback)
      try {
        final stations = _parseWithExcelPackage(bytes, fileName);
        return ExcelImportResult(stations: stations, fileName: fileName, originalBytes: originalBytes);
      } catch (e) {
        debugPrint('excel 패키지 파싱 실패: $e');

        // numFmtId 오류인 경우 - 웹에서는 바로 XML 직접 파싱으로 진행 (UI 응답성 유지)
        if (e.toString().contains('numFmtId')) {
          debugPrint('numFmtId 오류 감지');

          // 웹 환경에서는 무거운 ZIP 재처리 과정을 건너뛰고 바로 XML 직접 파싱
          if (kIsWeb) {
            debugPrint('웹 환경 - XML 직접 파싱으로 바로 진행');
            try {
              final stations = await _parseXmlDirectly(bytes, fileName);
              debugPrint('XML 직접 파싱 성공: ${stations.length}개');
              return ExcelImportResult(stations: stations, fileName: fileName, originalBytes: originalBytes);
            } catch (e4) {
              debugPrint('XML 직접 파싱도 실패: $e4');
              throw Exception('Excel 파일 파싱 실패. 지원되지 않는 형식이거나 파일이 손상되었습니다.');
            }
          }

          // 모바일 환경에서는 기존 로직 유지 (isolate 사용 가능)
          debugPrint('모바일 환경 - styles.xml 전처리 시도');
          try {
            final fixedBytes = _fixNumFmtIdInExcel(bytes);
            debugPrint('전처리된 바이트 크기: ${fixedBytes.length}');
            final stations = _parseWithExcelPackage(fixedBytes, fileName);
            debugPrint('전처리 후 파싱 성공');
            return ExcelImportResult(stations: stations, fileName: fileName, originalBytes: originalBytes);
          } catch (e2, stackTrace) {
            debugPrint('전처리 후에도 파싱 실패: $e2');
            debugPrint('스택트레이스: $stackTrace');

            // 원본 파일로 다시 시도 (numFmt 무시)
            debugPrint('원본 파일로 재시도 중...');
            try {
              final stations = _parseWithExcelPackageIgnoreNumFmt(bytes, fileName);
              debugPrint('원본 파일 파싱 성공 (numFmt 무시)');
              return ExcelImportResult(stations: stations, fileName: fileName, originalBytes: originalBytes);
            } catch (e3) {
              debugPrint('원본 파일 파싱도 실패: $e3');

              // 최후의 수단: XML 직접 파싱 (비동기)
              debugPrint('XML 직접 파싱 시도 중...');
              try {
                final stations = await _parseXmlDirectly(bytes, fileName);
                debugPrint('XML 직접 파싱 성공: ${stations.length}개');
                return ExcelImportResult(stations: stations, fileName: fileName, originalBytes: originalBytes);
              } catch (e4) {
                debugPrint('XML 직접 파싱도 실패: $e4');
                throw Exception('Excel 파일 파싱 실패. 지원되지 않는 형식이거나 파일이 손상되었습니다.');
              }
            }
          }
        }

        throw Exception('Excel 파일 파싱 실패. 지원되지 않는 형식이거나 파일이 손상되었습니다.');
      }
    } catch (e) {
      debugPrint('Excel 파일 import 오류: $e');
      rethrow;
    }
  }

  /// Excel 파일 내 numFmtId 오류 수정 (한국 원화 등 특수 형식 처리)
  /// xlsx 파일은 ZIP 압축된 XML 파일들로 구성됨
  /// styles.xml에서 numFmtId < 164인 커스텀 포맷을 164 이상으로 변경
  Uint8List _fixNumFmtIdInExcel(Uint8List bytes) {
    try {
      // xlsx 파일을 ZIP으로 디코딩
      final archive = ZipDecoder().decodeBytes(bytes);
      final newArchive = Archive();

      debugPrint('ZIP 아카이브 파일 수: ${archive.length}');
      bool stylesFound = false;
      int copiedFiles = 0;
      int skippedFiles = 0;

      for (final file in archive) {
        if (file.isFile) {
          // 파일 내용이 null인 경우 스킵
          final fileContent = file.content;
          if (fileContent == null) {
            debugPrint('파일 내용이 null: ${file.name}');
            skippedFiles++;
            continue;
          }

          // styles.xml 파일 경로 확인 (대소문자 무시, 경로 변형 대응)
          final lowerName = file.name.toLowerCase();
          if (lowerName.contains('styles.xml')) {
            debugPrint('styles.xml 발견: ${file.name}');
            try {
              // styles.xml 수정
              final content = utf8.decode(fileContent as List<int>);
              final fixedContent = _fixStylesXmlNumFmtId(content);
              final fixedBytes = utf8.encode(fixedContent);
              final newFile = ArchiveFile(file.name, fixedBytes.length, fixedBytes);
              newFile.compress = true; // 압축 활성화
              newArchive.addFile(newFile);
              debugPrint('styles.xml numFmtId 수정 완료');
              stylesFound = true;
              copiedFiles++;
            } catch (e) {
              debugPrint('styles.xml 수정 실패: $e - 원본 사용');
              final newFile = ArchiveFile(file.name, fileContent.length, fileContent);
              newFile.compress = true;
              newArchive.addFile(newFile);
              copiedFiles++;
            }
          } else {
            // 다른 파일은 그대로 복사
            try {
              final newFile = ArchiveFile(file.name, fileContent.length, fileContent);
              newFile.compress = true; // 압축 활성화
              newArchive.addFile(newFile);
              copiedFiles++;
            } catch (e) {
              debugPrint('파일 복사 실패: ${file.name} - $e');
              skippedFiles++;
            }
          }
        }
      }

      debugPrint('ZIP 복사 완료: $copiedFiles개 복사, $skippedFiles개 스킵');

      if (!stylesFound) {
        debugPrint('styles.xml 파일을 찾지 못함 - 원본 반환');
        return bytes;
      }

      if (copiedFiles == 0) {
        debugPrint('복사된 파일이 없음 - 원본 반환');
        return bytes;
      }

      // 수정된 ZIP 파일로 재인코딩
      final fixedZipBytes = ZipEncoder().encode(newArchive);
      if (fixedZipBytes == null) {
        debugPrint('ZIP 재인코딩 실패 - 원본 반환');
        return bytes;
      }

      debugPrint('ZIP 재인코딩 완료: ${fixedZipBytes.length} 바이트');
      return Uint8List.fromList(fixedZipBytes);
    } catch (e) {
      debugPrint('numFmtId 수정 중 오류: $e - 원본 반환');
      return bytes; // 오류 시 원본 반환 (재시도 가능)
    }
  }

  /// styles.xml에서 numFmtId < 164인 커스텀 포맷을 제거하거나 수정
  String _fixStylesXmlNumFmtId(String xml) {
    // numFmt 태그에서 numFmtId가 164 미만인 것들을 찾아서 제거
    // 패턴: <numFmt numFmtId="42" formatCode="..."/>
    final numFmtPattern = RegExp(
      r'<numFmt\s+numFmtId="(\d+)"[^>]*/>',
      multiLine: true,
    );

    String fixedXml = xml.replaceAllMapped(numFmtPattern, (match) {
      final numFmtId = int.tryParse(match.group(1) ?? '0') ?? 0;
      if (numFmtId > 0 && numFmtId < 164) {
        debugPrint('numFmtId $numFmtId 제거됨');
        return ''; // 문제되는 numFmt 태그 제거
      }
      return match.group(0)!;
    });

    // cellXfs에서 numFmtId 참조도 수정 (0으로 변경)
    final xfPattern = RegExp(
      r'(<xf[^>]*\s+numFmtId=")(\d+)("[^>]*>)',
      multiLine: true,
    );

    fixedXml = fixedXml.replaceAllMapped(xfPattern, (match) {
      final numFmtId = int.tryParse(match.group(2) ?? '0') ?? 0;
      if (numFmtId > 0 && numFmtId < 164) {
        debugPrint('xf numFmtId $numFmtId -> 0 으로 변경');
        return '${match.group(1)}0${match.group(3)}';
      }
      return match.group(0)!;
    });

    return fixedXml;
  }

  /// 대상 시트 찾기 (우선순위: 검사신청내역 > 신청/내역 포함 > 첫 번째 시트)
  String _findTargetSheet(List<String> sheetNames) {
    // 1순위: 정확히 '검사신청내역' 시트
    if (sheetNames.contains('검사신청내역')) {
      return '검사신청내역';
    }

    // 2순위: '검사신청내역'과 유사한 이름 (공백, 대소문자 무시)
    for (final name in sheetNames) {
      final normalized = name.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      if (normalized == '검사신청내역') {
        return name;
      }
    }

    // 3순위: '검사'와 '신청' 또는 '내역'이 모두 포함된 시트
    for (final name in sheetNames) {
      if (name.contains('검사') && (name.contains('신청') || name.contains('내역'))) {
        return name;
      }
    }

    // 4순위: '신청' 또는 '내역'이 포함된 시트
    for (final name in sheetNames) {
      if (name.contains('신청') || name.contains('내역')) {
        return name;
      }
    }

    // 5순위: 첫 번째 시트
    return sheetNames.first;
  }

  /// excel 패키지를 사용한 파싱 (numFmt 오류 무시 버전)
  /// styles.xml을 완전히 제거하고 파싱 시도
  List<RadioStation> _parseWithExcelPackageIgnoreNumFmt(List<int> bytes, String categoryName) {
    try {
      // styles.xml을 완전히 제거한 버전으로 시도
      final archive = ZipDecoder().decodeBytes(bytes);
      final newArchive = Archive();

      for (final file in archive) {
        if (file.isFile) {
          final lowerName = file.name.toLowerCase();
          // styles.xml 제외하고 복사
          if (!lowerName.contains('styles.xml')) {
            final content = file.content;
            if (content != null) {
              final newFile = ArchiveFile(file.name, content.length, content);
              newFile.compress = true; // 압축 활성화
              newArchive.addFile(newFile);
            }
          }
        }
      }

      final modifiedBytes = ZipEncoder().encode(newArchive);
      if (modifiedBytes == null) {
        throw Exception('ZIP 인코딩 실패');
      }

      debugPrint('styles.xml 제거 후 파싱 시도: ${modifiedBytes.length} 바이트');
      return _parseWithExcelPackage(modifiedBytes, categoryName);
    } catch (e) {
      debugPrint('styles.xml 제거 파싱 실패: $e');
      rethrow;
    }
  }

  /// XML 직접 파싱 (excel 패키지 우회)
  /// xlsx 파일 내 XML 파일들을 직접 파싱하여 데이터 추출
  /// 비동기로 처리하여 웹에서 UI 응답성 유지
  Future<List<RadioStation>> _parseXmlDirectly(List<int> bytes, String categoryName) async {
    try {
      // ZIP 디코딩 후 UI 응답성을 위해 yield
      final archive = ZipDecoder().decodeBytes(bytes);
      await Future.delayed(Duration.zero); // UI 응답성 유지

      final List<RadioStation> stations = [];

      // sharedStrings.xml에서 공유 문자열 추출
      final sharedStrings = <String>[];
      for (final file in archive) {
        if (file.isFile && file.name.toLowerCase().contains('sharedstrings.xml')) {
          final content = file.content;
          if (content != null) {
            final xmlStr = utf8.decode(content as List<int>);
            await Future.delayed(Duration.zero); // UI 응답성 유지

            // <t> 태그 내용 추출
            final tPattern = RegExp(r'<t[^>]*>([^<]*)</t>', multiLine: true);
            for (final match in tPattern.allMatches(xmlStr)) {
              sharedStrings.add(match.group(1) ?? '');
            }
          }
          break;
        }
      }
      debugPrint('공유 문자열 수: ${sharedStrings.length}');
      await Future.delayed(Duration.zero); // UI 응답성 유지

      // workbook.xml에서 시트 이름과 ID 매핑 추출
      final sheetNameToId = <String, String>{};
      final sheetIdToRId = <String, String>{};
      for (final file in archive) {
        if (file.isFile && file.name.toLowerCase().contains('workbook.xml') && !file.name.toLowerCase().contains('.rels')) {
          final content = file.content;
          if (content != null) {
            final xmlStr = utf8.decode(content as List<int>);
            // <sheet name="시트명" sheetId="1" r:id="rId1"/> 패턴
            final sheetPattern = RegExp(r'<sheet[^>]*name="([^"]*)"[^>]*sheetId="(\d+)"[^>]*r:id="([^"]*)"', multiLine: true);
            for (final match in sheetPattern.allMatches(xmlStr)) {
              final name = match.group(1) ?? '';
              final sheetId = match.group(2) ?? '';
              final rId = match.group(3) ?? '';
              sheetNameToId[name] = sheetId;
              sheetIdToRId[sheetId] = rId;
              debugPrint('시트 발견: "$name" (sheetId=$sheetId, rId=$rId)');
            }
          }
          break;
        }
      }

      // workbook.xml.rels에서 rId와 실제 파일 경로 매핑
      final rIdToPath = <String, String>{};
      for (final file in archive) {
        if (file.isFile && file.name.toLowerCase().contains('workbook.xml.rels')) {
          final content = file.content;
          if (content != null) {
            final xmlStr = utf8.decode(content as List<int>);
            // <Relationship Id="rId1" Target="worksheets/sheet1.xml" .../>
            final relPattern = RegExp(r'<Relationship[^>]*Id="([^"]*)"[^>]*Target="([^"]*)"', multiLine: true);
            for (final match in relPattern.allMatches(xmlStr)) {
              final rId = match.group(1) ?? '';
              final target = match.group(2) ?? '';
              rIdToPath[rId] = target;
              debugPrint('관계: $rId -> $target');
            }
          }
          break;
        }
      }

      // 대상 시트 이름 결정 (검사신청내역 우선)
      final targetSheetName = _findTargetSheet(sheetNameToId.keys.toList());
      debugPrint('선택된 시트 이름: $targetSheetName');

      // 선택된 시트의 파일 경로 찾기
      String? targetSheetPath;
      if (sheetNameToId.containsKey(targetSheetName)) {
        final sheetId = sheetNameToId[targetSheetName]!;
        final rId = sheetIdToRId[sheetId];
        if (rId != null && rIdToPath.containsKey(rId)) {
          targetSheetPath = rIdToPath[rId]!;
          // 상대 경로를 절대 경로로 변환
          if (!targetSheetPath.startsWith('xl/')) {
            targetSheetPath = 'xl/$targetSheetPath';
          }
        }
      }
      debugPrint('대상 시트 파일 경로: $targetSheetPath');

      // 대상 시트 파일 찾기
      ArchiveFile? targetSheet;
      for (final file in archive) {
        if (file.isFile && file.name.toLowerCase().contains('worksheets/sheet')) {
          // 경로가 지정된 경우 해당 파일만 선택
          if (targetSheetPath != null) {
            if (file.name.toLowerCase().endsWith(targetSheetPath.toLowerCase().split('/').last)) {
              targetSheet = file;
              break;
            }
          } else {
            // 경로를 찾지 못한 경우 sheet1.xml 사용
            targetSheet = file;
            if (file.name.toLowerCase().contains('sheet1.xml')) {
              break;
            }
          }
        }
      }

      if (targetSheet == null || targetSheet.content == null) {
        throw Exception('워크시트를 찾을 수 없습니다.');
      }

      debugPrint('대상 시트 파일: ${targetSheet.name}');
      final sheetXml = utf8.decode(targetSheet.content as List<int>);
      await Future.delayed(Duration.zero); // UI 응답성 유지

      // 행 추출: <row> 태그
      final rowPattern = RegExp(r'<row[^>]*>(.*?)</row>', multiLine: true, dotAll: true);
      final rows = rowPattern.allMatches(sheetXml).toList();
      debugPrint('총 행 수: ${rows.length}');
      await Future.delayed(Duration.zero); // UI 응답성 유지

      if (rows.isEmpty) {
        throw Exception('데이터가 없습니다.');
      }

      // 첫 번째 행을 헤더로 사용
      final headerRow = rows.first;
      final headerRowContent = headerRow.group(1) ?? '';

      // 디버깅: 첫 번째 행 XML 구조 출력 (처음 500자만)
      debugPrint('===== XML 직접 파싱 디버그 =====');
      debugPrint('첫 번째 행 XML (처음 500자): ${headerRowContent.length > 500 ? headerRowContent.substring(0, 500) : headerRowContent}');

      final headerCells = _extractCellsFromRow(headerRowContent, sharedStrings, debug: true);
      debugPrint('헤더 셀 수: ${headerCells.length}');
      for (int i = 0; i < headerCells.length; i++) {
        debugPrint('헤더[$i]: "${headerCells[i]}"');
      }

      // 헤더 매핑
      final columnMap = <String, int>{};
      for (int i = 0; i < headerCells.length; i++) {
        final value = headerCells[i].toLowerCase();
        _mapColumnByValue(value, i, columnMap);
      }
      debugPrint('1행 컬럼 매핑: $columnMap');

      // 두 번째 행도 확인하여 병합셀 하위 헤더 처리 (이득, 기수 등)
      int dataStartRow = 1; // 기본값: 두 번째 행부터 데이터
      if (rows.length > 1) {
        final secondRow = rows[1];
        final secondRowContent = secondRow.group(1) ?? '';
        final secondRowCells = _extractCellsFromRow(secondRowContent, sharedStrings, debug: true);
        bool isSecondRowHeader = false;

        debugPrint('두 번째 행 헤더 확인 (셀 수: ${secondRowCells.length}):');
        for (int i = 0; i < secondRowCells.length; i++) {
          final value = secondRowCells[i].toLowerCase();
          if (value.isNotEmpty) {
            debugPrint('2행[$i]: "$value"');
            // 이득, 기수 등 서브헤더 키워드 확인
            if (value.contains('이득') || value.contains('기수') || value == 'db') {
              isSecondRowHeader = true;
            }
            // 1행에서 매핑되지 않은 컬럼만 2행에서 매핑
            _mapColumnByValue(value, i, columnMap);
          }
        }
        debugPrint('1+2행 컬럼 매핑: $columnMap');

        // 두 번째 행이 서브헤더이면 세 번째 행부터 데이터 시작
        if (isSecondRowHeader) {
          dataStartRow = 2;
          debugPrint('두 번째 행이 서브헤더로 감지됨 - 데이터 시작 행: 3행');
        }
      }

      debugPrint('설치대 컬럼 인덱스: ${columnMap['installationType']}');
      debugPrint('비고 컬럼 인덱스: ${columnMap['remarks']}');

      // 주소 컬럼이 없으면 자동 매핑
      if (!columnMap.containsKey('address')) {
        debugPrint('주소 컬럼을 찾지 못함 - 자동 매핑 시도');
        _autoMapColumns(headerCells.length, columnMap);
        debugPrint('자동 매핑 후: $columnMap');
      }

      // 비고 컬럼 검증 - 첫 몇 개 데이터 행을 미리 추출하여 검증
      if (columnMap.containsKey('remarks')) {
        final previewRows = <List<String>>[];
        final previewCount = rows.length < 12 ? rows.length : 12;
        for (int i = dataStartRow; i < previewCount && i < rows.length; i++) {
          final rowContent = rows[i].group(1) ?? '';
          final cells = _extractCellsFromRow(rowContent, sharedStrings);
          previewRows.add(cells);
        }
        _validateRemarksColumn(columnMap, previewRows);
        debugPrint('비고 컬럼 검증 완료: ${columnMap.containsKey('remarks') ? '매핑 유지' : '매핑 제거됨'}');
      }

      // 데이터 행 파싱 (청크 단위로 처리하여 UI 응답성 유지)
      const int chunkSize = 20; // 20개 행마다 이벤트 루프에 제어권 반환
      for (int i = dataStartRow; i < rows.length; i++) {
        final rowContent = rows[i].group(1) ?? '';
        // 첫 3개 데이터 행에 대해 상세 디버깅
        final isDebugRow = i - dataStartRow < 3;
        if (isDebugRow) {
          debugPrint('--- 행 ${i + 1} XML 파싱 중 ---');
        }
        final cells = _extractCellsFromRow(rowContent, sharedStrings, debug: isDebugRow);

        String getCellValue(String key) {
          final index = columnMap[key];
          if (index == null || index >= cells.length) return '';
          return cells[index];
        }

        final stationName = getCellValue('stationName');
        final address = getCellValue('address');
        final installationTypeVal = getCellValue('installationType');
        final remarksVal = getCellValue('remarks');

        // 상세 디버깅 (처음 5개 데이터 행만)
        if (i - dataStartRow < 5) {
          final rowNum = i + 1; // Excel 행 번호 (1-based)
          debugPrint('--- 데이터 행 $rowNum (index=$i) ---');
          debugPrint('  셀 수: ${cells.length}');
          // 모든 셀 값 출력
          for (int j = 0; j < cells.length; j++) {
            final cellVal = cells[j];
            if (cellVal.isNotEmpty) {
              debugPrint('  셀[$j]: "$cellVal"');
            }
          }
          debugPrint('  stationName(idx=${columnMap['stationName']}): "$stationName"');
          debugPrint('  address(idx=${columnMap['address']}): "$address"');
          debugPrint('  installationType(idx=${columnMap['installationType']}): "$installationTypeVal"');
          debugPrint('  remarks(idx=${columnMap['remarks']}): "$remarksVal"');
        }

        if (address.isEmpty && stationName.isEmpty) continue;

        final uniqueId = 'station_${categoryName.hashCode.abs()}_${i}_${DateTime.now().microsecondsSinceEpoch}_${i % 10000}';

        stations.add(RadioStation(
          id: uniqueId,
          stationName: stationName.isNotEmpty ? stationName : '무선국 $i',
          licenseNumber: getCellValue('licenseNumber').isNotEmpty ? getCellValue('licenseNumber') : '-',
          address: address.isNotEmpty ? address : stationName,
          callSign: getCellValue('callSign').isNotEmpty ? getCellValue('callSign') : null,
          gain: getCellValue('gain').isNotEmpty ? getCellValue('gain') : null,
          antennaCount: getCellValue('antennaCount').isNotEmpty ? getCellValue('antennaCount') : null,
          remarks: _validateRemarksValue(getCellValue('remarks')),
          typeApprovalNumber: getCellValue('typeApprovalNumber').isNotEmpty ? getCellValue('typeApprovalNumber') : null,
          installationType: installationTypeVal.isNotEmpty ? installationTypeVal : null,
          originalInstallationType: installationTypeVal.isNotEmpty ? installationTypeVal : null, // 원본 설치대 저장
          categoryName: categoryName,
        ));

        // 청크 단위로 이벤트 루프에 제어권 반환 (웹 UI 응답성 유지)
        if (i % chunkSize == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      debugPrint('===== XML 직접 파싱 완료 =====');
      debugPrint('총 파싱된 스테이션: ${stations.length}개');
      debugPrint('컬럼 매핑 최종: $columnMap');

      // 설치대와 비고 값이 있는 스테이션 수 출력
      int installationTypeCount = stations.where((s) => s.installationType?.isNotEmpty == true).length;
      int remarksCount = stations.where((s) => s.remarks?.isNotEmpty == true).length;
      debugPrint('설치대 값이 있는 스테이션: $installationTypeCount개');
      debugPrint('비고 값이 있는 스테이션: $remarksCount개');

      // 처음 3개 스테이션의 설치대/비고 값 출력
      for (int i = 0; i < stations.length && i < 3; i++) {
        final s = stations[i];
        debugPrint('스테이션[$i] ${s.stationName}: 설치대="${s.installationType ?? ""}", 비고="${s.remarks ?? ""}"');
      }

      return stations;
    } catch (e) {
      debugPrint('XML 직접 파싱 오류: $e');
      rethrow;
    }
  }

  /// XML 행에서 셀 값 추출
  /// 디버그 모드에서 상세 로그 출력
  List<String> _extractCellsFromRow(String rowXml, List<String> sharedStrings, {bool debug = false}) {
    final cells = <String>[];

    // 모든 셀 위치를 추적
    final cellMap = <int, String>{};
    int maxCol = 0;

    // 방법 1: <c ... >...</c> 형태 (내용이 있는 셀)
    // 공백이 있든 없든 매칭되도록 \s* 사용
    final cellWithContentPattern = RegExp(r'<c\s*([^>]*)>(.*?)</c>', multiLine: true, dotAll: true);

    // r 속성이 없는 셀을 위한 순차 인덱스 (일부 Excel 파일에서 r 속성 누락 가능)
    int sequentialColIndex = 0;

    for (final match in cellWithContentPattern.allMatches(rowXml)) {
      final attributes = match.group(1) ?? '';
      final content = match.group(2) ?? '';

      int colIndex;

      // r 속성에서 셀 위치 추출 (예: r="A1", r="AB123")
      final rMatch = RegExp(r'r="([A-Z]+)(\d+)"').firstMatch(attributes);
      if (rMatch != null) {
        final colLetter = rMatch.group(1) ?? 'A';

        // 열 문자를 인덱스로 변환 (A=0, B=1, ..., Z=25, AA=26, ...)
        colIndex = 0;
        for (int i = 0; i < colLetter.length; i++) {
          colIndex = colIndex * 26 + (colLetter.codeUnitAt(i) - 'A'.codeUnitAt(0) + 1);
        }
        colIndex--; // 0-based

        sequentialColIndex = colIndex + 1; // 다음 순차 인덱스 업데이트

        if (debug) {
          debugPrint('  셀 발견: r="$colLetter" → colIndex=$colIndex');
        }
      } else {
        // r 속성이 없는 경우 순차 인덱스 사용
        colIndex = sequentialColIndex;
        sequentialColIndex++;

        if (debug) {
          debugPrint('  셀 발견: r 속성 없음 → colIndex=$colIndex (순차)');
        }
      }

      // t 속성 추출 (셀 타입: s=shared string, n=number, b=boolean, inlineStr 등)
      final tMatch = RegExp(r't="([^"]*)"').firstMatch(attributes);
      final cellType = tMatch?.group(1);

      // <v> 태그에서 값 추출
      final vMatch = RegExp(r'<v>([^<]*)</v>').firstMatch(content);
      String cellValue = vMatch?.group(1) ?? '';

      // inlineStr 타입의 경우 <is><t>값</t></is> 형태
      if (cellType == 'inlineStr' || cellValue.isEmpty) {
        final isMatch = RegExp(r'<is>\s*<t[^>]*>([^<]*)</t>\s*</is>').firstMatch(content);
        if (isMatch != null) {
          cellValue = isMatch.group(1) ?? '';
        }
      }

      if (colIndex > maxCol) maxCol = colIndex;

      String value = '';
      if (cellType == 's' && cellValue.isNotEmpty) {
        // 공유 문자열 참조
        final idx = int.tryParse(cellValue);
        if (idx != null && idx < sharedStrings.length) {
          value = sharedStrings[idx];
        } else {
          debugPrint('SharedString 인덱스 오류: idx=$idx, 총 ${sharedStrings.length}개');
        }
      } else if (cellType == 'inlineStr') {
        // inline string은 이미 cellValue에 텍스트가 들어있음
        value = cellValue;
      } else if (cellValue.isNotEmpty) {
        value = cellValue;
      }

      cellMap[colIndex] = value;

      if (debug && value.isNotEmpty) {
        debugPrint('    → 값: "$value" (type=$cellType)');
      }
    }

    // 빈 셀도 포함하여 리스트 생성
    for (int i = 0; i <= maxCol; i++) {
      cells.add(cellMap[i] ?? '');
    }

    return cells;
  }

  /// excel 패키지를 사용한 파싱
  List<RadioStation> _parseWithExcelPackage(List<int> bytes, String categoryName) {
    final excel = excel_pkg.Excel.decodeBytes(bytes);
    final List<RadioStation> stations = [];

    if (excel.tables.isEmpty) {
      throw Exception('시트가 없습니다.');
    }

    // 시트 선택 우선순위: 검사신청내역 > 신청/내역 포함 > 첫 번째 시트
    final sheetName = _findTargetSheet(excel.tables.keys.toList());
    debugPrint('===== Excel Import 디버그 =====');
    debugPrint('선택된 시트: $sheetName (전체 시트: ${excel.tables.keys.toList()})');

    final sheet = excel.tables[sheetName];

    if (sheet == null || sheet.rows.isEmpty) {
      throw Exception('시트가 비어있습니다.');
    }

    debugPrint('총 행 수: ${sheet.rows.length}');

    final headerRow = sheet.rows.first;
    debugPrint('헤더 행 셀 수: ${headerRow.length}');

    // 헤더 내용 출력
    for (int i = 0; i < headerRow.length; i++) {
      final cell = headerRow[i];
      final value = _getCellStringValueExcel(cell);
      debugPrint('헤더[$i]: "$value"');
    }

    final columnMap = _mapColumnsExcel(headerRow);
    debugPrint('컬럼 매핑 결과 (1행): $columnMap');

    // 두 번째 행도 확인하여 병합셀 하위 헤더 처리 (이득, 기수 등)
    // 두 번째 행이 서브헤더인지 확인 (이득, 기수 등의 키워드 포함 여부)
    int dataStartRow = 1; // 기본값: 두 번째 행부터 데이터
    if (sheet.rows.length > 1) {
      final secondRow = sheet.rows[1];
      bool isSecondRowHeader = false;
      debugPrint('두 번째 행 헤더 확인:');
      for (int i = 0; i < secondRow.length; i++) {
        final cell = secondRow[i];
        final value = _getCellStringValueExcel(cell).toLowerCase();
        if (value.isNotEmpty) {
          debugPrint('2행[$i]: "$value"');
          // 이득, 기수 등 서브헤더 키워드 확인
          if (value.contains('이득') || value.contains('기수') || value.contains('db')) {
            isSecondRowHeader = true;
          }
          // 1행에서 매핑되지 않은 컬럼만 2행에서 매핑
          _mapColumnByValue(value, i, columnMap);
        }
      }
      debugPrint('컬럼 매핑 결과 (1+2행): $columnMap');

      // 두 번째 행이 서브헤더이면 세 번째 행부터 데이터 시작
      if (isSecondRowHeader) {
        dataStartRow = 2;
        debugPrint('두 번째 행이 서브헤더로 감지됨 - 데이터 시작 행: 3행');
      }
    }

    if (!columnMap.containsKey('address')) {
      debugPrint('주소 컬럼을 찾지 못함 - 자동 매핑 시도');
      _autoMapColumns(headerRow.length, columnMap);
      debugPrint('자동 매핑 후: $columnMap');
    }

    // 비고 컬럼 검증 - 첫 몇 개 데이터 행을 추출하여 검증
    if (columnMap.containsKey('remarks')) {
      final previewRows = <List<String>>[];
      final previewCount = sheet.rows.length < 12 ? sheet.rows.length : 12;
      for (int i = dataStartRow; i < previewCount && i < sheet.rows.length; i++) {
        final row = sheet.rows[i];
        final cells = row.map((cell) => _getCellStringValueExcel(cell)).toList();
        previewRows.add(cells);
      }
      _validateRemarksColumn(columnMap, previewRows);
      debugPrint('비고 컬럼 검증 완료: ${columnMap.containsKey('remarks') ? '매핑 유지' : '매핑 제거됨'}');
    }

    // 첫 번째 데이터 행 샘플 출력
    if (sheet.rows.length > dataStartRow) {
      final firstDataRow = sheet.rows[dataStartRow];
      debugPrint('첫 번째 데이터 행 (${dataStartRow + 1}행) 셀 수: ${firstDataRow.length}');
      for (int i = 0; i < firstDataRow.length; i++) {
        final cell = firstDataRow[i];
        final value = _getCellStringValueExcel(cell);
        debugPrint('데이터[$dataStartRow][$i]: "$value"');
      }
    }

    int parsedCount = 0;
    int skippedCount = 0;

    for (int i = dataStartRow; i < sheet.rows.length; i++) {
      final row = sheet.rows[i];
      final station = _parseRowExcel(row, columnMap, i, categoryName);
      if (station != null) {
        stations.add(station);
        parsedCount++;
      } else {
        skippedCount++;
      }
    }

    debugPrint('파싱 완료: 성공 $parsedCount개, 스킵 $skippedCount개');
    debugPrint('===== Excel Import 완료 =====');

    return stations;
  }

  /// excel 패키지용 헤더 매핑
  Map<String, int> _mapColumnsExcel(List<excel_pkg.Data?> headerRow) {
    final Map<String, int> columnMap = {};

    for (int i = 0; i < headerRow.length; i++) {
      final cell = headerRow[i];
      if (cell == null || cell.value == null) continue;

      final value = _getCellStringValueExcel(cell).toLowerCase();
      _mapColumnByValue(value, i, columnMap);
    }

    return columnMap;
  }

  /// 컬럼 값에 따라 매핑 (value는 이미 lowercase 처리됨)
  void _mapColumnByValue(String value, int index, Map<String, int> columnMap) {
    // ERP국소명/국소명/무선국명 등 (대소문자 무시)
    // 공백 제거한 버전도 확인
    final noSpaceValue = value.replaceAll(RegExp(r'\s+'), '');

    if (value.contains('erp국소명') || value.contains('erp 국소명') || noSpaceValue.contains('erp국소명')) {
      columnMap['stationName'] = index;
      debugPrint('국소명 컬럼 발견 (ERP): index=$index, value="$value"');
    } else if (value.contains('통합시설명칭') || noSpaceValue.contains('통합시설명칭')) {
      // 통합시설명칭 - 우선순위 높음
      columnMap['stationName'] = index;
      debugPrint('국소명 컬럼 발견 (통합시설명칭): index=$index, value="$value"');
    } else if (value.contains('국소명') || value.contains('국명') || value.contains('station') ||
               value.contains('무선국명') || value.contains('기지국명') || value.contains('발신국명') ||
               value == '명칭' || value == '국소' || value.contains('station name') ||
               value.contains('시설명칭') || value.contains('시설명') ||
               noSpaceValue.contains('국소명') || noSpaceValue.contains('무선국명')) {
      if (!columnMap.containsKey('stationName')) {
        columnMap['stationName'] = index;
        debugPrint('국소명 컬럼 발견: index=$index, value="$value"');
      }
    }
    // 호출명칭
    if (value.contains('호출명칭') || (value.contains('호출') && value.contains('명칭'))) {
      columnMap['callSign'] = index;
    }
    // 허가번호
    if (value.contains('허가번호') || value.contains('허가') || value.contains('license')) {
      columnMap['licenseNumber'] = index;
    }
    // 설치장소(주소) - 주소, 소재지 등 다양한 이름 지원
    if (value.contains('설치장소') || value.contains('주소') || value.contains('소재지') || value.contains('address') || value.contains('location')) {
      if (!columnMap.containsKey('address')) {
        columnMap['address'] = index;
      }
    }
    // 이득(dB)
    if (value.contains('이득') || value.contains('gain') || value == 'db') {
      if (!columnMap.containsKey('gain')) {
        columnMap['gain'] = index;
        debugPrint('이득 컬럼 발견: index=$index, value="$value"');
      }
    }
    // 기수
    if (value.contains('기수') || (value.contains('antenna') && value.contains('count'))) {
      if (!columnMap.containsKey('antennaCount')) {
        columnMap['antennaCount'] = index;
        debugPrint('기수 컬럼 발견: index=$index, value="$value"');
      }
    }
    // 비고 - 정확한 매칭만 (다른 컬럼과 혼동 방지)
    // 정확히 '비고'만 매칭하거나, 'remarks', 'note' 정확 매칭
    // '비고란'을 포함하는 경우는 제외 (다른 컬럼일 가능성)
    if (value == '비고' || value == 'remarks' || value == 'note' || value == '비고사항') {
      if (!columnMap.containsKey('remarks')) {
        columnMap['remarks'] = index;
        debugPrint('비고 컬럼 발견 (정확 매칭): index=$index, value="$value"');
      }
    }
    // 형식검정번호
    if (value.contains('형식검정번호') || value.contains('형식검정') || value.contains('검정번호')) {
      if (!columnMap.containsKey('typeApprovalNumber')) {
        columnMap['typeApprovalNumber'] = index;
        debugPrint('형식검정번호 컬럼 발견: index=$index, value="$value"');
      }
    }
    // 주파수
    if (value.contains('주파수') || value.contains('frequency') || value.contains('freq')) {
      if (!columnMap.containsKey('frequency')) {
        columnMap['frequency'] = index;
      }
    }
    // 설치대 (철탑형태) - 다양한 표현 지원 (다른 매칭보다 먼저 검사)
    final cleanValue = value.replaceAll(RegExp(r'\s+'), ''); // 공백 제거
    // '설치대', '철탑형태', '설치형태', 'installation', '철탑', '안테나형태', '지지물' 등
    // '설치구분', '지지물종류', '지지물구분' 등도 포함
    if (value.contains('설치대') || value.contains('철탑형태') || value.contains('설치형태') ||
        value.contains('installation') || cleanValue.contains('설치대') || cleanValue.contains('철탑형태') ||
        value.contains('지지물') || value.contains('안테나형태') ||
        (value.contains('철탑') && !value.contains('번호')) ||
        value == '설치' || cleanValue == '설치대' ||
        value.contains('설치구분') || value.contains('지지구분') ||
        value.contains('지지물종류') || value.contains('지지물구분') ||
        (value.contains('설치') && value.contains('종류')) ||
        (value.contains('설치') && value.contains('구분'))) {
      if (!columnMap.containsKey('installationType')) {
        columnMap['installationType'] = index;
        debugPrint('설치대 컬럼 발견: index=$index, value="$value"');
      }
    }
    // 종류 - 'type' 단독 매칭 제외 (설치대 관련 패턴 제외)
    final isInstallationType = value.contains('설치') || value.contains('지지물') || value.contains('철탑') || value.contains('안테나');
    if (!isInstallationType && (value.contains('종류') || value.contains('종별') || value.contains('구분') || value == 'type')) {
      if (!columnMap.containsKey('stationType')) {
        columnMap['stationType'] = index;
      }
    }
    // 소유자
    if (value.contains('소유자') || value.contains('owner') || value.contains('대표자') || value.contains('사업자')) {
      if (!columnMap.containsKey('owner')) {
        columnMap['owner'] = index;
      }
    }
    // 위도
    if (value.contains('위도') || value.contains('lat')) {
      if (!columnMap.containsKey('latitude')) {
        columnMap['latitude'] = index;
      }
    }
    // 경도
    if (value.contains('경도') || value.contains('lng') || value.contains('lon')) {
      if (!columnMap.containsKey('longitude')) {
        columnMap['longitude'] = index;
      }
    }
  }

  /// 비고 컬럼 검증 - 첫 몇 개 데이터 행의 값이 순수 숫자인지 확인
  /// 순수 숫자만 있으면 잘못된 매핑으로 판단하여 제거
  void _validateRemarksColumn(
    Map<String, int> columnMap,
    List<List<String>> dataRows,
  ) {
    if (!columnMap.containsKey('remarks')) return;

    final remarksIndex = columnMap['remarks']!;
    int numericCount = 0;
    int nonEmptyCount = 0;

    // 처음 10개 데이터 행 검사
    final checkCount = dataRows.length < 10 ? dataRows.length : 10;
    for (int i = 0; i < checkCount; i++) {
      final row = dataRows[i];
      if (remarksIndex >= row.length) continue;

      final value = row[remarksIndex].trim();
      if (value.isEmpty) continue;

      nonEmptyCount++;
      // 순수 숫자인지 확인 (정수, 소수)
      if (RegExp(r'^-?\d+\.?\d*$').hasMatch(value)) {
        numericCount++;
      }
    }

    // 비어있지 않은 값 중 80% 이상이 순수 숫자면 잘못된 매핑으로 판단
    if (nonEmptyCount > 0 && numericCount / nonEmptyCount >= 0.8) {
      debugPrint('비고 컬럼 검증 실패: index=$remarksIndex, 숫자비율=${numericCount}/${nonEmptyCount}');
      debugPrint('비고 컬럼이 숫자 컬럼으로 판단되어 매핑 제거');
      columnMap.remove('remarks');
    } else {
      debugPrint('비고 컬럼 검증 통과: index=$remarksIndex, 숫자비율=${numericCount}/${nonEmptyCount}');
    }
  }

  /// 자동 컬럼 매핑
  void _autoMapColumns(int columnCount, Map<String, int> columnMap) {
    if (columnCount >= 3) {
      if (!columnMap.containsKey('stationName')) columnMap['stationName'] = 0;
      if (!columnMap.containsKey('licenseNumber')) columnMap['licenseNumber'] = 1;
      if (!columnMap.containsKey('address')) columnMap['address'] = 2;
    } else if (columnCount > 0) {
      if (!columnMap.containsKey('address')) columnMap['address'] = 0;
    }
  }

  /// excel 패키지용 셀 값 추출
  String _getCellStringValueExcel(excel_pkg.Data? cell) {
    if (cell == null || cell.value == null) return '';

    try {
      final value = cell.value;

      if (value is excel_pkg.TextCellValue) {
        return value.value.toString().trim();
      } else if (value is excel_pkg.IntCellValue) {
        return value.value.toString().trim();
      } else if (value is excel_pkg.DoubleCellValue) {
        return value.value.toString().trim();
      } else if (value is excel_pkg.DateCellValue) {
        return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
      } else if (value is excel_pkg.TimeCellValue) {
        return '${value.hour}:${value.minute}:${value.second}';
      } else if (value is excel_pkg.DateTimeCellValue) {
        return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} ${value.hour}:${value.minute}';
      } else if (value is excel_pkg.BoolCellValue) {
        return value.value.toString();
      } else if (value is excel_pkg.FormulaCellValue) {
        return value.formula.toString().trim();
      } else {
        return value.toString().trim();
      }
    } catch (e) {
      debugPrint('셀 값 추출 오류: $e');
      return '';
    }
  }

  /// excel 패키지용 double 추출
  double? _getCellDoubleValueExcel(excel_pkg.Data? cell) {
    if (cell == null || cell.value == null) return null;

    try {
      final value = cell.value;

      if (value is excel_pkg.IntCellValue) {
        return value.value.toDouble();
      } else if (value is excel_pkg.DoubleCellValue) {
        return value.value;
      } else if (value is excel_pkg.TextCellValue) {
        final text = value.value.toString().trim();
        final numStr = text.replaceAll(RegExp(r'[^\d.-]'), '');
        return double.tryParse(numStr);
      } else {
        final text = value.toString().trim();
        final numStr = text.replaceAll(RegExp(r'[^\d.-]'), '');
        return double.tryParse(numStr);
      }
    } catch (e) {
      return null;
    }
  }

  /// excel 패키지용 행 파싱
  RadioStation? _parseRowExcel(List<excel_pkg.Data?> row, Map<String, int> columnMap, int rowIndex, String categoryName) {
    try {
      String getCellValue(String key) {
        final index = columnMap[key];
        if (index == null || index >= row.length) return '';
        return _getCellStringValueExcel(row[index]);
      }

      double? getCellDouble(String key) {
        final index = columnMap[key];
        if (index == null || index >= row.length) return null;
        return _getCellDoubleValueExcel(row[index]);
      }

      final stationName = getCellValue('stationName');
      final licenseNumber = getCellValue('licenseNumber');
      final address = getCellValue('address');
      final callSign = getCellValue('callSign');
      final gain = getCellValue('gain');
      final antennaCount = getCellValue('antennaCount');
      final remarks = getCellValue('remarks');
      final typeApprovalNumber = getCellValue('typeApprovalNumber');
      final installationType = getCellValue('installationType');

      // 디버깅 (처음 5개 행만)
      if (rowIndex < 7) {
        debugPrint('[$rowIndex] 비고(remarks) 매핑: index=${columnMap['remarks']}, value="$remarks"');
        debugPrint('[$rowIndex] installationType 매핑: index=${columnMap['installationType']}, value="$installationType"');
      }

      if (address.isEmpty && stationName.isEmpty) {
        return null;
      }

      final finalAddress = address.isNotEmpty ? address : stationName;

      // UUID 대신 고유 ID 생성: 카테고리명 + 행번호 + 타임스탬프(마이크로초) + 랜덤값
      final uniqueId = 'station_${categoryName.hashCode.abs()}_${rowIndex}_${DateTime.now().microsecondsSinceEpoch}_${DateTime.now().hashCode.abs() % 10000}';

      return RadioStation(
        id: uniqueId,
        stationName: stationName.isNotEmpty ? stationName : '무선국 $rowIndex',
        licenseNumber: licenseNumber.isNotEmpty ? licenseNumber : '-',
        address: finalAddress,
        latitude: getCellDouble('latitude'),
        longitude: getCellDouble('longitude'),
        frequency: getCellValue('frequency'),
        stationType: getCellValue('stationType'),
        owner: getCellValue('owner'),
        callSign: callSign.isNotEmpty ? callSign : null,
        gain: gain.isNotEmpty ? gain : null,
        antennaCount: antennaCount.isNotEmpty ? antennaCount : null,
        remarks: _validateRemarksValue(remarks),
        typeApprovalNumber: typeApprovalNumber.isNotEmpty ? typeApprovalNumber : null,
        installationType: installationType.isNotEmpty ? installationType : null,
        originalInstallationType: installationType.isNotEmpty ? installationType : null, // 원본 설치대 저장
        categoryName: categoryName,
      );
    } catch (e) {
      debugPrint('행 $rowIndex 파싱 오류: $e');
      return null;
    }
  }

  /// 비고 값이 유효한지 확인 (순수 숫자만 있는 경우 무효로 처리)
  /// Excel에서 빈 셀이 숫자로 잘못 파싱되는 경우를 방지
  String? _validateRemarksValue(String? value) {
    if (value == null || value.isEmpty) return null;

    // 순수 숫자인 경우 (정수 또는 소수)는 비고 값으로 부적절
    // 예: "556", "665", "123.45" 등
    if (RegExp(r'^-?\d+\.?\d*$').hasMatch(value.trim())) {
      debugPrint('비고 값 필터링: "$value" (순수 숫자는 비고로 부적절)');
      return null;
    }

    return value;
  }

  /// 국소명을 안전한 파일명으로 변환
  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*\s]'), '_');
  }

  /// 사진 경로에서 확장자 추출 (URL 형식에 따라 다르게 처리)
  String _extractPhotoExtension(String photoPath) {
    // 1. base64 data URL인 경우: data:image/png;base64,... 또는 data:image/jpeg;base64,...
    if (photoPath.startsWith('data:image/')) {
      // data:image/png;base64,... 에서 'png' 추출
      final mimeEnd = photoPath.indexOf(';');
      if (mimeEnd > 11) {
        final mimeType = photoPath.substring(11, mimeEnd); // 'png', 'jpeg', 'gif' 등
        // jpeg -> jpg 변환
        if (mimeType == 'jpeg') return 'jpg';
        return mimeType;
      }
      return 'jpg'; // 기본값
    }

    // 2. S3 URL인 경우: s3://private/photos/stationId/1234567890_photo.jpg
    if (photoPath.startsWith('s3://')) {
      final lastDot = photoPath.lastIndexOf('.');
      final lastSlash = photoPath.lastIndexOf('/');
      if (lastDot > lastSlash && lastDot < photoPath.length - 1) {
        final ext = photoPath.substring(lastDot + 1).toLowerCase();
        // 유효한 이미지 확장자인지 확인
        if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext)) {
          return ext == 'jpeg' ? 'jpg' : ext;
        }
      }
      return 'jpg'; // 기본값
    }

    // 3. HTTP/HTTPS URL인 경우
    if (photoPath.startsWith('http://') || photoPath.startsWith('https://')) {
      // 쿼리 스트링 제거
      var cleanPath = photoPath.split('?').first;
      final lastDot = cleanPath.lastIndexOf('.');
      if (lastDot > 0 && lastDot < cleanPath.length - 1) {
        final ext = cleanPath.substring(lastDot + 1).toLowerCase();
        // 유효한 이미지 확장자인지 확인
        if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext)) {
          return ext == 'jpeg' ? 'jpg' : ext;
        }
      }
      return 'jpg'; // 기본값
    }

    // 4. blob URL인 경우 (확장자 정보 없음)
    if (photoPath.startsWith('blob:')) {
      return 'jpg'; // 기본값
    }

    // 5. 일반 파일 경로인 경우
    final lastDot = photoPath.lastIndexOf('.');
    if (lastDot > 0 && lastDot < photoPath.length - 1) {
      final ext = photoPath.substring(lastDot + 1).toLowerCase();
      // 유효한 이미지 확장자인지 확인 (최대 4자)
      if (ext.length <= 4 && ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext)) {
        return ext == 'jpeg' ? 'jpg' : ext;
      }
    }

    // 기본값
    return 'jpg';
  }

  /// 무선국 목록을 Excel 파일로 내보내기 (사진 포함 ZIP)
  /// saveOnly: true면 저장만, false면 저장 후 반환 (공유용)
  Future<String?> exportToExcel(List<RadioStation> stations, String categoryName, {bool saveOnly = false}) async {
    try {
      final excel = excel_pkg.Excel.createExcel();

      // 시트명 설정 (최대 31자)
      final sheetName = categoryName.length > 31
          ? categoryName.substring(0, 31)
          : categoryName;

      // 새 시트 생성 후 기본 Sheet1 삭제
      final sheet = excel[sheetName];
      excel.delete('Sheet1');

      // 헤더 스타일
      final headerStyle = excel_pkg.CellStyle(
        bold: true,
        horizontalAlign: excel_pkg.HorizontalAlign.Center,
        backgroundColorHex: excel_pkg.ExcelColor.fromHexString('#4472C4'),
        fontColorHex: excel_pkg.ExcelColor.fromHexString('#FFFFFF'),
      );

      // 헤더 추가 (import 형식과 일치 + 추가 컬럼)
      final headers = [
        '호출명칭', 'ERP국소명', '설치장소(주소)', '허가번호',
        '이득(dB)', '기수', '형식검정번호', '비고', '설치대',
        '특이사항 메모', '검사상태'
      ];
      for (int col = 0; col < headers.length; col++) {
        final cell = sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 0));
        cell.value = excel_pkg.TextCellValue(headers[col]);
        cell.cellStyle = headerStyle;
      }

      // 사진 파일 정보 수집 (국소명별 폴더로 구성)
      final List<Map<String, dynamic>> photoInfoList = [];

      // 데이터 추가
      for (int i = 0; i < stations.length; i++) {
        final station = stations[i];
        final rowIndex = i + 1;

        // 호출명칭
        sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: rowIndex))
            .value = excel_pkg.TextCellValue(station.callSign ?? '');

        // ERP국소명
        sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: rowIndex))
            .value = excel_pkg.TextCellValue(station.stationName);

        // 설치장소(주소)
        sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: rowIndex))
            .value = excel_pkg.TextCellValue(station.address);

        // 허가번호
        sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: rowIndex))
            .value = excel_pkg.TextCellValue(station.licenseNumber);

        // 이득(dB)
        sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: rowIndex))
            .value = excel_pkg.TextCellValue(station.gain ?? '');

        // 기수
        sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: rowIndex))
            .value = excel_pkg.TextCellValue(station.antennaCount ?? '');

        // 형식검정번호
        sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: rowIndex))
            .value = excel_pkg.TextCellValue(station.typeApprovalNumber ?? '');

        // 비고
        sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: rowIndex))
            .value = excel_pkg.TextCellValue(station.remarks ?? '');

        // 설치대
        sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: 8, rowIndex: rowIndex))
            .value = excel_pkg.TextCellValue(station.installationType ?? '');

        // 특이사항 메모
        sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: 9, rowIndex: rowIndex))
            .value = excel_pkg.TextCellValue(station.memo ?? '');

        // 검사상태
        final inspectionStatus = station.isInspected ? '검사완료' : '검사대기';
        sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: 10, rowIndex: rowIndex))
            .value = excel_pkg.TextCellValue(inspectionStatus);

        // 사진 파일 정보 수집 (국소명 폴더/파일명 구조)
        if (station.photoPaths != null && station.photoPaths!.isNotEmpty) {
          final sanitizedStationName = _sanitizeFileName(station.stationName);

          for (int j = 0; j < station.photoPaths!.length; j++) {
            final photoPath = station.photoPaths![j];
            // 확장자 추출 (URL 형식에 따라 다르게 처리)
            final extension = _extractPhotoExtension(photoPath);
            // 파일명: 사진1.jpg, 사진2.jpg 형식
            final photoFileName = station.photoPaths!.length == 1
                ? '사진.$extension'
                : '사진${j + 1}.$extension';

            // 사진 정보 저장 (ZIP 생성용) - 국소명 폴더 포함
            photoInfoList.add({
              'originalPath': photoPath,
              'folderName': sanitizedStationName,
              'fileName': photoFileName,
            });
          }
        }
      }

      // 컬럼 너비 설정
      sheet.setColumnWidth(0, 15);   // 호출명칭
      sheet.setColumnWidth(1, 25);   // ERP국소명
      sheet.setColumnWidth(2, 40);   // 설치장소(주소)
      sheet.setColumnWidth(3, 15);   // 허가번호
      sheet.setColumnWidth(4, 10);   // 이득(dB)
      sheet.setColumnWidth(5, 8);    // 기수
      sheet.setColumnWidth(6, 20);   // 형식검정번호
      sheet.setColumnWidth(7, 20);   // 비고
      sheet.setColumnWidth(8, 15);   // 설치대
      sheet.setColumnWidth(9, 30);   // 특이사항 메모
      sheet.setColumnWidth(10, 12);  // 검사상태

      // 파일 저장
      final bytes = excel.encode();
      if (bytes == null) {
        throw Exception('Excel 파일 생성 실패');
      }

      // 파일명: 리스트명_수검완료.xlsx
      final sanitizedName = categoryName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

      // 사진이 있으면 ZIP 파일로 내보내기, 없으면 Excel만 내보내기
      if (photoInfoList.isNotEmpty) {
        // ZIP 파일 생성 (Excel + 사진) - 웹/모바일 모두 지원
        final zipFileName = '${sanitizedName}_수검완료.zip';
        final filePath = await platform_export.saveExcelWithPhotosAsZip(
          Uint8List.fromList(bytes),
          '${sanitizedName}_수검완료.xlsx',
          photoInfoList,
          zipFileName,
          saveOnly: saveOnly,
        );
        debugPrint('ZIP 파일 저장 완료: $filePath');
        return filePath;
      } else {
        // Excel만 저장
        final fileName = '${sanitizedName}_수검완료.xlsx';
        final filePath = await platform_export.saveExcelFile(
          Uint8List.fromList(bytes),
          fileName,
          saveOnly: saveOnly,
        );
        debugPrint('Excel 파일 저장 완료: $filePath');
        return filePath;
      }
    } catch (e) {
      debugPrint('Excel 내보내기 오류: $e');
      rethrow;
    }
  }

  /// Excel 파일 공유
  Future<void> shareExcelFile(String filePath) async {
    try {
      await platform_export.shareExcelFile(filePath);
    } catch (e) {
      debugPrint('파일 공유 오류: $e');
      rethrow;
    }
  }

  /// 원본 Excel 서식을 유지하면서 수검여부/특이사항 컬럼만 추가하여 내보내기
  /// [originalBytes] - 원본 Excel 파일 바이트
  /// [stations] - 현재 스테이션 데이터 (수검여부, 메모 등 업데이트된 정보 포함)
  /// [categoryName] - 카테고리명 (파일명용)
  /// [saveOnly] - true면 저장만, false면 공유 다이얼로그도 표시
  Future<String?> exportWithOriginalFormat(
    Uint8List originalBytes,
    List<RadioStation> stations,
    String categoryName, {
    bool saveOnly = false,
  }) async {
    try {
      debugPrint('===== 원본 서식 유지 Export 시작 =====');
      debugPrint('원본 파일 크기: ${originalBytes.length} bytes');
      debugPrint('스테이션 수: ${stations.length}');

      // 스테이션 데이터를 여러 기준으로 매핑 (신뢰할 수 있는 매칭)
      // 우선순위: 허가번호 > 국소명+호출명칭 > 국소명+주소
      final stationByLicense = <String, RadioStation>{};
      final stationByNameAndCallSign = <String, RadioStation>{};
      final stationByNameAndAddress = <String, RadioStation>{};
      for (final station in stations) {
        // 1. 허가번호로 매핑 (가장 고유함)
        final license = station.licenseNumber.trim();
        if (license.isNotEmpty) {
          stationByLicense[license] = station;
        }
        // 2. 국소명+호출명칭으로 매핑 (같은 국소명이어도 호출명칭이 다르면 구분)
        final callSign = station.callSign?.trim() ?? '';
        final nameAndCallSign = '${station.stationName.trim()}|$callSign';
        stationByNameAndCallSign[nameAndCallSign] = station;
        // 3. 국소명+주소로 매핑 (fallback)
        final nameAndAddr = '${station.stationName.trim()}|${station.address.trim()}';
        stationByNameAndAddress[nameAndAddr] = station;
      }
      debugPrint('스테이션 매핑 - 허가번호: ${stationByLicense.length}, 국소명+호출명칭: ${stationByNameAndCallSign.length}, 국소명+주소: ${stationByNameAndAddress.length}');

      // xlsx ZIP 아카이브 열기
      final archive = ZipDecoder().decodeBytes(originalBytes);
      final newArchive = Archive();

      // 공유 문자열 목록 추출 및 새 문자열 추가 준비
      List<String> sharedStrings = [];
      String? sharedStringsXml;
      ArchiveFile? sharedStringsFile;

      for (final file in archive) {
        if (file.isFile && file.name.toLowerCase().contains('sharedstrings.xml')) {
          sharedStringsFile = file;
          final content = file.content;
          if (content != null) {
            sharedStringsXml = utf8.decode(content as List<int>);
            // 기존 공유 문자열 추출
            final tPattern = RegExp(r'<t[^>]*>([^<]*)</t>', multiLine: true);
            for (final match in tPattern.allMatches(sharedStringsXml!)) {
              sharedStrings.add(match.group(1) ?? '');
            }
          }
          break;
        }
      }
      debugPrint('기존 공유 문자열 수: ${sharedStrings.length}');

      // 새로 추가할 문자열들
      final newStrings = <String>[];
      final stringToIndex = <String, int>{};

      // 기존 문자열 인덱스 매핑
      for (int i = 0; i < sharedStrings.length; i++) {
        stringToIndex[sharedStrings[i]] = i;
      }

      // 새 문자열 인덱스 얻기 (기존에 있으면 기존 인덱스, 없으면 새로 추가)
      int getOrAddStringIndex(String text) {
        if (stringToIndex.containsKey(text)) {
          return stringToIndex[text]!;
        }
        final newIndex = sharedStrings.length + newStrings.length;
        stringToIndex[text] = newIndex;
        newStrings.add(text);
        return newIndex;
      }

      // 헤더 문자열 인덱스 미리 확보
      final headerInstallationIdx = getOrAddStringIndex('설치대(수정후)');
      final headerInspectionIdx = getOrAddStringIndex('수검여부');
      final headerMemoIdx = getOrAddStringIndex('특이사항');
      debugPrint('헤더 인덱스 - 설치대(수정후): $headerInstallationIdx, 수검여부: $headerInspectionIdx, 특이사항: $headerMemoIdx');

      // 워크시트 파일 찾기 및 수정
      ArchiveFile? worksheetFile;
      String? worksheetXml;
      String? worksheetPath;

      // workbook.xml에서 시트 이름과 rId 매핑 추출
      final sheetNameToRId = <String, String>{};
      String? targetSheetName;

      for (final file in archive) {
        if (file.isFile && file.name.toLowerCase().contains('workbook.xml') &&
            !file.name.toLowerCase().contains('.rels')) {
          final content = file.content;
          if (content != null) {
            final xmlStr = utf8.decode(content as List<int>);
            final sheetNames = <String>[];
            // <sheet name="시트명" sheetId="1" r:id="rId1"/> 패턴
            final sheetPattern = RegExp(r'<sheet[^>]*name="([^"]*)"[^>]*r:id="([^"]*)"', multiLine: true);
            for (final match in sheetPattern.allMatches(xmlStr)) {
              final name = match.group(1) ?? '';
              final rId = match.group(2) ?? '';
              sheetNames.add(name);
              sheetNameToRId[name] = rId;
              debugPrint('시트 발견: "$name" (rId=$rId)');
            }
            targetSheetName = _findTargetSheet(sheetNames);
            debugPrint('대상 시트: $targetSheetName');
          }
          break;
        }
      }

      // workbook.xml.rels에서 rId와 실제 파일 경로 매핑
      final rIdToPath = <String, String>{};
      for (final file in archive) {
        if (file.isFile && file.name.toLowerCase().contains('workbook.xml.rels')) {
          final content = file.content;
          if (content != null) {
            final xmlStr = utf8.decode(content as List<int>);
            // <Relationship Id="rId1" Target="worksheets/sheet1.xml" .../>
            final relPattern = RegExp(r'<Relationship[^>]*Id="([^"]*)"[^>]*Target="([^"]*)"', multiLine: true);
            for (final match in relPattern.allMatches(xmlStr)) {
              final rId = match.group(1) ?? '';
              final target = match.group(2) ?? '';
              rIdToPath[rId] = target;
              debugPrint('관계: $rId -> $target');
            }
          }
          break;
        }
      }

      // 대상 시트의 파일 경로 찾기
      String? targetSheetPath;
      if (targetSheetName != null && sheetNameToRId.containsKey(targetSheetName)) {
        final rId = sheetNameToRId[targetSheetName];
        if (rId != null && rIdToPath.containsKey(rId)) {
          targetSheetPath = rIdToPath[rId];
          // 상대 경로를 절대 경로로 변환
          if (targetSheetPath != null && !targetSheetPath.startsWith('xl/')) {
            targetSheetPath = 'xl/$targetSheetPath';
          }
          debugPrint('대상 시트 파일 경로: $targetSheetPath');
        }
      }

      // 대상 워크시트 파일 찾기
      for (final file in archive) {
        if (file.isFile && file.name.toLowerCase().contains('worksheets/sheet')) {
          // 대상 경로가 지정된 경우 해당 파일 선택
          if (targetSheetPath != null) {
            if (file.name.toLowerCase().endsWith(targetSheetPath.toLowerCase().split('/').last)) {
              worksheetFile = file;
              worksheetPath = file.name;
              debugPrint('대상 시트 파일 선택됨: ${file.name}');
              break;
            }
          } else {
            // 대상 경로를 찾지 못한 경우 sheet1.xml 사용 (fallback)
            if (worksheetFile == null || file.name.toLowerCase().contains('sheet1.xml')) {
              worksheetFile = file;
              worksheetPath = file.name;
            }
          }
        }
      }

      if (worksheetFile == null || worksheetFile.content == null) {
        throw Exception('워크시트를 찾을 수 없습니다.');
      }

      worksheetXml = utf8.decode(worksheetFile.content as List<int>);
      debugPrint('선택된 워크시트 파일: $worksheetPath');

      // 마지막 컬럼 문자 찾기 (dimension 태그에서)
      String lastColLetter = 'A';
      final dimPattern = RegExp(r'<dimension\s+ref="([A-Z]+)\d+:([A-Z]+)\d+"', multiLine: true);
      final dimMatch = dimPattern.firstMatch(worksheetXml!);
      if (dimMatch != null) {
        lastColLetter = dimMatch.group(2) ?? 'A';
        debugPrint('기존 마지막 컬럼: $lastColLetter');
      }

      // 새 컬럼 문자 계산 (예: Z -> AA -> AB)
      String incrementColumn(String col) {
        final chars = col.split('').reversed.toList();
        bool carry = true;
        for (int i = 0; i < chars.length && carry; i++) {
          if (chars[i] == 'Z') {
            chars[i] = 'A';
          } else {
            chars[i] = String.fromCharCode(chars[i].codeUnitAt(0) + 1);
            carry = false;
          }
        }
        if (carry) chars.add('A');
        return chars.reversed.join();
      }

      final col1Letter = incrementColumn(lastColLetter); // 설치대(수정후) 컬럼
      final col2Letter = incrementColumn(col1Letter);    // 수검여부 컬럼
      final col3Letter = incrementColumn(col2Letter);    // 특이사항 컬럼
      debugPrint('새 컬럼 문자: $col1Letter (설치대수정후), $col2Letter (수검여부), $col3Letter (특이사항)');

      // 사진 파일 정보 수집 (ZIP 생성용)
      final List<Map<String, dynamic>> photoInfoList = [];

      // dimension 업데이트
      if (dimMatch != null) {
        final oldDim = dimMatch.group(0)!;
        final newDim = oldDim.replaceAll(
          RegExp(r':([A-Z]+)(\d+)"'),
          ':$col3Letter\$2"',
        );
        worksheetXml = worksheetXml!.replaceFirst(oldDim, newDim);
        debugPrint('Dimension 업데이트: $oldDim -> $newDim');
      }

      // 컬럼 문자를 숫자로 변환하는 함수 (A=1, B=2, ..., Z=26, AA=27)
      int columnLetterToNumber(String col) {
        int result = 0;
        for (int i = 0; i < col.length; i++) {
          result = result * 26 + (col.codeUnitAt(i) - 'A'.codeUnitAt(0) + 1);
        }
        return result;
      }

      // 마지막 컬럼의 병합 상태 추출 및 새 컬럼에 적용
      // 예: <mergeCell ref="Z1:Z2"/> 형태로 1행~2행이 병합된 경우
      final mergeCellsPattern = RegExp(r'<mergeCells[^>]*>(.*?)</mergeCells>', multiLine: true, dotAll: true);
      final mergeCellsMatch = mergeCellsPattern.firstMatch(worksheetXml!);

      if (mergeCellsMatch != null) {
        String mergeCellsContent = mergeCellsMatch.group(1) ?? '';

        // 마지막 컬럼의 병합 정보 찾기
        final lastColMergePattern = RegExp(
          r'<mergeCell\s+ref="' + lastColLetter + r'(\d+):' + lastColLetter + r'(\d+)"',
          multiLine: true,
        );

        final newMergeCells = <String>[];
        for (final mergeMatch in lastColMergePattern.allMatches(mergeCellsContent)) {
          final startRow = mergeMatch.group(1);
          final endRow = mergeMatch.group(2);
          if (startRow != null && endRow != null) {
            // 새 컬럼들에도 동일한 병합 적용
            newMergeCells.add('<mergeCell ref="$col1Letter$startRow:$col1Letter$endRow"/>');
            newMergeCells.add('<mergeCell ref="$col2Letter$startRow:$col2Letter$endRow"/>');
            newMergeCells.add('<mergeCell ref="$col3Letter$startRow:$col3Letter$endRow"/>');
            debugPrint('병합 셀 복제: ${lastColLetter}$startRow:${lastColLetter}$endRow -> 새 컬럼들');
          }
        }

        // 새 병합 정보 추가
        if (newMergeCells.isNotEmpty) {
          final oldMergeCells = mergeCellsMatch.group(0)!;
          // count 속성 업데이트
          final countPattern = RegExp(r'count="(\d+)"');
          final countMatch = countPattern.firstMatch(oldMergeCells);
          if (countMatch != null) {
            final oldCount = int.parse(countMatch.group(1)!);
            final newCount = oldCount + newMergeCells.length;
            var newMergeCellsXml = oldMergeCells.replaceFirst(
              'count="$oldCount"',
              'count="$newCount"',
            );
            // </mergeCells> 앞에 새 병합 셀 추가
            newMergeCellsXml = newMergeCellsXml.replaceFirst(
              '</mergeCells>',
              '${newMergeCells.join('')}</mergeCells>',
            );
            worksheetXml = worksheetXml!.replaceFirst(oldMergeCells, newMergeCellsXml);
            debugPrint('병합 셀 추가 완료: ${newMergeCells.length}개');
          }
        }
      }

      // 컬럼 너비 설정을 위한 최대 문자열 추적
      String maxCol1Text = '설치대(수정후)';
      String maxCol2Text = '수검여부';
      String maxCol3Text = '특이사항';

      // 스테이션 데이터에서 최대 너비 텍스트 찾기 및 사진 정보 수집
      for (final station in stations) {
        // 설치대(수정후) - 원본 또는 수정된 값 중 출력될 값 기준
        final currentInstallation = station.installationType ?? '';
        final originalInstallation = station.originalInstallationType ?? '';
        final isChanged = currentInstallation.isNotEmpty &&
                          originalInstallation.isNotEmpty &&
                          currentInstallation != originalInstallation;
        final displayInstallation = isChanged ? currentInstallation : originalInstallation;
        if (displayInstallation.length > maxCol1Text.length) {
          maxCol1Text = displayInstallation;
        }
        // 수검여부 - 고정값이므로 스킵
        // 특이사항
        final memo = station.memo ?? '';
        if (memo.length > maxCol3Text.length) {
          maxCol3Text = memo;
        }
        // 사진 정보 수집 (ZIP 생성용)
        if (station.photoPaths != null && station.photoPaths!.isNotEmpty) {
          final sanitizedStationName = _sanitizeFileName(station.stationName);

          for (int j = 0; j < station.photoPaths!.length; j++) {
            final photoPath = station.photoPaths![j];
            final extension = _extractPhotoExtension(photoPath);
            final photoFileName = station.photoPaths!.length == 1
                ? '사진.$extension'
                : '사진${j + 1}.$extension';

            // 사진 정보 저장 (ZIP 생성용)
            photoInfoList.add({
              'originalPath': photoPath,
              'folderName': sanitizedStationName,
              'fileName': photoFileName,
            });
          }
        }
      }

      // 너비를 Excel 단위로 변환 (Excel 자동맞춤과 유사하게)
      // Excel 너비 단위: 기본 폰트(Calibri 11pt)에서 '0' 문자 너비 기준
      double calcWidth(String text) {
        if (text.isEmpty) return 8.43; // Excel 기본 너비

        double totalWidth = 0;
        for (final char in text.runes) {
          if (char >= 0xAC00 && char <= 0xD7A3) {
            // 한글: 약 2 단위
            totalWidth += 2.0;
          } else if (char >= 0x3000 && char <= 0x9FFF) {
            // 기타 CJK 문자: 약 2 단위
            totalWidth += 2.0;
          } else {
            // ASCII 및 기타: 약 1 단위
            totalWidth += 1.0;
          }
        }
        // 셀 패딩 (좌우 여백) 추가
        totalWidth += 2.0;
        return totalWidth.clamp(8.43, 100.0);
      }

      final col1Width = calcWidth(maxCol1Text);
      final col2Width = calcWidth(maxCol2Text);
      final col3Width = calcWidth(maxCol3Text);
      debugPrint('새 컬럼 너비: $col1Letter=$col1Width, $col2Letter=$col2Width, $col3Letter=$col3Width');

      // 컬럼 너비 정의 추가 (<cols> 섹션)
      final col1Num = columnLetterToNumber(col1Letter);
      final col2Num = columnLetterToNumber(col2Letter);
      final col3Num = columnLetterToNumber(col3Letter);

      final newColDefs =
        '<col min="$col1Num" max="$col1Num" width="$col1Width" customWidth="1"/>'
        '<col min="$col2Num" max="$col2Num" width="$col2Width" customWidth="1"/>'
        '<col min="$col3Num" max="$col3Num" width="$col3Width" customWidth="1"/>';

      // <cols> 섹션이 있으면 끝에 추가, 없으면 <sheetData> 앞에 새로 생성
      final colsPattern = RegExp(r'(<cols[^>]*>)(.*?)(</cols>)', multiLine: true, dotAll: true);
      final colsMatch = colsPattern.firstMatch(worksheetXml!);

      if (colsMatch != null) {
        // 기존 <cols> 섹션에 추가
        final oldCols = colsMatch.group(0)!;
        final newCols = oldCols.replaceFirst('</cols>', '$newColDefs</cols>');
        worksheetXml = worksheetXml!.replaceFirst(oldCols, newCols);
        debugPrint('기존 <cols> 섹션에 컬럼 너비 추가');
      } else {
        // <cols> 섹션이 없으면 <sheetData> 앞에 생성
        final sheetDataPattern = RegExp(r'<sheetData');
        worksheetXml = worksheetXml!.replaceFirst(
          sheetDataPattern,
          '<cols>$newColDefs</cols><sheetData',
        );
        debugPrint('<cols> 섹션 새로 생성');
      }

      // 각 행에 새 셀 추가
      final rowPattern = RegExp(r'(<row[^>]*r="(\d+)"[^>]*>)(.*?)(</row>)', multiLine: true, dotAll: true);

      // 헤더 행 수 결정 - 1행~2행에 걸친 병합 셀이 있으면 2행도 헤더
      int headerRowNum = 1;
      if (mergeCellsMatch != null) {
        final mergeCellsContent = mergeCellsMatch.group(1) ?? '';
        // 1행부터 2행까지 병합된 셀이 있는지 확인 (예: A1:A2, B1:B2 등)
        final headerMergePattern = RegExp(r'<mergeCell\s+ref="[A-Z]+1:[A-Z]+2"', multiLine: true);
        if (headerMergePattern.hasMatch(mergeCellsContent)) {
          headerRowNum = 2;
          debugPrint('헤더가 2행까지 병합됨 - headerRowNum=2');
        }
      }
      debugPrint('헤더 행 수: $headerRowNum');

      // 매칭 통계
      int totalDataRows = 0;
      int matchedRows = 0;
      int unmatchedRows = 0;
      int skippedEmptyRows = 0;

      // 셀 값 추출 헬퍼 함수 (컬럼 문자와 행번호로 셀 값 추출)
      String extractCellValue(String rowContent, String colLetter, int rowNum) {
        // <c r="A1" t="s"><v>0</v></c> 또는 <c r="A1"><v>123</v></c> 형태
        final cellPattern = RegExp(
          r'<c[^>]*r="' + colLetter + rowNum.toString() + r'"([^>]*)>.*?<v>([^<]*)</v>',
          multiLine: true,
          dotAll: true,
        );
        final match = cellPattern.firstMatch(rowContent);
        if (match == null) return '';

        final attrs = match.group(1) ?? '';
        final value = match.group(2) ?? '';

        // t="s"이면 sharedStrings에서 가져옴
        if (attrs.contains('t="s"')) {
          final idx = int.tryParse(value);
          if (idx != null && idx < sharedStrings.length) {
            return sharedStrings[idx];
          }
        }
        return value;
      }

      // 헤더 행에서 매칭용 컬럼 찾기
      String? stationNameCol;
      String? addressCol;
      String? licenseCol;
      String? callSignCol;

      // 1행의 모든 셀을 파싱하여 컬럼 매핑
      final headerRowMatch = rowPattern.firstMatch(worksheetXml!);
      if (headerRowMatch != null) {
        final headerContent = headerRowMatch.group(3) ?? '';
        // 모든 셀 추출
        final cellPattern = RegExp(r'<c[^>]*r="([A-Z]+)1"([^>]*)>.*?<v>([^<]*)</v>', multiLine: true, dotAll: true);
        for (final cellMatch in cellPattern.allMatches(headerContent)) {
          final col = cellMatch.group(1) ?? '';
          final attrs = cellMatch.group(2) ?? '';
          final value = cellMatch.group(3) ?? '';

          String headerText = value;
          if (attrs.contains('t="s"')) {
            final idx = int.tryParse(value);
            if (idx != null && idx < sharedStrings.length) {
              headerText = sharedStrings[idx];
            }
          }

          final lowerText = headerText.toLowerCase();
          // 국소명 컬럼 찾기
          if (stationNameCol == null &&
              (lowerText.contains('국소명') || lowerText.contains('erp국소명') ||
               lowerText.contains('무선국명') || lowerText.contains('시설명칭') ||
               lowerText.contains('통합시설명칭'))) {
            stationNameCol = col;
            debugPrint('국소명 컬럼 발견: $col (헤더: $headerText)');
          }
          // 주소 컬럼 찾기
          if (addressCol == null &&
              (lowerText.contains('설치장소') || lowerText.contains('주소') ||
               lowerText.contains('소재지') || lowerText.contains('address'))) {
            addressCol = col;
            debugPrint('주소 컬럼 발견: $col (헤더: $headerText)');
          }
          // 허가번호 컬럼 찾기
          if (licenseCol == null &&
              (lowerText.contains('허가번호') || lowerText.contains('허가') ||
               lowerText.contains('license'))) {
            licenseCol = col;
            debugPrint('허가번호 컬럼 발견: $col (헤더: $headerText)');
          }
          // 호출명칭 컬럼 찾기
          if (callSignCol == null &&
              (lowerText.contains('호출명칭') || lowerText.contains('호출부호') ||
               lowerText.contains('callsign') || lowerText.contains('call sign'))) {
            callSignCol = col;
            debugPrint('호출명칭 컬럼 발견: $col (헤더: $headerText)');
          }
        }
      }
      debugPrint('매칭용 컬럼 - 국소명: $stationNameCol, 주소: $addressCol, 허가번호: $licenseCol, 호출명칭: $callSignCol');

      // 마지막 컬럼 셀의 스타일 추출 함수
      String? extractLastColumnStyle(String rowContent, String lastCol) {
        // 마지막 컬럼 셀에서 s 속성 추출
        // 예: <c r="Z1" s="5" t="s"><v>0</v></c> 에서 s="5" 추출
        final lastColCellPattern = RegExp(
          r'<c[^>]*r="' + lastCol + r'\d+"([^>]*)>',
          multiLine: true,
        );
        final match = lastColCellPattern.firstMatch(rowContent);
        if (match != null) {
          final attrs = match.group(1) ?? '';
          final styleMatch = RegExp(r's="(\d+)"').firstMatch(attrs);
          if (styleMatch != null) {
            return styleMatch.group(1);
          }
        }
        return null;
      }

      worksheetXml = worksheetXml!.replaceAllMapped(rowPattern, (match) {
        final rowStart = match.group(1)!;
        final rowNum = int.parse(match.group(2)!);
        final rowContent = match.group(3)!;
        final rowEnd = match.group(4)!;

        // 마지막 컬럼의 스타일 추출
        final lastColStyle = extractLastColumnStyle(rowContent, lastColLetter);
        final styleAttr = lastColStyle != null ? ' s="$lastColStyle"' : '';

        String newCell1; // 설치대(수정후)
        String newCell2; // 수검여부
        String newCell3; // 특이사항

        if (rowNum <= headerRowNum) {
          // 헤더 행 - 새 컬럼 헤더 추가 (스타일 유지)
          if (rowNum == 1) {
            // 1행에 "설치대(수정후)", "수검여부", "특이사항" 헤더 추가
            newCell1 = '<c r="$col1Letter$rowNum"$styleAttr t="s"><v>$headerInstallationIdx</v></c>';
            newCell2 = '<c r="$col2Letter$rowNum"$styleAttr t="s"><v>$headerInspectionIdx</v></c>';
            newCell3 = '<c r="$col3Letter$rowNum"$styleAttr t="s"><v>$headerMemoIdx</v></c>';
          } else {
            // 2행이 서브헤더인 경우 - 빈 셀 추가 (스타일 유지)
            newCell1 = '<c r="$col1Letter$rowNum"$styleAttr><v></v></c>';
            newCell2 = '<c r="$col2Letter$rowNum"$styleAttr><v></v></c>';
            newCell3 = '<c r="$col3Letter$rowNum"$styleAttr><v></v></c>';
          }
        } else {
          // 데이터 행 - 해당 스테이션의 설치대(수정후)/수검여부/특이사항 추가

          // 빈 행인지 확인 (셀 내용이 없거나 값이 없는 행)
          // <c> 태그가 없거나, 모든 <v> 태그가 비어있으면 빈 행으로 판단
          final hasCellContent = RegExp(r'<c[^>]*>.*?<v>[^<]+</v>', dotAll: true).hasMatch(rowContent);

          if (!hasCellContent) {
            // 빈 행은 건너뛰고 빈 셀만 추가
            skippedEmptyRows++;
            debugPrint('빈 행 건너뜀: rowNum=$rowNum');
            newCell1 = '<c r="$col1Letter$rowNum"$styleAttr><v></v></c>';
            newCell2 = '<c r="$col2Letter$rowNum"$styleAttr><v></v></c>';
            newCell3 = '<c r="$col3Letter$rowNum"$styleAttr><v></v></c>';
            return '$rowStart$rowContent$newCell1$newCell2$newCell3$rowEnd';
          }

          // 실제 데이터 행 - 국소명 기반으로 스테이션 매칭
          totalDataRows++;

          // Excel 행에서 매칭용 데이터 추출
          RadioStation? matchedStation;
          String extractedName = '';
          String extractedAddress = '';
          String extractedLicense = '';
          String extractedCallSign = '';

          if (stationNameCol != null) {
            extractedName = extractCellValue(rowContent, stationNameCol, rowNum).trim();
          }
          if (addressCol != null) {
            extractedAddress = extractCellValue(rowContent, addressCol, rowNum).trim();
          }
          if (licenseCol != null) {
            extractedLicense = extractCellValue(rowContent, licenseCol, rowNum).trim();
          }
          if (callSignCol != null) {
            extractedCallSign = extractCellValue(rowContent, callSignCol, rowNum).trim();
          }

          // 매칭 우선순위:
          // 1차: 허가번호로 매칭 (가장 고유함)
          if (extractedLicense.isNotEmpty) {
            matchedStation = stationByLicense[extractedLicense];
          }
          // 2차: 국소명+호출명칭으로 매칭 (같은 국소명이어도 호출명칭이 다르면 구분)
          if (matchedStation == null && extractedName.isNotEmpty) {
            final key = '$extractedName|$extractedCallSign';
            matchedStation = stationByNameAndCallSign[key];
          }
          // 3차: 국소명+주소로 매칭 (fallback)
          if (matchedStation == null && extractedName.isNotEmpty && extractedAddress.isNotEmpty) {
            final key = '$extractedName|$extractedAddress';
            matchedStation = stationByNameAndAddress[key];
          }

          // 디버그: 매칭 실패 시 로그
          if (matchedStation == null) {
            unmatchedRows++;
            debugPrint('⚠️ 매칭 실패: rowNum=$rowNum, 허가번호="$extractedLicense", '
                '국소명="$extractedName", 호출명칭="$extractedCallSign", stations수=${stations.length}');
          }

          if (matchedStation != null) {
            matchedRows++;
            // 1. 설치대(수정후) - 원본과 다를 경우에만 표시
            final currentInstallation = matchedStation.installationType ?? '';
            final originalInstallation = matchedStation.originalInstallationType ?? '';

            // 설치대(수정후) 로직:
            // - 수정사항 없을 시: 원본 설치대 표시
            // - 수정사항 있을 시: 수정된 설치대 표시
            final isInstallationChanged = currentInstallation.isNotEmpty &&
                                          originalInstallation.isNotEmpty &&
                                          currentInstallation != originalInstallation;

            // 출력할 설치대 값 결정
            final displayInstallation = isInstallationChanged ? currentInstallation : originalInstallation;

            // 디버그: 처음 10개 행에 대해 상세 로그
            if (matchedRows <= 10) {
              debugPrint('행$rowNum "${matchedStation.stationName}": '
                  '설치대 원본="$originalInstallation", 현재="$currentInstallation", '
                  '변경=$isInstallationChanged, 출력="$displayInstallation", 검사=${matchedStation.isInspected}');
            }

            // 설치대(수정후) - 항상 표시 (원본 또는 수정된 값)
            if (displayInstallation.isNotEmpty) {
              final installationIdx = getOrAddStringIndex(displayInstallation);
              newCell1 = '<c r="$col1Letter$rowNum"$styleAttr t="s"><v>$installationIdx</v></c>';
            } else {
              newCell1 = '<c r="$col1Letter$rowNum"$styleAttr><v></v></c>';
            }

            // 2. 수검여부 - 항상 값 출력
            final inspectionText = matchedStation.isInspected ? '검사완료' : '검사대기';
            final inspectionIdx = getOrAddStringIndex(inspectionText);
            newCell2 = '<c r="$col2Letter$rowNum"$styleAttr t="s"><v>$inspectionIdx</v></c>';

            // 3. 특이사항 (메모)
            final memoText = matchedStation.memo ?? '';
            if (memoText.isNotEmpty) {
              final memoIdx = getOrAddStringIndex(memoText);
              newCell3 = '<c r="$col3Letter$rowNum"$styleAttr t="s"><v>$memoIdx</v></c>';
            } else {
              newCell3 = '<c r="$col3Letter$rowNum"$styleAttr><v></v></c>';
            }
          } else {
            // 매칭 실패 시 빈 셀 (스타일 유지)
            newCell1 = '<c r="$col1Letter$rowNum"$styleAttr><v></v></c>';
            newCell2 = '<c r="$col2Letter$rowNum"$styleAttr><v></v></c>';
            newCell3 = '<c r="$col3Letter$rowNum"$styleAttr><v></v></c>';
          }
        }

        return '$rowStart$rowContent$newCell1$newCell2$newCell3$rowEnd';
      });

      // 매칭 통계 출력
      debugPrint('===== Export 매칭 통계 =====');
      debugPrint('총 데이터 행: $totalDataRows');
      debugPrint('매칭 성공: $matchedRows');
      debugPrint('매칭 실패: $unmatchedRows');
      debugPrint('건너뛴 빈 행: $skippedEmptyRows');
      debugPrint('스테이션 수: ${stations.length}');
      if (matchedRows != stations.length) {
        debugPrint('⚠️ 매칭 성공 수와 스테이션 수 불일치! (빈 행 때문일 수 있음)');
      }

      // sharedStrings.xml 업데이트 (새 문자열 추가)
      if (newStrings.isNotEmpty && sharedStringsXml != null) {
        debugPrint('새로 추가된 문자열 수: ${newStrings.length}');

        // count와 uniqueCount 업데이트
        final totalCount = sharedStrings.length + newStrings.length;
        sharedStringsXml = sharedStringsXml!.replaceAllMapped(
          RegExp(r'<sst[^>]*count="(\d+)"[^>]*uniqueCount="(\d+)"'),
          (m) => m.group(0)!
              .replaceFirst(RegExp(r'count="\d+"'), 'count="$totalCount"')
              .replaceFirst(RegExp(r'uniqueCount="\d+"'), 'uniqueCount="$totalCount"'),
        );

        // </sst> 앞에 새 문자열 추가
        final newSiElements = newStrings.map((s) => '<si><t>${_escapeXml(s)}</t></si>').join('');
        sharedStringsXml = sharedStringsXml!.replaceFirst('</sst>', '$newSiElements</sst>');
      }

      // 수정된 파일들로 새 아카이브 생성
      for (final file in archive) {
        if (file.isFile) {
          final content = file.content;
          if (content == null) continue;

          Uint8List newContent;

          if (file.name == worksheetPath) {
            // 수정된 워크시트
            newContent = Uint8List.fromList(utf8.encode(worksheetXml!));
          } else if (file.name == sharedStringsFile?.name && sharedStringsXml != null) {
            // 수정된 sharedStrings
            newContent = Uint8List.fromList(utf8.encode(sharedStringsXml!));
          } else {
            // 나머지 파일은 그대로
            newContent = Uint8List.fromList(content as List<int>);
          }

          final newFile = ArchiveFile(file.name, newContent.length, newContent);
          newFile.compress = true;
          newArchive.addFile(newFile);
        }
      }

      // ZIP 인코딩
      final modifiedBytes = ZipEncoder().encode(newArchive);
      if (modifiedBytes == null) {
        throw Exception('수정된 Excel 파일 생성 실패');
      }

      debugPrint('수정된 파일 크기: ${modifiedBytes.length} bytes');
      debugPrint('사진 수: ${photoInfoList.length}');
      debugPrint('===== 원본 서식 유지 Export 완료 =====');

      // 파일 저장
      final sanitizedName = categoryName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

      // 사진이 있으면 ZIP 파일로 내보내기, 없으면 Excel만 내보내기
      if (photoInfoList.isNotEmpty) {
        // ZIP 파일 생성 (Excel + 사진)
        final zipFileName = '${sanitizedName}_검사결과.zip';
        final filePath = await platform_export.saveExcelWithPhotosAsZip(
          Uint8List.fromList(modifiedBytes),
          '${sanitizedName}_검사결과.xlsx',
          photoInfoList,
          zipFileName,
          saveOnly: saveOnly,
        );
        debugPrint('ZIP 파일 저장 완료: $filePath');
        return filePath;
      } else {
        // Excel만 저장
        final fileName = '${sanitizedName}_검사결과.xlsx';
        final filePath = await platform_export.saveExcelFile(
          Uint8List.fromList(modifiedBytes),
          fileName,
          saveOnly: saveOnly,
        );
        debugPrint('Excel 파일 저장 완료: $filePath');
        return filePath;
      }
    } catch (e, stackTrace) {
      debugPrint('원본 서식 유지 Export 오류: $e');
      debugPrint('스택 트레이스: $stackTrace');
      rethrow;
    }
  }

  /// XML 특수문자 이스케이프
  String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
