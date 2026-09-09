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

  // ── 특이국소 관리 ─────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getSpecialSites() async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/special-sites'),
      headers: _headers,
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '특이국소 조회 실패');
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  Future<Map<String, dynamic>> resolveSpecialSites(List<String> licenses) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/special-sites/resolve'),
      headers: _headers,
      body: json.encode({'licenses': licenses}),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '대상 조회 실패');
    return body;
  }

  Future<Map<String, dynamic>> bulkRegisterSpecialSites(
      List<String> licenses, String type, String memo) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/special-sites/bulk'),
      headers: _headers,
      body: json.encode({'licenses': licenses, '유형': type, '메모': memo}),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '특이국소 등록 실패');
    return body;
  }

  Future<int> deleteSpecialSites(List<String> licenses) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/special-sites/delete'),
      headers: _headers,
      body: json.encode({'licenses': licenses}),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '특이국소 삭제 실패');
    return (body['deleted'] as num?)?.toInt() ?? 0;
  }

  // ── 실적(결과장) → 일정·결과 백필 ───────────────────────────

  Future<Map<String, dynamic>> backfillFromResults({
    required int year,
    String region = '',
    bool dryRun = true,
    bool overwrite = false,
    bool withSchedules = true,
    bool addMissingTargets = true,
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection-results/backfill'),
      headers: _headers,
      body: json.encode({
        'year': year,
        if (region.isNotEmpty) 'region': region,
        'dry_run': dryRun,
        'overwrite': overwrite,
        'with_schedules': withSchedules,
        'add_missing_targets': addMissingTargets,
      }),
    ).timeout(const Duration(minutes: 5));
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '실적 백필 실패');
    return body;
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
    String scheduleWeek = '',
    List<String> workflowStatuses = const [],   // Phase 5: 워크플로우 상태 서버측 필터 (복수 선택)
    String needsRecheck = '',     // Phase 5: '1' = 재점검 필요만
    String overdueOnly = '',      // Phase 5: '1' = SLA 임계점 초과 건만
    String sortBy = '',
    String sortDir = 'asc',
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/data'),
      headers: _headers,
      body: json.encode({
        'year': year, 'sheet': sheet,
        'filters': filters, 'search': search, 'addr': addr,
        'page': page, 'page_size': pageSize,
        'schedule_yn': scheduleYn,
        'schedule_week': scheduleWeek,
        'workflow_status': workflowStatuses.join(','),
        'needs_recheck': needsRecheck,
        'overdue_only': overdueOnly,
        'sort_by': sortBy,
        'sort_dir': sortDir,
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

  Future<Uint8List> exportAllXlsx({
    required int year,
    String accessTeam = '',
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/export-all-xlsx'),
      headers: _headers,
      body: json.encode({'year': year, 'access담당': accessTeam}),
    ).timeout(const Duration(minutes: 5));
    if (resp.statusCode != 200) throw Exception('통합 Export 실패: ${resp.statusCode}');
    return resp.bodyBytes;
  }

  Future<Map<String, dynamic>> getDetail(int year, String licenseNo) async {
    final uri = Uri.parse('$_baseUrl/inspection/detail').replace(
        queryParameters: {'year': '$year', '허가번호': licenseNo});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> updateTargetReview(int year, String licenseNo, String value) async {
    final uri = Uri.parse('$_baseUrl/inspection/target-review').replace(
        queryParameters: {'year': '$year', '허가번호': licenseNo, '시기조정': value});
    final resp = await http.patch(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('검토 결과 저장 실패');
  }

  // ── Schedule ─────────────────────────────────────────────

  Future<Map<String, dynamic>> coLocatedCheck(int year, List<String> licenses) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/schedule/co-located-check'),
      headers: _headers,
      body: json.encode({'year': year, 'licenses': licenses}),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '동일국소 확인 실패');
    return body;
  }

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

  // ── Workflow (Phase 1) ───────────────────────────────────

  Future<void> transitionStatus(String pk, String toStatus, {String memo = ''}) async {
    final resp = await http.patch(
      Uri.parse('$_baseUrl/inspection/schedule/${Uri.encodeComponent(pk)}/status'),
      headers: _headers,
      body: json.encode({'to_status': toStatus, 'memo': memo}),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '상태 전환 실패');
    }
  }

  /// admin/manager 전용 — 강등 포함 어떤 상태로든 강제 변경
  Future<void> forceTransitionStatus(String pk, String toStatus, {String memo = ''}) async {
    final resp = await http.patch(
      Uri.parse('$_baseUrl/inspection/schedule/${Uri.encodeComponent(pk)}/status-force'),
      headers: _headers,
      body: json.encode({'to_status': toStatus, 'memo': memo}),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '상태 강제 변경 실패');
    }
  }

  Future<Map<String, dynamic>> transitionStatusBulk(
      List<String> schedulePks, String toStatus, {String memo = ''}) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/schedule/transition-bulk'),
      headers: _headers,
      body: json.encode({
        'schedule_pks': schedulePks,
        'to_status': toStatus,
        'memo': memo,
      }),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '일괄 전환 실패');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getStatusLog(String pk) async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/inspection/schedule/${Uri.encodeComponent(pk)}/log'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('이력 조회 실패');
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  Future<void> submitPreCheckResult(
      String pk,
      Map<String, dynamic> summary, {
      List<Map<String, dynamic>> items = const [],
      bool confirmationAcknowledged = false,
      }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/schedule/${Uri.encodeComponent(pk)}/pre-check-result'),
      headers: _headers,
      body: json.encode({
        'summary': summary,
        'items': items,
        'confirmation_acknowledged': confirmationAcknowledged,
      }),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '결과 회신 실패');
    }
  }

  // ── Change Request (Phase 2) ─────────────────────────────

  Future<int> createChangeRequest(String schedulePk, List<Map<String, dynamic>> items) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/schedule/${Uri.encodeComponent(schedulePk)}/change-request'),
      headers: _headers,
      body: json.encode({'items': items}),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '변경개설 요청 실패');
    }
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return (body['count'] as num?)?.toInt() ?? 0;
  }

  Future<int> createChangeRequestDirect(String licenseNo, List<Map<String, dynamic>> items) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/change-request/direct'),
      headers: _headers,
      body: json.encode({'허가번호': licenseNo, 'items': items}),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '변경개설 요청 실패');
    }
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return (body['count'] as num?)?.toInt() ?? 0;
  }

  Future<Map<String, int>> markPreChecked(List<String> licenseNos, {int year = 0, String status = 'PRE_CHECKED'}) async {
    final resp = await http.patch(
      Uri.parse('$_baseUrl/inspection/targets/pre-check-status'),
      headers: _headers,
      body: json.encode({'license_nos': licenseNos, 'status': status, 'year': year}),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '사전점검완료 표시 실패');
    }
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return {
      'updated': (body['updated'] as num?)?.toInt() ?? 0,
      'updated_targets': (body['updated_targets'] as num?)?.toInt() ?? 0,
      'updated_schedules': (body['updated_schedules'] as num?)?.toInt() ?? 0,
    };
  }

  Future<List<Map<String, dynamic>>> listChangeRequests({
    String schedulePk = '', String status = '',
    String licenseNo = '', String accessTeam = '', int year = 0,
  }) async {
    final qp = <String, String>{};
    if (schedulePk.isNotEmpty) qp['schedule_pk'] = schedulePk;
    if (status.isNotEmpty) qp['status'] = status;
    if (licenseNo.isNotEmpty) qp['허가번호'] = licenseNo;
    if (accessTeam.isNotEmpty) qp['access담당'] = accessTeam;
    if (year > 0) qp['year'] = '$year';
    final uri = Uri.parse('$_baseUrl/change-request').replace(queryParameters: qp);
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('변경 요청 조회 실패');
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  /// 변경개설 요청 단건 취소 (REQUESTED 상태만 가능)
  Future<Map<String, dynamic>> cancelChangeRequest(int crId) async {
    final resp = await http.delete(
      Uri.parse('$_baseUrl/change-request/$crId'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '취소 실패');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 변경개설 요청 일괄 취소 — schedule_pks 또는 ids
  Future<Map<String, dynamic>> cancelChangeRequestBulk({
    List<String> schedulePks = const [],
    List<int> ids = const [],
  }) async {
    final body = <String, dynamic>{};
    if (schedulePks.isNotEmpty) body['schedule_pks'] = schedulePks;
    if (ids.isNotEmpty) body['ids'] = ids;
    final resp = await http.post(
      Uri.parse('$_baseUrl/change-request/cancel-bulk'),
      headers: _headers,
      body: json.encode(body),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '일괄 취소 실패');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> markChangeRequestFiled({
    String schedulePk = '',
    List<String> schedulePks = const [],
    String memo = '',
  }) async {
    final body = <String, dynamic>{'memo': memo};
    if (schedulePk.isNotEmpty) body['schedule_pk'] = schedulePk;
    if (schedulePks.isNotEmpty) body['schedule_pks'] = schedulePks;
    final resp = await http.patch(
      Uri.parse('$_baseUrl/change-request/file'),
      headers: _headers,
      body: json.encode(body),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '신고 완료 처리 실패');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// A파일(신고서) xls 묶음 다운로드 — bytes 반환
  /// 묶음 키(qualityTeam/week/team/year) 또는 schedule_pk 단건 지원
  Future<List<int>> generateChangeRequestForm({
    String schedulePk = '',
    String qualityTeam = '',
    String week = '',
    String team = '',
    int year = 0,
  }) async {
    final qp = <String, String>{};
    if (schedulePk.isNotEmpty) qp['schedule_pk'] = schedulePk;
    if (qualityTeam.isNotEmpty) qp['품질개선팀'] = qualityTeam;
    if (week.isNotEmpty) qp['수검예정주차'] = week;
    if (team.isNotEmpty) qp['조'] = team;
    if (year > 0) qp['year'] = '$year';
    final uri = Uri.parse('$_baseUrl/change-request/generate-form')
        .replace(queryParameters: qp);
    final resp = await http.post(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('신고서 생성 실패: ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }

  /// 필터 결과 통합 신고서 — 일정 pk 목록 전체를 하나의 xls 로 (혁신팀 탭)
  Future<Uint8List> generateChangeFormByPks(
      List<String> schedulePks, String sheetLabel) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/change-request/generate-form'),
      headers: _headers,
      body: json.encode({'schedule_pks': schedulePks, 'sheet_label': sheetLabel}),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('신고서 생성 실패: ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }

  /// 부분 DS 파일 파싱 → 변경 전/후 diff 반환 (DB 미적용)
  Future<Map<String, dynamic>> previewPartialDsUpdate(Uint8List bytes, String filename) async {
    final uri = Uri.parse('$_baseUrl/ds/preview-partial-update');
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await req.send().timeout(_uploadTimeout);
    final body = json.decode(utf8.decode(await streamed.stream.toBytes())) as Map<String, dynamic>;
    if (streamed.statusCode != 200) {
      throw Exception(body['detail'] ?? 'DS 미리보기 실패');
    }
    return body;
  }

  /// ds_변경이력 전체 건수
  Future<int> getDsChangeHistoryCount({String divisionId = ''}) async {
    final uri = Uri.parse('$_baseUrl/ds/변경이력-count').replace(
      queryParameters: divisionId.isEmpty ? null : {'division_id': divisionId},
    );
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) return 0;
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return (body['count'] as num?)?.toInt() ?? 0;
  }

  /// DS 변경 이력 목록 조회. licenseNo 비면 전체.
  Future<List<Map<String, dynamic>>> listDsChangeHistory({
    String licenseNo = '',
    String divisionId = '',
    String uploadId = '',
    String search = '',
    bool includeCancelled = true,
    int limit = 2000,
  }) async {
    final uri = Uri.parse('$_baseUrl/ds/change-history').replace(queryParameters: {
      if (licenseNo.isNotEmpty) '허가번호': licenseNo,
      if (divisionId.isNotEmpty) 'division_id': divisionId,
      if (uploadId.isNotEmpty) 'upload_id': uploadId,
      if (search.isNotEmpty) 'search': search,
      'include_cancelled': includeCancelled ? 'true' : 'false',
      'limit': '$limit',
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['detail'] ?? 'DS 변경 이력 조회 실패');
    }
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  /// 업로드 묶음(upload_id) 요약 조회.
  Future<List<Map<String, dynamic>>> listDsChangeHistoryUploads({
    String divisionId = '',
    bool includeCancelled = true,
    int limit = 100,
  }) async {
    final uri = Uri.parse('$_baseUrl/ds/change-history/uploads').replace(queryParameters: {
      if (divisionId.isNotEmpty) 'division_id': divisionId,
      'include_cancelled': includeCancelled ? 'true' : 'false',
      'limit': '$limit',
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['detail'] ?? 'DS 업로드 묶음 조회 실패');
    }
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  /// DS 변경 이력 단건 취소(되돌리기). 변경전값으로 DS DB 복원.
  Future<Map<String, dynamic>> cancelDsChange(int historyId) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/ds/change-history/$historyId/cancel'),
      headers: _headers,
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['detail'] ?? 'DS 변경 취소 실패');
    }
    return body;
  }

  /// DS 변경 이력 다중 일괄 되돌리기. {succeeded, failed, skipped, errors} 반환.
  Future<Map<String, dynamic>> bulkCancelDsChanges(List<int> ids) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/ds/change-history/bulk-cancel'),
      headers: _headers,
      body: json.encode({'ids': ids}),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['detail'] ?? 'DS 변경 일괄 취소 실패');
    }
    return body;
  }

  /// 부분 DS 업로드 → DB 패치 + 자동 재비교
  Future<Map<String, dynamic>> applyPartialDsUpdate(Uint8List bytes, String filename,
      {List<String> excludedKeys = const [], String divisionId = '',
       String divisionCode = '', String importDate = ''}) async {
    final uri = Uri.parse('$_baseUrl/ds/apply-partial-update');
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename))
      ..fields['excluded'] = excludedKeys.isEmpty ? '' : json.encode(excludedKeys)
      ..fields['division_id'] = divisionId
      ..fields['division_code'] = divisionCode
      ..fields['import_date'] = importDate;
    final streamed = await req.send().timeout(_uploadTimeout);
    final body = json.decode(utf8.decode(await streamed.stream.toBytes())) as Map<String, dynamic>;
    if (streamed.statusCode != 200) {
      throw Exception(body['detail'] ?? '부분 DS 적용 실패');
    }
    return body;
  }

  // ── SKO-OCEAN sisl_photo ─────────────────────────────────

  /// SKO-OCEAN sisl_db 엑셀 임포트 (admin 전용).
  /// 응답: { success, filename, total, inserted, updated, skipped }
  Future<Map<String, dynamic>> importSislPhotos(Uint8List bytes, String filename) async {
    final uri = Uri.parse('$_baseUrl/admin/sisl-photos/import');
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await req.send().timeout(_uploadTimeout);
    final body = json.decode(utf8.decode(await streamed.stream.toBytes())) as Map<String, dynamic>;
    if (streamed.statusCode != 200) {
      throw Exception(body['detail'] ?? 'SISL 임포트 실패');
    }
    return body;
  }

  /// SKO-OCEAN sisl_photo 통계 (admin/manager).
  /// 응답: { total, unique_neos, date_min, date_max, by_reg_cls[], recent_imports[] }
  Future<Map<String, dynamic>> getSislPhotoStats() async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/sisl-photos/stats'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('SISL 통계 조회 실패');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 공대(neos_code) 기준 SKO-OCEAN 사진 메타 조회.
  /// 각 항목에 완성된 url 필드 포함.
  Future<List<Map<String, dynamic>>> listSislPhotos({
    required String neosCode,
    int regCls = 0,
    int limit = 500,
  }) async {
    if (neosCode.isEmpty) return const [];
    final uri = Uri.parse('$_baseUrl/sisl-photos').replace(queryParameters: {
      'neos_code': neosCode,
      if (regCls > 0) 'reg_cls': '$regCls',
      'limit': '$limit',
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('SISL 사진 조회 실패');
    }
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['items'] ?? const []);
  }

  /// 본부→팀 매핑 (cert 캐시 distinct). 응답: { '경기Access담당': ['평택품질개선팀', ...], ... }
  Future<Map<String, List<String>>> getSislFilterOptions() async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/sisl-photos/filter-options'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('필터 옵션 조회 실패');
    }
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final org = (body['org'] as Map?) ?? const {};
    return org.map((k, v) =>
        MapEntry('$k', List<String>.from((v as List?) ?? const [])));
  }

  /// 본부·팀·국소명·주소로 cert 조인 검색 → 국소(공대)별 사진 그룹.
  /// 응답: { groups: [{neos_code, 통시코드, 국소명, 주소, 본부, 팀, photo_count, photos[]}], total_neos, total_photos }
  Future<Map<String, dynamic>> searchSislPhotos({
    String hdqt = '',
    String team = '',
    String facility = '',
    String address = '',
  }) async {
    final uri = Uri.parse('$_baseUrl/sisl-photos/search').replace(queryParameters: {
      if (hdqt.isNotEmpty) 'hdqt': hdqt,
      if (team.isNotEmpty) 'team': team,
      if (facility.isNotEmpty) 'facility': facility,
      if (address.isNotEmpty) 'address': address,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('시설물 사진 검색 실패');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
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

  Future<List<Map<String, dynamic>>> getMyList(int year, {String week = '', String team = ''}) async {
    final uri = Uri.parse('$_baseUrl/inspection/my-list').replace(
        queryParameters: {
          'year': '$year',
          if (week.isNotEmpty) 'week': week,
          if (team.isNotEmpty) 'team': team,
        });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  Future<List<String>> getMyListWeeks(int year, {String team = ''}) async {
    final uri = Uri.parse('$_baseUrl/inspection/my-list/weeks').replace(
        queryParameters: {
          'year': '$year',
          if (team.isNotEmpty) 'team': team,
        });
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

  Future<Map<String, dynamic>> getProgressByResult(int year) async {
    final uri = Uri.parse('$_baseUrl/inspection/progress-by-result').replace(
        queryParameters: {'year': '$year'});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 본부 하나의 팀별 진행률
  Future<List<Map<String, dynamic>>> getProgressByTeam(int year, String region) async {
    final uri = Uri.parse('$_baseUrl/inspection/progress-by-team').replace(
        queryParameters: {'year': '$year', 'region': region});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) return [];
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

  Future<Map<String, dynamic>> remapDivisions({required int year, bool dryRun = true}) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/remap-divisions').replace(
          queryParameters: {'year': '$year', 'dry_run': dryRun ? 'true' : 'false'}),
      headers: _headers,
    ).timeout(const Duration(minutes: 5));
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '재매핑 실패');
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

  /// Phase 3: 검사내역서 발급 (다중 schedule_pk) + REPORT_ISSUED 자동 전환.
  /// 사전점검 거친 건(PRE_CHECK_DONE) 또는 사전점검 스킵 건(REGISTERED) 둘 다 통과.
  Future<Uint8List> generateInspectionReport({
    required List<String> schedulePks,
    String sheetTitle = '',
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/report/generate'),
      headers: _headers,
      body: json.encode({
        'schedule_pks': schedulePks,
        'sheet_title': sheetTitle,
      }),
    ).timeout(const Duration(minutes: 3));
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '검사내역서 발급 실패');
    }
    return resp.bodyBytes;
  }

  /// Phase 3: 전파관리소 접수번호 입력 → SUBMITTED 전환.
  Future<void> submitInspection({
    required String schedulePk,
    required String submissionNo,
    String submittedAt = '',
  }) async {
    final resp = await http.patch(
      Uri.parse('$_baseUrl/inspection/schedule/${Uri.encodeComponent(schedulePk)}/submission'),
      headers: _headers,
      body: json.encode({
        'submission_no': submissionNo,
        'submitted_at': submittedAt,
      }),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '접수번호 저장 실패');
    }
  }

  /// Phase 3: 접수번호 일괄 입력 — 다중 schedule_pk에 동일 접수번호 적용.
  /// returns: {total, succeeded, results: [{pk, ok, msg}, ...]}
  Future<Map<String, dynamic>> submitInspectionBulk({
    required List<String> schedulePks,
    required String submissionNo,
    String submittedAt = '',
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/schedule/submission-bulk'),
      headers: _headers,
      body: json.encode({
        'schedule_pks': schedulePks,
        'submission_no': submissionNo,
        'submitted_at': submittedAt,
      }),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['detail'] ?? '접수번호 일괄 저장 실패');
    }
    return body;
  }

  // ── Phase 5: 워크플로우 알림 ────────────────────────────
  //
  // 주의: 기존 NotificationService(시정기한/커뮤니티)와 별개.
  // 워크플로우 전환 자동 알림은 /inspection/notifications/* 네임스페이스 사용.

  /// 워크플로우 알림 목록 조회.
  Future<List<Map<String, dynamic>>> getNotifications({
    bool unreadOnly = false,
    int limit = 50,
  }) async {
    final uri = Uri.parse('$_baseUrl/inspection/notifications').replace(queryParameters: {
      if (unreadOnly) 'unread_only': 'true',
      'limit': '$limit',
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  /// 워크플로우 알림 안 읽음 개수.
  Future<int> getUnreadNotificationCount() async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/inspection/notifications/unread-count'),
      headers: _headers,
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return (body['count'] as num?)?.toInt() ?? 0;
  }

  /// 워크플로우 알림 읽음 처리. ids 비워서 보내면 전체 안 읽음 일괄 처리.
  Future<int> markNotificationsRead({List<int> ids = const []}) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/notifications/mark-read'),
      headers: _headers,
      body: json.encode({'ids': ids}),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return (body['updated'] as num?)?.toInt() ?? 0;
  }

  // ── Phase 5: 역할별 대시보드 ────────────────────────────

  /// 역할별 워크플로우 대시보드 집계.
  /// returns: { role, scope, counts, recheck, overdue, overdue_total }
  Future<Map<String, dynamic>> getDashboard(int year) async {
    final uri = Uri.parse('$_baseUrl/inspection/dashboard')
        .replace(queryParameters: {'year': '$year'});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['detail'] ?? '대시보드 조회 실패');
    }
    return body;
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
  ///
  /// [team] 지정 시 그 팀만, [groupBy]='team' + [region] 지정 시 그 본부의 팀별 분해.
  Future<Map<String, dynamic>> getResultsDashboard(int year, {
    String region = '',
    String team = '',
    String groupBy = '',
  }) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/dashboard')
        .replace(queryParameters: {
      'year': '$year',
      if (region.isNotEmpty) 'region': region,
      if (team.isNotEmpty) 'team': team,
      if (groupBy.isNotEmpty) 'groupBy': groupBy,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 월별 대시보드
  Future<Map<String, dynamic>> getResultsMonthly(int year, String month, {
    String region = '',
    String team = '',
    String groupBy = '',
  }) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/dashboard/monthly')
        .replace(queryParameters: {
      'year': '$year',
      'month': month,
      if (region.isNotEmpty) 'region': region,
      if (team.isNotEmpty) 'team': team,
      if (groupBy.isNotEmpty) 'groupBy': groupBy,
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

  Future<Map<String, dynamic>> getResultsAnalysis(int year, {
    String region = '',
    String team = '',
  }) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/analysis')
        .replace(queryParameters: {
      'year': '$year',
      if (region.isNotEmpty) 'region': region,
      if (team.isNotEmpty) 'team': team,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('분석 조회 실패');
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 본부별 또는 팀별 주차별 추이. [region] 지정 시 그 본부의 ons팀 단위로 자동 분해.
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

  Future<Map<String, dynamic>> getResultsWeeklyTrend(int year, {
    String region = '',
    String team = '',
  }) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/weekly-trend')
        .replace(queryParameters: {
      'year': '$year',
      if (region.isNotEmpty) 'region': region,
      if (team.isNotEmpty) 'team': team,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('주차별 추이 조회 실패');
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getResultsSummaryReport(int year, {
    String region = '',
    String team = '',
  }) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/summary-report')
        .replace(queryParameters: {
      'year': '$year',
      if (region.isNotEmpty) 'region': region,
      if (team.isNotEmpty) 'team': team,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('리포트 조회 실패');
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<List<String>> getResultsWeeks(int year, {String month = '', String region = ''}) async {
    final uri = Uri.parse('$_baseUrl/inspection-results/weeks').replace(queryParameters: {
      'year': year.toString(),
      if (month.isNotEmpty) 'month': month,
      if (region.isNotEmpty) 'region': region,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) return [];
    final data = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<String>.from(data['weeks'] as List? ?? []);
  }

  Future<Uint8List> exportResultsXlsx(int year, {
    List<String> regions = const [], String progress = '', String status = '',
    String perfDoc = '', List<String> weeks = const [],
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection-results/export-xlsx'),
      headers: _headers,
      body: json.encode({
        'year': year, '본부': regions, '진행여부': progress,
        'status': status, '성능서류': perfDoc, '주차별': weeks,
      }),
    ).timeout(const Duration(minutes: 5));
    if (resp.statusCode != 200) throw Exception('엑셀 다운로드 실패');
    return resp.bodyBytes;
  }

  // ── 부적합 관리 ──────────────────────────────────────────

  /// 부적합 동기화
  Future<Map<String, dynamic>> syncInadequate(int year) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inadequate/sync').replace(
          queryParameters: {'year': '$year'}),
      headers: _headers,
    ).timeout(const Duration(minutes: 5));
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '동기화 실패');
    return body;
  }

  /// 부적합 목록
  Future<Map<String, dynamic>> getInadequateList(int year, {
    String region = '',
    String team = '',
    String status = '',
    String searchField = '',   // 'license' | 'callname' | 'address'
    String searchValues = '',  // 콤마 구분 복수값
    int page = 1,
    int pageSize = 100,
    String sortBy = '',
    String sortDir = 'desc',
  }) async {
    final uri = Uri.parse('$_baseUrl/inadequate/list').replace(
        queryParameters: {
      'year': '$year',
      if (region.isNotEmpty) 'region': region,
      if (team.isNotEmpty) 'team': team,
      if (status.isNotEmpty) 'status': status,
      if (searchField.isNotEmpty && searchValues.isNotEmpty) 'search_field': searchField,
      if (searchField.isNotEmpty && searchValues.isNotEmpty) 'search_values': searchValues,
      'page': '$page',
      'pageSize': '$pageSize',
      if (sortBy.isNotEmpty) 'sort_by': sortBy,
      'sort_dir': sortDir,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 부적합 상태 업데이트
  Future<void> updateInadequate(int id, {String status = '', String reviewRound = ''}) async {
    final resp = await http.put(
      Uri.parse('$_baseUrl/inadequate/update'),
      headers: _headers,
      body: json.encode({
        'id': id,
        if (status.isNotEmpty) 'status': status,
        if (reviewRound.isNotEmpty) '심의차수': reviewRound,
      }),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? '업데이트 실패');
    }
  }

  /// 부적합 Excel 내보내기
  Future<Uint8List> exportInadequateXlsx(int year, {
    String region = '',
    String team = '',
    String status = '',
    String searchField = '',
    String searchValues = '',
  }) async {
    final uri = Uri.parse('$_baseUrl/inadequate/export-xlsx').replace(
        queryParameters: {
      'year': '$year',
      if (region.isNotEmpty) 'region': region,
      if (team.isNotEmpty) 'team': team,
      if (status.isNotEmpty) 'status': status,
      if (searchField.isNotEmpty && searchValues.isNotEmpty) 'search_field': searchField,
      if (searchField.isNotEmpty && searchValues.isNotEmpty) 'search_values': searchValues,
    });
    final resp = await http.get(uri, headers: _headers).timeout(const Duration(minutes: 3));
    if (resp.statusCode != 200) throw Exception('엑셀 내보내기 실패');
    return resp.bodyBytes;
  }

  /// 부적합 통계
  Future<Map<String, dynamic>> getInadequateStats(int year, {
    String region = '',
    String team = '',
  }) async {
    final uri = Uri.parse('$_baseUrl/inadequate/stats').replace(
        queryParameters: {
      'year': '$year',
      if (region.isNotEmpty) 'region': region,
      if (team.isNotEmpty) 'team': team,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<String> buildDsDetail(String divisionId, String importDate) async {
    final uri = Uri.parse('$_baseUrl/inspection/build-ds-detail').replace(
        queryParameters: {'division_id': divisionId, 'import_date': importDate});
    final resp = await http.post(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '빌드 실패');
    return body['jobId'] as String;
  }

  // ── 매핑 보정 ─────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getOverrides(int year, {String licenseNo = ''}) async {
    final uri = Uri.parse('$_baseUrl/inspection/overrides').replace(queryParameters: {
      'year': '$year',
      if (licenseNo.isNotEmpty) '허가번호': licenseNo,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes));
    return List<Map<String, dynamic>>.from(body as List);
  }

  Future<void> upsertOverride(int year, String licenseNo, String field, String value, {String reason = ''}) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/overrides'),
      headers: _headers,
      body: json.encode({'year': year, '허가번호': licenseNo, 'field': field, 'value': value, 'reason': reason}),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '보정 저장 실패');
    }
  }

  Future<void> deleteOverride(int id) async {
    final resp = await http.delete(
      Uri.parse('$_baseUrl/inspection/overrides/$id'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '보정 취소 실패');
    }
  }
}
