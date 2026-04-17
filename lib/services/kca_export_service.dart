import 'dart:typed_data';
import 'package:excel/excel.dart' as excel_pkg;
import 'inspection_service.dart';

/// KCA playground Import 스펙에 맞춘 Excel 생성 서비스
/// - 시트 이름: 수검대상 / 수검일정 / 수검결과
/// - 컬럼 순서/이름은 kca-be의 `_get_columns_for_table`과 일치해야 함
class KcaExportService {
  final InspectionService _svc;

  KcaExportService({String? authToken})
      : _svc = InspectionService()..setAuthToken(authToken);

  static const List<String> _targetsColumns = [
    '허가번호', '호출명칭', '국종군', '부서', '분기', '연도주기',
    '검사주기', '허가상태', '설치장소', '도로명주소', '장치수',
    '통시', '공대', 'kca검토결과', '시기조정', '기준연도',
    'skt본부', 'access담당', '품질개선팀',
  ];

  static const List<String> _schedulesColumns = [
    '허가번호', '호출명칭', '분기', 'skt본부', 'access담당', '품질개선팀',
    '수검예정주차', '수검시작일', '수검종료일', '지역',
    '등록자', '등록일시', '검사관', '조',
  ];

  static const List<String> _resultsColumns = [
    '허가번호', 'status', '검사일', '메모', '철탑형태', '입력자',
    '입력일시', '진행여부', '성능서류', '불합격내용', '불합격상세',
    '공용화대상', '간략불합격', '기타사항', '수검자', '시스템',
    '기지국구분', '전파진흥원', '검사관', '주차별',
  ];

  /// 본부별 수검대상/일정/결과를 수집해 KCA import 호환 Excel 파일 생성
  /// [divisionShortName] 이 null/빈 문자열이면 본부 필터 없이 전체 조회
  Future<Uint8List> buildKcaImportExcel({
    required int year,
    String? divisionShortName,
  }) async {
    final division = (divisionShortName ?? '').trim();

    final targets = await _fetchTargets(year, division);
    final schedules = await _fetchSchedules(year, division);
    final results = await _fetchResults(year, division);

    final excel = excel_pkg.Excel.createExcel();
    // 기본 'Sheet1' 제거
    final defaultSheet = excel.getDefaultSheet();
    if (defaultSheet != null) {
      excel.delete(defaultSheet);
    }

    _writeSheet(excel, '수검대상', _targetsColumns, targets);
    _writeSheet(excel, '수검일정', _schedulesColumns, schedules);
    _writeSheet(excel, '수검결과', _resultsColumns, results);

    final bytes = excel.save();
    if (bytes == null) {
      throw Exception('Excel 파일 생성에 실패했습니다.');
    }
    return Uint8List.fromList(bytes);
  }

  Future<List<Map<String, dynamic>>> _fetchTargets(int year, String division) async {
    final filters = <String, List<String>>{
      if (division.isNotEmpty) 'access담당': [division],
    };
    final res = await _svc.getData(
      year: year,
      sheet: 'all',
      filters: filters,
      page: 1,
      pageSize: 100000,
    );
    return List<Map<String, dynamic>>.from(res['items'] ?? const []);
  }

  Future<List<Map<String, dynamic>>> _fetchSchedules(int year, String division) async {
    final all = await _svc.getSchedules(year, accessTeam: division);
    if (division.isEmpty) return all;
    return all.where((s) {
      final v = (s['access담당'] as String? ?? '').trim();
      return v == division;
    }).toList();
  }

  Future<List<Map<String, dynamic>>> _fetchResults(int year, String division) async {
    final items = <Map<String, dynamic>>[];
    int page = 1;
    const pageSize = 500;
    while (true) {
      final res = await _svc.getResultsRaw(
        year,
        region: division,
        page: page,
        pageSize: pageSize,
      );
      final list = List<Map<String, dynamic>>.from(res['items'] ?? const []);
      items.addAll(list);
      final total = (res['total'] as num?)?.toInt() ?? items.length;
      if (items.length >= total || list.isEmpty) break;
      page++;
    }
    return items;
  }

  void _writeSheet(
    excel_pkg.Excel excel,
    String sheetName,
    List<String> columns,
    List<Map<String, dynamic>> rows,
  ) {
    final sheet = excel[sheetName];

    // 헤더
    sheet.appendRow(
      columns.map<excel_pkg.CellValue?>(
        (c) => excel_pkg.TextCellValue(c),
      ).toList(),
    );

    // 데이터
    for (final row in rows) {
      final cells = columns.map<excel_pkg.CellValue?>((col) {
        final v = row[col];
        if (v == null) return excel_pkg.TextCellValue('');
        if (v is num) return excel_pkg.TextCellValue(v.toString());
        return excel_pkg.TextCellValue(v.toString());
      }).toList();
      sheet.appendRow(cells);
    }
  }
}
