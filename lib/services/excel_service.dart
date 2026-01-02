import 'dart:io';
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
      final bytes = file.bytes;

      if (bytes == null) {
        throw Exception('파일을 읽을 수 없습니다.');
      }

      // excel 패키지로 파싱
      try {
        final stations = _parseWithExcelPackage(bytes, fileName);
        return ExcelImportResult(stations: stations, fileName: fileName);
      } catch (e) {
        debugPrint('excel 패키지 파싱 실패: $e');
        throw Exception('Excel 파일 파싱 실패. 지원되지 않는 형식이거나 파일이 손상되었습니다.');
      }
    } catch (e) {
      debugPrint('Excel 파일 import 오류: $e');
      rethrow;
    }
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

  /// excel 패키지를 사용한 파싱
  List<RadioStation> _parseWithExcelPackage(List<int> bytes, String categoryName) {
    final excel = excel_pkg.Excel.decodeBytes(bytes);
    final List<RadioStation> stations = [];

    if (excel.tables.isEmpty) {
      throw Exception('시트가 없습니다.');
    }

    // 시트 선택 우선순위: 검사신청내역 > 신청/내역 포함 > 첫 번째 시트
    final sheetName = _findTargetSheet(excel.tables.keys.toList());
    debugPrint('선택된 시트: $sheetName (전체 시트: ${excel.tables.keys.toList()})');

    final sheet = excel.tables[sheetName];

    if (sheet == null || sheet.rows.isEmpty) {
      throw Exception('시트가 비어있습니다.');
    }

    final headerRow = sheet.rows.first;
    final columnMap = _mapColumnsExcel(headerRow);

    if (!columnMap.containsKey('address')) {
      _autoMapColumns(headerRow.length, columnMap);
    }

    for (int i = 1; i < sheet.rows.length; i++) {
      final row = sheet.rows[i];
      final station = _parseRowExcel(row, columnMap, i, categoryName);
      if (station != null) {
        stations.add(station);
      }
    }

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

  /// 컬럼 값에 따라 매핑
  void _mapColumnByValue(String value, int index, Map<String, int> columnMap) {
    // ERP국소명
    if (value.contains('ERP국소명')) {
      columnMap['stationName'] = index;
    } else if (value.contains('국소명') || value.contains('국명') || value.contains('station')) {
      if (!columnMap.containsKey('stationName')) {
        columnMap['stationName'] = index;
      }
    }
    // 호출명칭
    if (value.contains('호출명칭') || value.contains('호출') && value.contains('명칭')) {
      columnMap['callSign'] = index;
    }
    // 허가번호
    if (value.contains('허가번호') || value.contains('허가') || value.contains('license')) {
      columnMap['licenseNumber'] = index;
    }
    // 설치장소(주소)
    if (value.contains('설치장소')) {
      columnMap['address'] = index;
    }
    // 이득(dB)
    if (value.contains('이득') || value.contains('gain') || value.contains('db')) {
      columnMap['gain'] = index;
    }
    // 기수
    if (value.contains('기수') || value.contains('antenna') && value.contains('count')) {
      columnMap['antennaCount'] = index;
    }
    // 비고
    if (value.contains('비고') || value.contains('remarks') || value.contains('note')) {
      columnMap['remarks'] = index;
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

      if (address.isEmpty && stationName.isEmpty) {
        return null;
      }

      final finalAddress = address.isNotEmpty ? address : stationName;

      return RadioStation(
        id: 'station_${categoryName}_${rowIndex}_${DateTime.now().millisecondsSinceEpoch}',
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
