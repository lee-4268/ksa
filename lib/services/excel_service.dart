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

  ExcelImportResult({required this.stations, required this.fileName});
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

      // excel 패키지로 파싱 (numFmtId 오류 시 XML 직접 파싱으로 fallback)
      try {
        final stations = _parseWithExcelPackage(bytes, fileName);
        return ExcelImportResult(stations: stations, fileName: fileName);
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
              return ExcelImportResult(stations: stations, fileName: fileName);
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
            return ExcelImportResult(stations: stations, fileName: fileName);
          } catch (e2, stackTrace) {
            debugPrint('전처리 후에도 파싱 실패: $e2');
            debugPrint('스택트레이스: $stackTrace');

            // 원본 파일로 다시 시도 (numFmt 무시)
            debugPrint('원본 파일로 재시도 중...');
            try {
              final stations = _parseWithExcelPackageIgnoreNumFmt(bytes, fileName);
              debugPrint('원본 파일 파싱 성공 (numFmt 무시)');
              return ExcelImportResult(stations: stations, fileName: fileName);
            } catch (e3) {
              debugPrint('원본 파일 파싱도 실패: $e3');

              // 최후의 수단: XML 직접 파싱 (비동기)
              debugPrint('XML 직접 파싱 시도 중...');
              try {
                final stations = await _parseXmlDirectly(bytes, fileName);
                debugPrint('XML 직접 파싱 성공: ${stations.length}개');
                return ExcelImportResult(stations: stations, fileName: fileName);
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
      debugPrint('첫 번째 행 XML (처음 500자): ${headerRowContent.length > 500 ? headerRowContent.substring(0, 500) : headerRowContent}');

      final headerCells = _extractCellsFromRow(headerRowContent, sharedStrings);
      debugPrint('헤더: $headerCells');

      // 헤더 매핑
      final columnMap = <String, int>{};
      for (int i = 0; i < headerCells.length; i++) {
        final value = headerCells[i].toLowerCase();
        _mapColumnByValue(value, i, columnMap);
      }
      debugPrint('컬럼 매핑: $columnMap');

      // 주소 컬럼이 없으면 자동 매핑
      if (!columnMap.containsKey('address')) {
        _autoMapColumns(headerCells.length, columnMap);
      }

      // 데이터 행 파싱 (청크 단위로 처리하여 UI 응답성 유지)
      const int chunkSize = 20; // 20개 행마다 이벤트 루프에 제어권 반환
      for (int i = 1; i < rows.length; i++) {
        final rowContent = rows[i].group(1) ?? '';
        final cells = _extractCellsFromRow(rowContent, sharedStrings);

        String getCellValue(String key) {
          final index = columnMap[key];
          if (index == null || index >= cells.length) return '';
          return cells[index];
        }

        final stationName = getCellValue('stationName');
        final address = getCellValue('address');

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
          remarks: getCellValue('remarks').isNotEmpty ? getCellValue('remarks') : null,
          typeApprovalNumber: getCellValue('typeApprovalNumber').isNotEmpty ? getCellValue('typeApprovalNumber') : null,
          categoryName: categoryName,
        ));

        // 청크 단위로 이벤트 루프에 제어권 반환 (웹 UI 응답성 유지)
        if (i % chunkSize == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      debugPrint('XML 직접 파싱 완료: ${stations.length}개');
      return stations;
    } catch (e) {
      debugPrint('XML 직접 파싱 오류: $e');
      rethrow;
    }
  }

  /// XML 행에서 셀 값 추출
  List<String> _extractCellsFromRow(String rowXml, List<String> sharedStrings) {
    final cells = <String>[];

    // 모든 셀 위치를 추적
    final cellMap = <int, String>{};
    int maxCol = 0;

    // 방법 1: <c ... >...</c> 형태 (내용이 있는 셀)
    // 공백이 있든 없든 매칭되도록 \s* 사용
    final cellWithContentPattern = RegExp(r'<c\s*([^>]*)>(.*?)</c>', multiLine: true, dotAll: true);

    for (final match in cellWithContentPattern.allMatches(rowXml)) {
      final attributes = match.group(1) ?? '';
      final content = match.group(2) ?? '';

      // r 속성에서 셀 위치 추출 (예: r="A1", r="AB123")
      final rMatch = RegExp(r'r="([A-Z]+)(\d+)"').firstMatch(attributes);
      if (rMatch == null) continue;

      final colLetter = rMatch.group(1) ?? 'A';

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

      // 열 문자를 인덱스로 변환 (A=0, B=1, ..., Z=25, AA=26, ...)
      int colIndex = 0;
      for (int i = 0; i < colLetter.length; i++) {
        colIndex = colIndex * 26 + (colLetter.codeUnitAt(i) - 'A'.codeUnitAt(0) + 1);
      }
      colIndex--; // 0-based

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
    // ERP국소명 (대소문자 무시)
    if (value.contains('erp국소명') || value.contains('erp 국소명')) {
      columnMap['stationName'] = index;
    } else if (value.contains('국소명') || value.contains('국명') || value.contains('station')) {
      if (!columnMap.containsKey('stationName')) {
        columnMap['stationName'] = index;
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
    if (value.contains('이득') || value.contains('gain') || value.contains('db')) {
      columnMap['gain'] = index;
    }
    // 기수
    if (value.contains('기수') || (value.contains('antenna') && value.contains('count'))) {
      columnMap['antennaCount'] = index;
    }
    // 비고
    if (value.contains('비고') || value.contains('remarks') || value.contains('note')) {
      columnMap['remarks'] = index;
    }
    // 형식검정번호
    if (value.contains('형식검정번호') || value.contains('형식검정') || value.contains('검정번호')) {
      columnMap['typeApprovalNumber'] = index;
    }
    // 주파수
    if (value.contains('주파수') || value.contains('frequency') || value.contains('freq')) {
      columnMap['frequency'] = index;
    }
    // 종류
    if (value.contains('종류') || value.contains('종별') || value.contains('type') || value.contains('구분')) {
      columnMap['stationType'] = index;
    }
    // 소유자
    if (value.contains('소유자') || value.contains('owner') || value.contains('대표자') || value.contains('사업자')) {
      columnMap['owner'] = index;
    }
    // 위도
    if (value.contains('위도') || value.contains('lat')) {
      columnMap['latitude'] = index;
    }
    // 경도
    if (value.contains('경도') || value.contains('lng') || value.contains('lon')) {
      columnMap['longitude'] = index;
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
        remarks: remarks.isNotEmpty ? remarks : null,
        typeApprovalNumber: typeApprovalNumber.isNotEmpty ? typeApprovalNumber : null,
        categoryName: categoryName,
      );
    } catch (e) {
      debugPrint('행 $rowIndex 파싱 오류: $e');
      return null;
    }
  }

  /// 국소명을 안전한 파일명으로 변환
  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*\s]'), '_');
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

      // 헤더 추가 (사진 열 제거)
      final headers = ['호출명칭', 'ERP국소명', '설치장소(주소)', '허가번호', '특이사항 메모', '검사상태'];
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

        // 특이사항 메모
        sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: rowIndex))
            .value = excel_pkg.TextCellValue(station.memo ?? '');

        // 검사상태
        final inspectionStatus = station.isInspected ? '검사완료' : '검사대기';
        sheet.cell(excel_pkg.CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: rowIndex))
            .value = excel_pkg.TextCellValue(inspectionStatus);

        // 사진 파일 정보 수집 (국소명 폴더/파일명 구조)
        if (station.photoPaths != null && station.photoPaths!.isNotEmpty) {
          final sanitizedStationName = _sanitizeFileName(station.stationName);

          for (int j = 0; j < station.photoPaths!.length; j++) {
            final photoPath = station.photoPaths![j];
            final extension = photoPath.split('.').last.toLowerCase();
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
      sheet.setColumnWidth(0, 15);  // 호출명칭
      sheet.setColumnWidth(1, 25);  // ERP국소명
      sheet.setColumnWidth(2, 40);  // 설치장소(주소)
      sheet.setColumnWidth(3, 15);  // 허가번호
      sheet.setColumnWidth(4, 30);  // 특이사항 메모
      sheet.setColumnWidth(5, 12);  // 검사상태

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
}
