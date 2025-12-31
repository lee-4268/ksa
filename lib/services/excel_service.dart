import 'dart:io';
import 'package:excel/excel.dart' as excel_pkg;
import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import '../models/radio_station.dart';

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
      List<int>? bytes;

      if (kIsWeb) {
        bytes = file.bytes;
      } else {
        if (file.path != null) {
          bytes = await File(file.path!).readAsBytes();
        } else {
          bytes = file.bytes;
        }
      }

      if (bytes == null) {
        throw Exception('파일을 읽을 수 없습니다.');
      }

      // 1차 시도: excel 패키지로 파싱
      try {
        final stations = _parseWithExcelPackage(bytes, fileName);
        return ExcelImportResult(stations: stations, fileName: fileName);
      } catch (e) {
        debugPrint('excel 패키지 파싱 실패: $e');
        debugPrint('spreadsheet_decoder로 재시도...');

        // 2차 시도: spreadsheet_decoder로 파싱
        final stations = _parseWithSpreadsheetDecoder(bytes, fileName);
        return ExcelImportResult(stations: stations, fileName: fileName);
      }
    } catch (e) {
      debugPrint('Excel 파일 import 오류: $e');
      rethrow;
    }
  }

  /// excel 패키지를 사용한 파싱
  List<RadioStation> _parseWithExcelPackage(List<int> bytes, String categoryName) {
    final excel = excel_pkg.Excel.decodeBytes(bytes);
    final List<RadioStation> stations = [];

    if (excel.tables.isEmpty) {
      throw Exception('시트가 없습니다.');
    }

    // '검사신청내역' 시트를 우선 찾고, 없으면 첫 번째 시트 사용
    String sheetName;
    if (excel.tables.containsKey('검사신청내역')) {
      sheetName = '검사신청내역';
    } else {
      // 시트 이름에 '신청' 또는 '내역'이 포함된 시트 찾기
      sheetName = excel.tables.keys.firstWhere(
        (name) => name.contains('신청') || name.contains('내역'),
        orElse: () => excel.tables.keys.first,
      );
    }
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

  /// spreadsheet_decoder 패키지를 사용한 파싱 (대체 방법)
  List<RadioStation> _parseWithSpreadsheetDecoder(List<int> bytes, String categoryName) {
    final decoder = SpreadsheetDecoder.decodeBytes(bytes);
    final List<RadioStation> stations = [];

    if (decoder.tables.isEmpty) {
      throw Exception('시트가 없습니다.');
    }

    // '검사신청내역' 시트를 우선 찾고, 없으면 첫 번째 시트 사용
    String sheetName;
    if (decoder.tables.containsKey('검사신청내역')) {
      sheetName = '검사신청내역';
    } else {
      sheetName = decoder.tables.keys.firstWhere(
        (name) => name.contains('신청') || name.contains('내역'),
        orElse: () => decoder.tables.keys.first,
      );
    }
    debugPrint('선택된 시트 (decoder): $sheetName');

    final sheet = decoder.tables[sheetName];

    if (sheet == null || sheet.rows.isEmpty) {
      throw Exception('시트가 비어있습니다.');
    }

    final headerRow = sheet.rows.first;
    final columnMap = _mapColumnsDecoder(headerRow);

    if (!columnMap.containsKey('address')) {
      _autoMapColumns(headerRow.length, columnMap);
    }

    for (int i = 1; i < sheet.rows.length; i++) {
      final row = sheet.rows[i];
      final station = _parseRowDecoder(row, columnMap, i, categoryName);
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

  /// spreadsheet_decoder용 헤더 매핑
  Map<String, int> _mapColumnsDecoder(List<dynamic> headerRow) {
    final Map<String, int> columnMap = {};

    for (int i = 0; i < headerRow.length; i++) {
      final cell = headerRow[i];
      if (cell == null) continue;

      final value = cell.toString().trim().toLowerCase();
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

  /// spreadsheet_decoder용 행 파싱
  RadioStation? _parseRowDecoder(List<dynamic> row, Map<String, int> columnMap, int rowIndex, String categoryName) {
    try {
      String getCellValue(String key) {
        final index = columnMap[key];
        if (index == null || index >= row.length) return '';
        final cell = row[index];
        if (cell == null) return '';
        return cell.toString().trim();
      }

      double? getCellDouble(String key) {
        final value = getCellValue(key);
        if (value.isEmpty) return null;
        final numStr = value.replaceAll(RegExp(r'[^\d.-]'), '');
        return double.tryParse(numStr);
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
      debugPrint('행 $rowIndex 파싱 오류 (decoder): $e');
      return null;
    }
  }
}
