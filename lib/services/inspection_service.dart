import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// 수검 일정 관리 서비스
class InspectionService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );
  static const _apiTimeout = Duration(seconds: 30);
  static const _uploadTimeout = Duration(minutes: 10);

  String? _authToken;
  void setAuthToken(String? token) => _authToken = token;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${_authToken ?? ''}',
        'Content-Type': 'application/json',
      };

  // ── Import ──────────────────────────────────────────────

  Future<String> uploadRaw(Uint8List bytes, String filename) async {
    final uri = Uri.parse('$_baseUrl/inspection/upload-raw');
    final req = http.Request('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..headers['X-Filename'] = Uri.encodeComponent(filename)
      ..headers['Content-Type'] = 'application/octet-stream'
      ..bodyBytes = bytes;
    final streamed = await req.send().timeout(_uploadTimeout);
    final body = json.decode(await streamed.stream.bytesToString()) as Map<String, dynamic>;
    if (streamed.statusCode != 200) throw Exception(body['detail'] ?? '업로드 실패');
    return body['s3Key'] as String;
  }

  Future<String> enqueue(String s3Key, int year, String uploadedBy) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/enqueue'),
      headers: _headers,
      body: json.encode({'s3Key': s3Key, 'year': year, 'uploadedBy': uploadedBy}),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '잡 생성 실패');
    return body['jobId'] as String;
  }

  Future<Map<String, dynamic>> jobStatus(String jobId) async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/inspection/job/$jobId'),
      headers: _headers,
    ).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  // ── Meta ─────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getMeta() async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/inspection/meta'),
      headers: _headers,
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  // ── 미배정 항목 조회 ────────────────────────────────────

  Future<Map<String, dynamic>> getUnassigned(int year) async {
    final uri = Uri.parse('$_baseUrl/inspection/unassigned')
        .replace(queryParameters: {'year': '$year'});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  // ── Staging (필터링 후 확정) ─────────────────────────────

  Future<List<Map<String, dynamic>>> getStagingColumnValues(int year, String col) async {
    final uri = Uri.parse('$_baseUrl/inspection/staging/column-values').replace(
        queryParameters: {'year': '$year', 'col': col});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['values'] ?? []);
  }

  Future<Map<String, dynamic>> getStagingPreview(int year, Map<String, List<String>> filters) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/staging/preview'),
      headers: _headers,
      body: json.encode({'year': year, 'filters': filters}),
    ).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getStagingItems(int year, {
    Map<String, List<String>> filters = const {},
    String search = '',
    int page = 1,
    int pageSize = 500,
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/staging/items'),
      headers: _headers,
      body: json.encode({'year': year, 'filters': filters, 'search': search, 'page': page, 'pageSize': pageSize}),
    ).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<int> confirmStaging(int year, Map<String, List<String>> filters) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/staging/confirm'),
      headers: _headers,
      body: json.encode({'year': year, 'filters': filters}),
    ).timeout(const Duration(minutes: 5));
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '확정 실패');
    return body['count'] as int? ?? 0;
  }

  // ── Query ────────────────────────────────────────────────

  Future<Map<String, dynamic>> getOrgMap(int year) async {
    final uri = Uri.parse('$_baseUrl/inspection/org-map').replace(
        queryParameters: {'year': '$year'});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<List<String>> getColumnValues(int year, String col, {String sheet = 'all'}) async {
    final uri = Uri.parse('$_baseUrl/inspection/column-values').replace(
        queryParameters: {'year': '$year', 'col': col, 'sheet': sheet});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<String>.from(body['values'] ?? []);
  }

  Future<Map<String, dynamic>> getData({
    required int year,
    String sheet = 'all',
    Map<String, List<String>> filters = const {},
    String search = '',
    String addr = '',
    int page = 1,
    int pageSize = 100,
    String scheduleYn = '',
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/data'),
      headers: _headers,
      body: json.encode({
        'year': year, 'sheet': sheet,
        'filters': filters, 'search': search, 'addr': addr,
        'page': page, 'page_size': pageSize,
        'schedule_yn': scheduleYn,
      }),
    ).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getSummary({
    required int year,
    String sheet = 'all',
    Map<String, List<String>> filters = const {},
    String search = '',
    String addr = '',
    String scheduleYn = '',
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/summary'),
      headers: _headers,
      body: json.encode({
        'year': year, 'sheet': sheet,
        'filters': filters, 'search': search, 'addr': addr,
        'schedule_yn': scheduleYn,
      }),
    ).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Uint8List> exportXlsx({
    required int year,
    String sheet = 'all',
    Map<String, List<String>> filters = const {},
    String search = '',
    String addr = '',
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/export-xlsx'),
      headers: _headers,
      body: json.encode({
        'year': year, 'sheet': sheet,
        'filters': filters, 'search': search, 'addr': addr,
      }),
    ).timeout(const Duration(minutes: 3));
    if (resp.statusCode != 200) throw Exception('Export 실패: ${resp.statusCode}');
    return resp.bodyBytes;
  }

  Future<Map<String, dynamic>> getDetail(int year, String licenseNo) async {
    final uri = Uri.parse('$_baseUrl/inspection/detail').replace(
        queryParameters: {'year': '$year', '허가번호': licenseNo});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  // ── Schedule ─────────────────────────────────────────────

  Future<void> upsertSchedule(Map<String, dynamic> data) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/schedule'),
      headers: _headers,
      body: json.encode(data),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '일정 저장 실패');
    }
  }

  Future<void> deleteSchedule(int year, String licenseNo) async {
    final resp = await http.delete(
      Uri.parse('$_baseUrl/inspection/schedule/$year/${Uri.encodeComponent(licenseNo)}'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('일정 삭제 실패');
  }

  Future<List<Map<String, dynamic>>> getSchedules(int year, {String accessTeam = ''}) async {
    final uri = Uri.parse('$_baseUrl/inspection/schedules').replace(queryParameters: {
      'year': '$year',
      if (accessTeam.isNotEmpty) 'access담당': accessTeam,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  // ── Result ───────────────────────────────────────────────

  Future<void> upsertResult(Map<String, dynamic> data) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/result'),
      headers: _headers,
      body: json.encode(data),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '결과 저장 실패');
    }
  }

  Future<Map<String, dynamic>> uploadPhoto(
      int year, String licenseNo, Uint8List bytes, String filename) async {
    final uri = Uri.parse('$_baseUrl/inspection/result/photo').replace(
        queryParameters: {'year': '$year', '허가번호': licenseNo});
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await req.send().timeout(_uploadTimeout);
    final body = json.decode(await streamed.stream.bytesToString()) as Map<String, dynamic>;
    if (streamed.statusCode != 200) throw Exception(body['detail'] ?? '사진 업로드 실패');
    return body;
  }

  Future<void> deletePhoto(int year, String licenseNo, String s3Key) async {
    final uri = Uri.parse('$_baseUrl/inspection/result/photo').replace(
        queryParameters: {'year': '$year', '허가번호': licenseNo, 's3_key': s3Key});
    final resp = await http.delete(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('사진 삭제 실패');
  }

  /// YOLO 철탑형태 분류 (POST /predict)
  Future<Map<String, dynamic>> classifyTower(
      Uint8List imageBytes, String filename) async {
    final uri = Uri.parse('$_baseUrl/predict');
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(
          http.MultipartFile.fromBytes('file', imageBytes, filename: filename));
    final streamed = await req.send().timeout(const Duration(minutes: 2));
    final body = json.decode(await streamed.stream.bytesToString())
        as Map<String, dynamic>;
    if (streamed.statusCode != 200) {
      throw Exception(body['detail'] ?? '분류 실패');
    }
    return body;
  }

  Future<String> getPhotoUrl(String s3Key) async {
    final uri = Uri.parse('$_baseUrl/inspection/result/photo-url').replace(
        queryParameters: {'s3_key': s3Key});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return body['url'] as String;
  }

  /// 사진 바이너리 직접 반환 (Flutter web CORS 우회)
  Future<Uint8List> getPhotoData(String s3Key) async {
    final uri = Uri.parse('$_baseUrl/inspection/result/photo-data').replace(
        queryParameters: {'s3_key': s3Key});
    final resp = await http.get(uri, headers: _headers).timeout(const Duration(minutes: 1));
    if (resp.statusCode != 200) throw Exception('사진 로드 실패: ${resp.statusCode}');
    return resp.bodyBytes;
  }

  Future<List<Map<String, dynamic>>> getMyList(int year, {String week = ''}) async {
    final uri = Uri.parse('$_baseUrl/inspection/my-list').replace(
        queryParameters: {
          'year': '$year',
          if (week.isNotEmpty) 'week': week,
        });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  Future<List<String>> getMyListWeeks(int year) async {
    final uri = Uri.parse('$_baseUrl/inspection/my-list/weeks').replace(
        queryParameters: {'year': '$year'});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<String>.from(body['weeks'] ?? []);
  }

  Future<List<Map<String, dynamic>>> getProgress(int year) async {
    final uri = Uri.parse('$_baseUrl/inspection/progress').replace(
        queryParameters: {'year': '$year'});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  Future<Map<String, dynamic>> geocodeTargets(int year) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/geocode-targets').replace(
          queryParameters: {'year': '$year'}),
      headers: _headers,
    ).timeout(const Duration(minutes: 30));
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '지오코딩 실패');
    return body;
  }

  Future<Uint8List> exportInspectionReport({
    required int year,
    List<String> licenseNos = const [],
    String sheet = 'all',
    Map<String, List<String>> filters = const {},
    String search = '',
    String addr = '',
    String scheduleYn = '',
    String sheetTitle = '',
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/export-inspection-report'),
      headers: _headers,
      body: json.encode({
        'year': year,
        '\ud5c8\uac00\ubc88\ud638_list': licenseNos,
        'sheet': sheet,
        'filters': filters,
        'search': search,
        'addr': addr,
        'schedule_yn': scheduleYn,
        'sheet_title': sheetTitle,
      }),
    ).timeout(const Duration(minutes: 3));
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '\uac80\uc0ac\ub0b4\uc5ed\uc11c \uc0dd\uc131 \uc2e4\ud328');
    }
    return resp.bodyBytes;
  }

  Future<Map<String, dynamic>> addFromStaging(int year, String licenseNo) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/add-from-staging'),
      headers: _headers,
      body: json.encode({'year': year, '\ud5c8\uac00\ubc88\ud638': licenseNo}),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '추가 실패');
    return body['item'] as Map<String, dynamic>;
  }

  // ── 실적 결과장 ──────────────────────────────────────────

  /// 실적 결과장 업로드
  Future<Map<String, dynamic>> uploadResults(Uint8List bytes, String filename) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/upload');
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await req.send().timeout(const Duration(minutes: 5));
    final body = json.decode(await streamed.stream.bytesToString());
    if (streamed.statusCode != 200) throw Exception(body['detail'] ?? '업로드 실패');
    return body as Map<String, dynamic>;
  }

  /// 대시보드 통계
  Future<Map<String, dynamic>> getResultsDashboard(int year, {String region = ''}) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/dashboard')
        .replace(queryParameters: {
      'year': '$year',
      if (region.isNotEmpty) 'region': region,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 월별 대시보드
  Future<Map<String, dynamic>> getResultsMonthly(int year, String month, {String region = ''}) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/dashboard/monthly')
        .replace(queryParameters: {
      'year': '$year',
      'month': month,
      if (region.isNotEmpty) 'region': region,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 추이 데이터
  Future<Map<String, dynamic>> getResultsTrend(int year) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/trend')
        .replace(queryParameters: {'year': '$year'});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// RAW DATA 목록
  Future<Map<String, dynamic>> getResultsRaw(int year, {
    String region = '',
    String month = '',
    int page = 1,
    int pageSize = 100,
  }) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/raw')
        .replace(queryParameters: {
      'year': '$year',
      if (region.isNotEmpty) 'region': region,
      if (month.isNotEmpty) 'month': month,
      'page': '$page',
      'page_size': '$pageSize',
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getResultsAnalysis(int year, {String region = ''}) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/analysis')
        .replace(queryParameters: {
      'year': '$year',
      if (region.isNotEmpty) 'region': region,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('분석 조회 실패');
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getResultsWeeklyTrendByRegion(int year, {String region = ''}) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/weekly-trend-by-region')
        .replace(queryParameters: {
      'year': '$year',
      if (region.isNotEmpty) 'region': region,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('본부별 주차별 추이 조회 실패');
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getResultsWeeklyTrend(int year, {String region = ''}) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/weekly-trend')
        .replace(queryParameters: {
      'year': '$year',
      if (region.isNotEmpty) 'region': region,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('주차별 추이 조회 실패');
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getResultsSummaryReport(int year, {String region = ''}) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/summary-report')
        .replace(queryParameters: {
      'year': '$year',
      if (region.isNotEmpty) 'region': region,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('리포트 조회 실패');
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Uint8List> exportResultsXlsx(int year, {
    String region = '', String progress = '', String status = '',
    String perfDoc = '', String week = '',
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection-results/export-xlsx'),
      headers: _headers,
      body: json.encode({
        'year': year, '본부': region, '진행여부': progress,
        'status': status, '성능서류': perfDoc, '주차별': week,
      }),
    ).timeout(const Duration(minutes: 5));
    if (resp.statusCode != 200) throw Exception('엑셀 다운로드 실패');
    return resp.bodyBytes;
  }

  Future<String> buildDsDetail(String divisionId, String importDate) async {
    final uri = Uri.parse('$_baseUrl/inspection/build-ds-detail').replace(
        queryParameters: {'division_id': divisionId, 'import_date': importDate});
    final resp = await http.post(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '빌드 실패');
    return body['jobId'] as String;
  }
}
